#import "SFYTSabr.h"
#import "SFRuntime.h"
#import "SFModel.h"
#import "SFYTBreaker.h"
#import "SFEngine.h"
#import "SFSettings.h"
#import "SFStats.h"
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
    NSInteger _crashes;         // consecutive short-lived runs (reset only after a long healthy run)
    NSDate *_launchedAt;
    NSTimeInterval _nextStartAt; // backoff: no start before this (epoch)
    NSMutableArray *_queued;    // blocks waiting for readiness: ^(NSInteger port)
    NSMutableSet *_failed;      // video IDs whose SABR playback failed this run
    NSURLSession *_session;
    NSMutableArray *_preloads;  // times of recent focus preloads (budget)
}

// Focus preloads: at most this many player requests per window. Browsing a row quickly used to
// resolve every video the focus rested on - each one a player request on a bot-flagged IP.
static const NSUInteger kPreloadBudget = 8;
static const NSTimeInterval kPreloadWindow = 600;

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

static NSString *SabrMain(void) { return [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"sofa-yt/main.ts"]; }

- (BOOL)available {
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:SabrMain()] && [fm isExecutableFileAtPath:SFTool(@"node")];
}

- (void)markFailed:(NSString *)vid { if (vid) { [_failed addObject:vid]; SFCount(@"yt.sabr.marked-failed"); } }

- (NSString *)baseURL { return _port ? [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)_port] : nil; }

- (BOOL)usableFor:(NSString *)vid {
    return self.available && SFMPVAvailable() && !SFPreferAVFoundation() && ![self failedFor:vid];
}

- (BOOL)preloadOnFocus:(NSString *)vid {
    if (!vid.length || ![self usableFor:vid] || [SFYTBreaker shared].blockedUntil) return NO;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (!_preloads) _preloads = [NSMutableArray array];
    while (_preloads.count && now - [_preloads[0] doubleValue] > kPreloadWindow) [_preloads removeObjectAtIndex:0];
    if (_preloads.count >= kPreloadBudget) return NO;
    [_preloads addObject:@(now)];
    // the sidecar caches the player response: the click then opens without a player request
    // (a cached one costs nothing, so the budget only limits what reaches YouTube)
    [self open:vid background:YES done:^(NSDictionary *r, NSError *e) {}];
    return YES;
}

- (void)closeSession:(NSString *)sid {
    if (!sid.length || !_port) return;
    NSString *u = [NSString stringWithFormat:@"http://127.0.0.1:%ld/close?sid=%@", (long)_port, sid];
    [[_session dataTaskWithURL:[NSURL URLWithString:u]] resume];
}
- (BOOL)failedFor:(NSString *)vid { return vid && [_failed containsObject:vid]; }

- (void)sessionStatus:(NSString *)sid done:(void (^)(NSDictionary *))done {
    if (!sid.length || !_port) { done(nil); return; }
    NSString *u = [NSString stringWithFormat:@"http://127.0.0.1:%ld/s/%@/status", (long)_port, sid];
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]];
    rq.timeoutInterval = 3;   // a hanging sidecar must not hold up the player's decision
    [[_session dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSDictionary *j = d && [(NSHTTPURLResponse *)resp statusCode] == 200 ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        SFMain(^{ done([j isKindOfClass:[NSDictionary class]] ? j : nil); });
    }] resume];
}

#pragma mark Process

// A run shorter than this counts as a crash for the backoff. Resetting on the ready line was wrong:
// the sidecar is ready before its warm-up, so a crash during warm-up restarted it every 2 s, each
// time contacting YouTube again (review 2026-11-05).
static const NSTimeInterval kHealthyRun = 300;

- (void)start {
    if (_task.isRunning || !self.available) return;
    if ([NSDate date].timeIntervalSince1970 < _nextStartAt) return;   // backing off after crashes
    signal(SIGPIPE, SIG_IGN);
    NSString *state = [SFAppSupportDir() stringByAppendingPathComponent:@"sofa-yt"];   // dev instances: their own (SFSetDevInstance)
    NSString *cache = [SFCacheDir() stringByAppendingPathComponent:@"yt-dlp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    NSTask *t = [NSTask new];
    t.launchPath = SFTool(@"node");
    // the breaker file is ytresolver.py's: one bot-check state for both paths (same IP)
    t.arguments = @[SabrMain(), @"--port", @"0", @"--state", state,
                    @"--block-file", [SFYTBreaker filePath]];
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
    _task = t; _in = pin.fileHandleForWriting; _port = 0; _launchedAt = [NSDate date];
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
    // backoff first: 5 s, 10 s, 20 s ... up to 10 min for runs that died early; opens meanwhile go to
    // yt-dlp. Set BEFORE anyone hears of the exit - the player's observer reopens at once and would
    // otherwise start a new sidecar right away, bypassing the backoff (review 2026-11-05).
    BOOL healthy = _launchedAt && -[_launchedAt timeIntervalSinceNow] > kHealthyRun;
    _crashes = healthy ? 0 : _crashes + 1;
    double delay = healthy ? 2 : MIN(600, 5 * pow(2, MAX(0, _crashes - 1)));
    _nextStartAt = [NSDate date].timeIntervalSince1970 + delay;
    if (_crashes > 1) SFLog(@"sabr: %ld short runs in a row - next start in %.0f s", (long)_crashes, delay);
    NSArray *q = [_queued copy]; [_queued removeAllObjects];
    for (void (^w)(NSInteger) in q) w(0);
    [[NSNotificationCenter defaultCenter] postNotificationName:SFYTSabrDidExitNotification object:self];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay + 0.1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_task && !SFDevMode) [self start];
    });
}

