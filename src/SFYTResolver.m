#import "SFYTResolver.h"
#import "SFModel.h"

@implementation SFYTResolver {
    NSTask *_task;
    NSFileHandle *_in;
    NSMutableData *_buf, *_ebuf;
    NSMutableDictionary *_pending;    // rid -> @[key, vid]
    NSMutableDictionary *_waiters;    // key (vid bzw. live:vid) -> Rückrufe; eine Auflösung je Video
    NSMutableSet *_prioKeys;          // keys, für die schon eine Wiedergabe-Anfrage läuft
    NSMutableDictionary *_cache;      // vid -> result (bis expires - 1 h)
    NSInteger _rid;
    NSInteger _crashes;
    BOOL _wantRunning;
}

+ (instancetype)shared {
    static SFYTResolver *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFYTResolver new]; });
    return s;
}

+ (NSString *)cookieFile { return [SFAppSupportDir() stringByAppendingPathComponent:@"youtube-cookies.txt"]; }
+ (NSString *)python { return [SFAppSupportDir() stringByAppendingPathComponent:@"ytdlp/bin/python"]; }

- (instancetype)init {
    if ((self = [super init])) {
        _pending = [NSMutableDictionary new];
        _waiters = [NSMutableDictionary new];
        _prioKeys = [NSMutableSet new];
        _cache = [NSMutableDictionary new];
    }
    return self;
}

- (void)start {
    _wantRunning = YES;
    signal(SIGPIPE, SIG_IGN);   // Schreiben in eine tote Pipe darf die App nicht beenden
    if (_task.isRunning) return;
    NSString *py = [SFYTResolver python];
    NSString *script = [[NSBundle mainBundle] pathForResource:@"ytresolver" ofType:@"py"];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:py] || !script) {
        SFLog(@"yt: resolver missing (python %@, script %@)", py, script);
        return;
    }
    NSString *cache = [SFCacheDir() stringByAppendingPathComponent:@"yt-dlp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    NSTask *t = [NSTask new];
    t.launchPath = py;
    t.arguments = @[script, [SFYTResolver cookieFile], cache];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    env[@"PATH"] = @"/opt/local/bin:/usr/bin:/bin";
    env[@"PYTHONUNBUFFERED"] = @"1";
    t.environment = env;
    NSPipe *pin = [NSPipe pipe], *pout = [NSPipe pipe], *perr = [NSPipe pipe];
    t.standardInput = pin; t.standardOutput = pout; t.standardError = perr;
    _buf = [NSMutableData new]; _ebuf = [NSMutableData new];
    __weak SFYTResolver *ws = self;
    pout.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        SFMain(^{ [ws gotData:d err:NO]; });
    };
    perr.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        SFMain(^{ [ws gotData:d err:YES]; });
    };
    t.terminationHandler = ^(NSTask *tt) {
        SFMain(^{ [ws terminated:tt]; });
    };
    @try { [t launch]; }
    @catch (NSException *ex) { SFLog(@"yt: resolver launch failed %@", ex); return; }
    _task = t;
    _in = pin.fileHandleForWriting;
    SFLog(@"yt: resolver started pid %d", t.processIdentifier);
}

- (void)restart {
    if (_task.isRunning) { [_task terminate]; }   // terminated: startet neu
    else [self start];
}

- (void)terminated:(NSTask *)t {
    if (t != _task) return;
    SFLog(@"yt: resolver exited (%d)", t.terminationStatus);
    ((NSPipe *)t.standardOutput).fileHandleForReading.readabilityHandler = nil;
    ((NSPipe *)t.standardError).fileHandleForReading.readabilityHandler = nil;
    _task = nil; _in = nil;
    [_pending removeAllObjects];
    for (NSString *key in [_waiters allKeys]) [self finish:key result:nil error:SFError(@"YouTube-Auflösung abgebrochen.")];
    if (!_wantRunning) return;
    _crashes++;
    double delay = MIN(60, 2 * _crashes);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self start]; });
}

- (void)gotData:(NSData *)d err:(BOOL)isErr {
    NSMutableData *b = isErr ? _ebuf : _buf;
    [b appendData:d];
    while (1) {
        const char *bytes = b.bytes;
        void *nl = memchr(bytes, '\n', b.length);
        if (!nl) break;
        NSUInteger n = (const char *)nl - bytes;
        NSData *line = [b subdataWithRange:NSMakeRange(0, n)];
        [b replaceBytesInRange:NSMakeRange(0, n + 1) withBytes:NULL length:0];
        if (isErr) { NSString *s = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding]; if (s.length) SFLog(@"%@", s); continue; }
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) continue;
        if (j[@"ready"]) { _crashes = 0; continue; }
        NSNumber *rid = j[@"rid"];
        NSArray *p = rid ? _pending[rid] : nil;
        if (!p) continue;
        [_pending removeObjectForKey:rid];
        NSString *key = p[0], *vid = p[1];
        if ([j[@"url"] isKindOfClass:[NSString class]]) {
            SFLog(@"yt: resolved %@ -> %@p %@ in %@s (%@)", vid, j[@"height"], j[@"format"], j[@"secs"], j[@"pool"]);
            if (![key hasPrefix:@"live:"]) _cache[vid] = j;
            [self finish:key result:j error:nil];
        } else {
            SFLog(@"yt: resolve %@ failed: %@", vid, j[@"error"]);
            // läuft für dasselbe Video noch eine zweite Anfrage (Vorladen + Klick), auf die warten
            if (![self hasPending:key]) [self finish:key result:nil error:SFError([self friendly:j[@"error"]])];
        }
    }
}

