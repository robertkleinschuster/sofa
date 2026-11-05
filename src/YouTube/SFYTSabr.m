#import "SFYTSabr.h"
#import "SFRuntime.h"
#import "SFModel.h"
#import <signal.h>

// Opens wait at most this long for the sidecar to become ready (then the caller falls back to yt-dlp)
static const NSTimeInterval kReadyTimeout = 15;
// /open: ~10 ms with a cached player response, 2-4 s otherwise, longer on the very first call
// (Innertube session + BotGuard warm-up)
static const NSTimeInterval kOpenTimeout = 30;

NSString *const SFYTSabrDidExitNotification = @"SFYTSabrDidExit";

@implementation SFYTSabr {
    NSTask *_task;
    NSFileHandle *_in;          // kept open: the sidecar exits when its stdin reaches EOF (no orphans)
    NSMutableData *_out, *_err;
    NSInteger _port;            // 0 = not ready
    NSInteger _crashes;
    NSMutableArray *_queued;    // blocks waiting for readiness: ^(NSInteger port)
    NSMutableSet *_failed;      // video IDs whose SABR playback failed this run
    NSURLSession *_session;
}

+ (instancetype)shared {
    static SFYTSabr *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SFYTSabr new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queued = [NSMutableArray new];
        _failed = [NSMutableSet new];
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.connectionProxyDictionary = @{};          // local only, never through a proxy
        c.timeoutIntervalForRequest = kOpenTimeout;
        c.HTTPMaximumConnectionsPerHost = 4;
        _session = [NSURLSession sessionWithConfiguration:c];
    }
    return self;
}

static NSString *SabrMain(void) { return [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"sofa-yt/main.mjs"]; }

- (BOOL)available {
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:SabrMain()] && [fm isExecutableFileAtPath:SFTool(@"node")];
}

- (void)markFailed:(NSString *)vid { if (vid) [_failed addObject:vid]; }
- (BOOL)failedFor:(NSString *)vid { return vid && [_failed containsObject:vid]; }

#pragma mark Process

- (void)start {
    if (_task.isRunning || !self.available) return;
    signal(SIGPIPE, SIG_IGN);
    NSString *state = [SFAppSupportDir() stringByAppendingPathComponent:SFDevMode ? @"sofa-yt-dev" : @"sofa-yt"];
    NSString *cache = [SFCacheDir() stringByAppendingPathComponent:@"yt-dlp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    NSTask *t = [NSTask new];
    t.launchPath = SFTool(@"node");
    // the breaker file is ytresolver.py's: one bot-check state for both paths (same IP)
    t.arguments = @[SabrMain(), @"--port", @"0", @"--state", state,
                    @"--block-file", [cache stringByAppendingPathComponent:@"youtube-block.json"]];
    t.currentDirectoryPath = [SabrMain() stringByDeletingLastPathComponent];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    if (SFDevMode) env[@"SOFA_NO_WARMUP"] = @"1";   // test starts must not contact YouTube
    t.environment = env;
    NSPipe *pin = [NSPipe pipe], *pout = [NSPipe pipe], *perr = [NSPipe pipe];
    t.standardInput = pin; t.standardOutput = pout; t.standardError = perr;
    _out = [NSMutableData new]; _err = [NSMutableData new];
    __weak SFYTSabr *ws = self;
    pout.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) { NSData *d = h.availableData; SFMain(^{ [ws got:d err:NO task:t]; }); };
    perr.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) { NSData *d = h.availableData; SFMain(^{ [ws got:d err:YES task:t]; }); };
    t.terminationHandler = ^(NSTask *tt) { SFMain(^{ [ws terminated:tt]; }); };
    @try { [t launch]; }
    @catch (NSException *ex) { SFLog(@"sabr: launch failed %@", ex); return; }
    _task = t; _in = pin.fileHandleForWriting; _port = 0;
    SFLog(@"sabr: sidecar started pid %d", t.processIdentifier);
}

- (void)got:(NSData *)d err:(BOOL)isErr task:(NSTask *)t {
    if (t != _task || !d.length) return;
    NSMutableData *b = isErr ? _err : _out;
    [b appendData:d];
    while (1) {
        const char *bytes = b.bytes;
        void *nl = memchr(bytes, '\n', b.length);
        if (!nl) break;
        NSUInteger n = (const char *)nl - bytes;
        NSString *line = [[NSString alloc] initWithData:[b subdataWithRange:NSMakeRange(0, n)] encoding:NSUTF8StringEncoding];
        [b replaceBytesInRange:NSMakeRange(0, n + 1) withBytes:NULL length:0];
        if (isErr) { if (line.length) SFLog(@"%@", line); continue; }
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data] options:0 error:nil];
        if ([j isKindOfClass:[NSDictionary class]] && [j[@"ready"] boolValue] && [j[@"port"] integerValue] > 0) {
            _port = [j[@"port"] integerValue];
            _crashes = 0;
            SFLog(@"sabr: ready on port %ld", (long)_port);
            NSArray *q = [_queued copy]; [_queued removeAllObjects];
            for (void (^w)(NSInteger) in q) w(_port);
        }
    }
}