// Calls back with the port once ready (0 = not available / timed out). Main thread.
- (void)whenReady:(void (^)(NSInteger port))block {
    if (_port) { block(_port); return; }
    if (!_task && [NSDate date].timeIntervalSince1970 < _nextStartAt) { block(0); return; }   // backing off
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
    [self open:vid query:[NSString stringWithFormat:@"bg=%d&maxHeight=1080&lang=de&prefetch=0", bg ? 1 : 0] done:done];
}

- (void)openForDownload:(NSString *)vid done:(void (^)(NSDictionary *, NSError *))done {
    [self open:vid query:@"bg=1&maxHeight=1080&lang=de&prefetch=0" done:done];
}

- (void)open:(NSString *)vid query:(NSString *)query done:(void (^)(NSDictionary *, NSError *))done {
    if (!vid.length) { done(nil, SFError(@"Video nicht abspielbar.")); return; }
    NSDate *t0 = [NSDate date];
    [self whenReady:^(NSInteger port) {
        if (!port) { done(nil, SFError(@"YouTube-Wiedergabe startet gerade.")); return; }
        // prefetch=0: mpv's own reads (at the resume position) drive what SABR pulls
        NSString *u = [NSString stringWithFormat:@"http://127.0.0.1:%ld/open?v=%@&%@", (long)port, vid, query];
        [[self->_session dataTaskWithURL:[NSURL URLWithString:u] completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            SFMain(^{
                if (![j isKindOfClass:[NSDictionary class]]) {
                    SFLog(@"sabr: open %@ failed: %@", vid, e.localizedDescription ?: @"no answer");
                    done(nil, e ?: SFError(@"YouTube-Wiedergabe antwortet nicht.")); return;
                }
                BOOL playable = [j[@"video"] isKindOfClass:[NSString class]] || [j[@"hls"] isKindOfClass:[NSString class]];
                if (j[@"error"] || !playable) {
                    SFLog(@"sabr: open %@ failed: %@%@", vid, j[@"error"] ?: @"no video", [j[@"bot"] boolValue] ? @" (bot check)" : @"");
                    // the sidecar wrote the shared breaker file; take its pause over right away
                    if ([j[@"bot"] boolValue]) [[SFYTBreaker shared] noteBlockedUntil:[j[@"blocked_until"] doubleValue]];
                    NSError *err = [NSError errorWithDomain:@"SFYTSabr" code:1 userInfo:@{
                        NSLocalizedDescriptionKey: [j[@"error"] description] ?: @"no video",
                        @"bot": @([j[@"bot"] boolValue]), @"live": @([j[@"live"] boolValue]),
                        @"upcoming": @([j[@"upcoming"] boolValue]), @"startTime": @([j[@"startTime"] doubleValue]),
                        @"blocked_until": @([j[@"blocked_until"] doubleValue])}];
                    done(nil, err); return;
                }
                if (j[@"hls"]) SFLog(@"sabr: opened %@ -> %@ HLS %@p%@ in %.1fs%@", vid, [j[@"live"] boolValue] ? @"live" : @"post-live",
                                     j[@"height"], j[@"fps"], -[t0 timeIntervalSinceNow], [j[@"cached"] boolValue] ? @" (cached)" : @"");
                else SFLog(@"sabr: opened %@ -> %@p%@ %@/%@ audio %@ in %.1fs%@", vid, j[@"height"], j[@"fps"], j[@"vcodec"], j[@"acodec"],
                      [j[@"alang"] isKindOfClass:[NSString class]] ? j[@"alang"] : @"?", -[t0 timeIntervalSinceNow], [j[@"cached"] boolValue] ? @" (cached)" : @"");
                done(SabrClean(j), nil);
            });
        }] resume];
    }];
}

@end