- (NSString *)friendly:(NSString *)e {
    if (![e isKindOfClass:[NSString class]]) return @"Video nicht abspielbar.";
    NSString *l = e.lowercaseString;
    if ([l rangeOfString:@"private"].location != NSNotFound) return @"Dieses Video ist privat.";
    if ([l rangeOfString:@"age"].location != NSNotFound && [l rangeOfString:@"confirm"].location != NSNotFound) return @"Dieses Video ist altersbeschränkt und kann hier nicht abgespielt werden.";
    if ([l rangeOfString:@"premiere"].location != NSNotFound || [l rangeOfString:@"live event will begin"].location != NSNotFound) return @"Dieser Livestream hat noch nicht begonnen.";
    if ([l rangeOfString:@"unavailable"].location != NSNotFound || [l rangeOfString:@"nicht verfügbar"].location != NSNotFound) return @"Video nicht verfügbar.";
    return e;
}

- (BOOL)hasPending:(NSString *)key {
    for (NSArray *p in _pending.allValues) if ([p[0] isEqualToString:key]) return YES;
    return NO;
}

- (void)finish:(NSString *)key result:(NSDictionary *)r error:(NSError *)e {
    NSArray *w = _waiters[key];
    [_waiters removeObjectForKey:key];
    [_prioKeys removeObject:key];
    for (void (^done)(NSDictionary *, NSError *) in w) done(r, e);
}

- (void)resolve:(NSString *)vid live:(BOOL)live done:(void (^)(NSDictionary *, NSError *))done {
    [self resolve:vid live:live prio:YES done:done];
}
- (void)prefetch:(NSString *)vid done:(void (^)(NSDictionary *, NSError *))done {
    [self resolve:vid live:NO prio:NO done:done ?: ^(NSDictionary *r, NSError *e) {}];
}

- (void)resolve:(NSString *)vid live:(BOOL)live prio:(BOOL)prio done:(void (^)(NSDictionary *, NSError *))done {
    NSDictionary *c = _cache[vid];
    if (c && [c[@"expires"] doubleValue] - 3600 > [[NSDate date] timeIntervalSince1970] && !live) { done(c, nil); return; }
    [self start];
    if (!_in) { done(nil, SFError(@"YouTube-Wiedergabe nicht eingerichtet (yt-dlp fehlt).")); return; }
    NSString *key = live ? [@"live:" stringByAppendingString:vid] : vid;
    NSMutableArray *w = _waiters[key];
    if (w) {   // dasselbe Video wird schon aufgelöst (z.B. Vorladen bei Fokus) -> mitwarten
        [w addObject:[done copy]];
        if (!prio || [_prioKeys containsObject:key]) return;
        // nur Vorladen unterwegs: zusätzlich als Wiedergabe anfragen – der Resolver überholt
        // ein noch wartendes Vorladen oder hängt sich an ein laufendes an
    } else {
        _waiters[key] = [NSMutableArray arrayWithObject:[done copy]];
    }
    if (prio) [_prioKeys addObject:key];
    NSNumber *rid = @(++_rid);
    _pending[rid] = @[key, vid];
    NSData *line = [NSJSONSerialization dataWithJSONObject:@{@"rid": rid, @"vid": vid, @"live": @(live), @"prio": @(prio)} options:0 error:nil];
    NSMutableData *m = [line mutableCopy]; [m appendBytes:"\n" length:1];
    @try { [_in writeData:m]; }
    @catch (NSException *ex) {
        [_pending removeObjectForKey:rid];
        if (![self hasPending:key]) [self finish:key result:nil error:SFError(@"YouTube-Auflösung nicht erreichbar.")];
        return;
    }
    // Zeitlimit: erster Lauf nach Player-Rollout ~25 s, danach ~3 s
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_pending[rid]) return;
        [self->_pending removeObjectForKey:rid];
        if (![self hasPending:key]) [self finish:key result:nil error:SFError(@"YouTube antwortet nicht.")];
    });
}
- (void)forget:(NSString *)videoID { if (videoID) [_cache removeObjectForKey:videoID]; }
@end