- (void)terminated:(NSTask *)t {
    if (t != _task) return;
    SFLog(@"sabr: sidecar exited (%d)", t.terminationStatus);
    ((NSPipe *)t.standardOutput).fileHandleForReading.readabilityHandler = nil;
    ((NSPipe *)t.standardError).fileHandleForReading.readabilityHandler = nil;
    _task = nil; _in = nil; _port = 0;
    NSArray *q = [_queued copy]; [_queued removeAllObjects];
    for (void (^w)(NSInteger) in q) w(0);
    [[NSNotificationCenter defaultCenter] postNotificationName:SFYTSabrDidExitNotification object:self];
    // restart lazily with backoff (the next open starts it again anyway)
    _crashes++;
    double delay = MIN(60, 2 * _crashes);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_task && !SFDevMode) [self start];
    });
}

// Calls back with the port once ready (0 = not available / timed out). Main thread.
- (void)whenReady:(void (^)(NSInteger port))block {
    if (_port) { block(_port); return; }
    [self start];
    if (!_task) { block(0); return; }
    __block BOOL called = NO;
    void (^once)(NSInteger) = ^(NSInteger p) { if (called) return; called = YES; block(p); };
    [_queued addObject:[once copy]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReadyTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (called) return;
        SFLog(@"sabr: sidecar not ready after %.0f s", kReadyTimeout);
        once(0);
    });
}

#pragma mark Open

// JSON null -> key absent: the player code treats every value as a string/number (e.g. alang is
// null for single-language videos, and SFBaseLanguage(NSNull) would crash)
static id SabrClean(id v) {
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary new];
        [(NSDictionary *)v enumerateKeysAndObjectsUsingBlock:^(id k, id o, BOOL *stop) { if (o != [NSNull null]) d[k] = SabrClean(o); }];
        return d;
    }
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray new];
        for (id o in v) if (o != [NSNull null]) [a addObject:SabrClean(o)];
        return a;
    }
    return v;
}

- (void)open:(NSString *)vid background:(BOOL)bg done:(void (^)(NSDictionary *, NSError *))done {
    if (!vid.length) { done(nil, SFError(@"Video nicht abspielbar.")); return; }
    NSDate *t0 = [NSDate date];
    [self whenReady:^(NSInteger port) {
        if (!port) { done(nil, SFError(@"YouTube-Wiedergabe startet gerade.")); return; }
        // prefetch=0: mpv's own reads (at the resume position) drive what SABR pulls
        NSString *u = [NSString stringWithFormat:@"http://127.0.0.1:%ld/open?v=%@&bg=%d&maxHeight=1080&lang=de&prefetch=0",
                       (long)port, vid, bg ? 1 : 0];
        [[self->_session dataTaskWithURL:[NSURL URLWithString:u] completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            SFMain(^{
                if (![j isKindOfClass:[NSDictionary class]]) {
                    SFLog(@"sabr: open %@ failed: %@", vid, e.localizedDescription ?: @"no answer");
                    done(nil, e ?: SFError(@"YouTube-Wiedergabe antwortet nicht.")); return;
                }
                if (j[@"error"] || ![j[@"video"] isKindOfClass:[NSString class]]) {
                    SFLog(@"sabr: open %@ failed: %@%@", vid, j[@"error"] ?: @"no video", [j[@"bot"] boolValue] ? @" (bot check)" : @"");
                    NSError *err = [NSError errorWithDomain:@"SFYTSabr" code:1 userInfo:@{
                        NSLocalizedDescriptionKey: [j[@"error"] description] ?: @"no video",
                        @"bot": @([j[@"bot"] boolValue]), @"live": @([j[@"live"] boolValue])}];
                    done(nil, err); return;
                }
                SFLog(@"sabr: opened %@ -> %@p%@ %@/%@ audio %@ in %.1fs%@", vid, j[@"height"], j[@"fps"], j[@"vcodec"], j[@"acodec"],
                      [j[@"alang"] isKindOfClass:[NSString class]] ? j[@"alang"] : @"?", -[t0 timeIntervalSinceNow], [j[@"cached"] boolValue] ? @" (cached)" : @"");
                done(SabrClean(j), nil);
            });
        }] resume];
    }];
}

@end
