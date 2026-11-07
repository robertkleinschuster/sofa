#import "SFModel.h"
#import "SFYTEngine+Private.h"
#import "SFYTBrowser.h"
#import "SFYTBreaker.h"
#import "SFUserAgent.h"
#import "SFLocalHTTP.h"
#import "SFJSON.h"

NSString *const SFYTEngineSessionsLostNotification = @"SFYTEngineSessionsLost";

// Firefox start + youtube.com load + engine start; longer = restart the browser
static const NSTimeInterval kLaunchTimeout = 90;
// callers wait at most this long for a starting engine
static const NSTimeInterval kReadyTimeout = 60;
// the page's ytcfg appears after document_start: health is asked again until it is there
static const NSTimeInterval kPagePoll = 0.5;
static const int kPagePolls = 120;
// open: ~10 ms from the cache, 2-4 s with a player request, longer on the first (BotGuard)
static const NSTimeInterval kOpenTimeout = 60;
static const NSTimeInterval kCallTimeout = 30;
// a run shorter than this counts as a failure for the restart backoff
static const NSTimeInterval kHealthyRun = 300;
// largest request body: a POST of answers carries media reads (8 MB base64 at most) and events
static const NSUInteger kMaxPost = 16 * 1024 * 1024;
// focus preloads: at most this many player requests per window
static const NSUInteger kPreloadBudget = 8;
static const NSTimeInterval kPreloadWindow = 600;

typedef NS_ENUM(NSInteger, SFYTEngineState) { SFYTEngineIdle, SFYTEngineStarting, SFYTEngineReady };

@implementation SFYTEngine {
    SFLocalHTTP *_server;
    SFYTBrowser *_browser;
    SFYTEngineState _state;
    NSUInteger _run;              // browser runs; stale callbacks of an earlier run are ignored
    NSUInteger _page;             // engine pages seen (a reload is a new page)
    NSDate *_launchedAt;
    NSInteger _failures;          // consecutive short runs
    NSTimeInterval _nextStartAt;  // restart backoff (epoch)
    BOOL _startPending;           // a start waits for the backoff to end
    NSMutableArray *_waiting;     // ^(BOOL ready) blocks
    NSMutableArray *_preloads;    // times of recent focus preloads
}

+ (instancetype)shared {
    static SFYTEngine *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SFYTEngine new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("sofa.yt-engine", DISPATCH_QUEUE_SERIAL);
        _channel = [[SFYTChannel alloc] initWithQueue:_queue];
        _waiting = [NSMutableArray new];
        _preloads = [NSMutableArray new];
        __weak SFYTEngine *ws = self;
        _channel.onEvent = ^(NSDictionary *e) { SFMain(^{ [ws event:e]; }); };
        _server = [[SFLocalHTTP alloc] initWithName:@"yt-engine" queue:_queue maxBody:kMaxPost handler:^(SFHTTPExchange *x) {
            SFYTEngine *s = ws;
            if (!s || [s.channel handle:x]) return;
            if ([x.request.pathParts.firstObject isEqualToString:@"s"]) [s serveSession:x];
            else [x respondJSON:404 object:@{@"error": @"not found"}];
        }];
        // dev instances: their own profile (SFAppSupportDir is theirs) - never the real identity's state
        NSString *dir = [SFAppSupportDir() stringByAppendingPathComponent:@"youtube-engine"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        _browser = [[SFYTBrowser alloc] initWithProfile:[dir stringByAppendingPathComponent:@"profile"]];
        _browser.onExit = ^(NSString *why) { [ws runFailed:why]; };
    }
    return self;
}

- (BOOL)available { return _browser.available; }

#pragma mark Lifecycle

- (void)start {
    if (_state != SFYTEngineIdle || !self.available) return;
    if (SFSimulatedOffline()) return;   // dev test without network: the browser is a network client
    NSTimeInterval wait = _nextStartAt - [NSDate date].timeIntervalSince1970;
    if (wait > 0) {   // backing off after failed runs: start when it ends (callers keep waiting)
        if (_startPending) return;
        _startPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((wait + 0.1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->_startPending = NO;
            [self start];
        });
        return;
    }
    if (!_server.port && ![_server start]) return;
    _state = SFYTEngineStarting;
    _launchedAt = [NSDate date];
    NSUInteger run = ++_run;
    [_browser launchWithChannelPort:_server.port token:_channel.token done:^(BOOL ok) {
        if (!ok && run == self->_run) [self runFailed:@"browser did not start"];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLaunchTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (run == self->_run && self->_state == SFYTEngineStarting) [self runFailed:@"engine page not ready in time"];
    });
}

// After a crash nothing calls this: the extension closes Firefox once Sofa stays unreachable, and
// Xvfb ends with its last client.
- (void)stop {
    _state = SFYTEngineIdle;
    _run++;
    _nextStartAt = DBL_MAX;   // no restart
    [_browser stop];
}

// The run ended or is of no use: browser down, waiting callers told, restart after a backoff.
- (void)runFailed:(NSString *)why {
    if (_state == SFYTEngineIdle) return;
    SFLog(@"yt-engine: %@", why);
    BOOL wasReady = _state == SFYTEngineReady;
    _state = SFYTEngineIdle;
    _run++;
    [_browser stop];
    [_channel failAll:SFError(@"engine: the browser went away")];
    BOOL healthy = _launchedAt && -[_launchedAt timeIntervalSinceNow] > kHealthyRun;
    _failures = healthy ? 0 : _failures + 1;
    double delay = healthy ? 2 : MIN(600, 5 * pow(2, MAX(0, _failures - 1)));
    _nextStartAt = [NSDate date].timeIntervalSince1970 + delay;
    if (_failures > 1) SFLog(@"yt-engine: %ld short runs in a row - next start in %.0f s", (long)_failures, delay);
    [self tellWaiting:NO];
    if (wasReady) [[NSNotificationCenter defaultCenter] postNotificationName:SFYTEngineSessionsLostNotification object:self];
    if (!SFDevMode) [self start];   // after the backoff; dev instances on their next use
}

- (void)event:(NSDictionary *)e {
    NSString *type = str(e[@"type"]);
    if ([type isEqualToString:@"log"]) { SFLog(@"yt-engine: %@", e[@"line"]); return; }
    if ([type isEqualToString:@"block"]) { [[SFYTBreaker shared] recordState:dict(e[@"state"])]; return; }
    // ready: once per document the extension runs in; the engine's page is the youtube.com one
    if ([type isEqualToString:@"ready"] && [str(e[@"url"]) hasPrefix:@"https://www.youtube.com/"] && _state != SFYTEngineIdle) {
        if (_state == SFYTEngineReady) {   // a new document: the old page's sessions are gone
            SFLog(@"yt-engine: page reloaded - sessions lost");
            [[NSNotificationCenter defaultCenter] postNotificationName:SFYTEngineSessionsLostNotification object:self];
        }
        _state = SFYTEngineStarting;
        [self startPage:++_page polls:kPagePolls];
    }
}

// Waits for the page's ytcfg (health.onYouTube), then starts the engine in it.
- (void)startPage:(NSUInteger)page polls:(int)polls {
    [self request:@"health" args:@[] timeout:5 done:^(id h, NSError *e) { SFMain(^{
        if (page != self->_page || self->_state != SFYTEngineStarting) return;
        if (![dict(h)[@"onYouTube"] boolValue]) {
            if (polls <= 0) { [self runFailed:@"youtube.com page without its config"]; return; }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPagePoll * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self startPage:page polls:polls - 1]; });
            return;
        }
        NSData *bd = [NSData dataWithContentsOfFile:[SFYTBreaker filePath]];
        id block = bd ? [NSJSONSerialization JSONObjectWithData:bd options:0 error:nil] : nil;
        NSDictionary *cfg = @{@"base": [NSString stringWithFormat:@"http://127.0.0.1:%u", self->_server.port],
                              @"block": dict(block) ?: [NSNull null]};
        [self request:@"start" args:@[cfg] timeout:kCallTimeout done:^(id v, NSError *se) { SFMain(^{
            if (page != self->_page || self->_state != SFYTEngineStarting) return;
            if (se && se.code != 409) { [self runFailed:[@"engine start failed: " stringByAppendingString:se.localizedDescription]]; return; }
            self->_state = SFYTEngineReady;
            NSString *ua = str(dict(v)[@"userAgent"]) ?: str(dict(h)[@"userAgent"]);
            SFLog(@"yt-engine: ready (%@)", ua);
            // the app's own requests to YouTube (thumbnails, avatars) as the same browser
            if (ua) SFSetUserAgentForDomains(ua, @[@"youtube.com", @"ytimg.com", @"ggpht.com", @"googlevideo.com", @"googleusercontent.com"]);
            [self tellWaiting:YES];
        }); }];
    }); }];
}

- (void)tellWaiting:(BOOL)ready {
    NSArray *w = [_waiting copy];
    [_waiting removeAllObjects];
    for (void (^b)(BOOL) in w) b(ready);
}

// Calls back once the engine is ready (YES) or could not get there in time (NO). Main thread.
- (void)whenReady:(void (^)(BOOL ready))block {
    if (_state == SFYTEngineReady) { block(YES); return; }
    [self start];
    if (_state == SFYTEngineIdle && !_startPending) { block(NO); return; }
    __block BOOL called = NO;
    void (^once)(BOOL) = ^(BOOL ok) { if (called) return; called = YES; block(ok); };
    [_waiting addObject:[once copy]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReadyTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!called) SFLog(@"yt-engine: not ready after %.0f s", kReadyTimeout);
        once(NO);
    });
}

#pragma mark Calls

- (void)request:(NSString *)method args:(NSArray *)args timeout:(NSTimeInterval)timeout done:(void (^)(id, NSError *))done {
    [_channel call:method args:args timeout:timeout done:^(id reply, NSError *e) {
        if (e) { done(nil, [NSError errorWithDomain:@"SFYTEngine" code:504 userInfo:@{NSLocalizedDescriptionKey: e.localizedDescription, @"unanswered": @YES}]); return; }
        NSDictionary *r = dict(reply);
        if (!r || ![r objectForKey:@"ok"]) { done(reply, nil); return; }   // a plain value (health)
        if ([r[@"ok"] boolValue]) { done(nn(r[@"value"]), nil); return; }
        NSMutableDictionary *info = [dict(r[@"body"]) mutableCopy] ?: [NSMutableDictionary new];
        info[NSLocalizedDescriptionKey] = [str(info[@"error"]) ?: @"engine error" copy];
        done(nil, [NSError errorWithDomain:@"SFYTEngine" code:[r[@"status"] integerValue] userInfo:info]);
    }];
}

// A call once the engine is ready; done on the main thread.
- (void)call:(NSString *)method args:(NSArray *)args timeout:(NSTimeInterval)timeout done:(void (^)(id, NSError *))done {
    [self whenReady:^(BOOL ready) {
        if (!ready) { done(nil, [NSError errorWithDomain:@"SFYTEngine" code:503 userInfo:@{NSLocalizedDescriptionKey: @"YouTube startet gerade.", @"unanswered": @YES}]); return; }
        [self request:method args:args timeout:timeout done:^(id v, NSError *e) { SFMain(^{ done(v, e); }); }];
    }];
}

// JSON null -> key absent: the player code treats every value as a string/number
static id Clean(id v) {
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary new];
        [(NSDictionary *)v enumerateKeysAndObjectsUsingBlock:^(id k, id o, BOOL *stop) { if (o != [NSNull null]) d[k] = Clean(o); }];
        return d;
    }
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray new];
        for (id o in v) if (o != [NSNull null]) [a addObject:Clean(o)];
        return a;
    }
    return v;
}

- (void)open:(NSString *)vid background:(BOOL)bg done:(void (^)(NSDictionary *, NSError *))done {
    // prefetch off: mpv's own reads (at the resume position) drive what SABR pulls
    [self open:vid request:@{@"v": vid ?: @"", @"bg": @(bg), @"maxHeight": @1080, @"lang": @"de", @"prefetch": @NO} done:done];
}

- (void)openForDownload:(NSString *)vid done:(void (^)(NSDictionary *, NSError *))done {
    [self open:vid request:@{@"v": vid ?: @"", @"bg": @YES, @"maxHeight": @1080, @"lang": @"de", @"prefetch": @NO} done:done];
}

- (void)open:(NSString *)vid request:(NSDictionary *)req done:(void (^)(NSDictionary *, NSError *))done {
    if (!vid.length) { done(nil, SFError(@"Video nicht abspielbar.")); return; }
    NSDate *t0 = [NSDate date];
    [self call:@"open" args:@[req] timeout:kOpenTimeout done:^(id v, NSError *e) {
        NSDictionary *j = dict(v);
        BOOL playable = str(j[@"video"]) || str(j[@"hls"]);
        if (e || j[@"error"] || !playable) {
            NSMutableDictionary *info = [(e ? e.userInfo : j) mutableCopy] ?: [NSMutableDictionary new];
            NSString *msg = str(info[@"error"]) ?: e.localizedDescription ?: @"no video";
            SFLog(@"yt-engine: open %@ failed: %@%@", vid, msg, [info[@"bot"] boolValue] ? @" (bot check)" : @"");
            if ([info[@"bot"] boolValue]) [[SFYTBreaker shared] noteBlockedUntil:[info[@"blocked_until"] doubleValue]];
            info[NSLocalizedDescriptionKey] = msg;
            done(nil, [NSError errorWithDomain:@"SFYTEngine" code:1 userInfo:Clean(info)]);
            return;
        }
        if (j[@"hls"]) SFLog(@"yt-engine: opened %@ -> %@ HLS %@p%@ in %.1fs%@", vid, [j[@"live"] boolValue] ? @"live" : @"post-live",
                             j[@"height"], j[@"fps"], -[t0 timeIntervalSinceNow], [j[@"cached"] boolValue] ? @" (cached)" : @"");
        else SFLog(@"yt-engine: opened %@ -> %@p%@ %@/%@ audio %@ in %.1fs%@", vid, j[@"height"], j[@"fps"], j[@"vcodec"], j[@"acodec"],
                   str(j[@"alang"]) ?: @"?", -[t0 timeIntervalSinceNow], [j[@"cached"] boolValue] ? @" (cached)" : @"");
        done(Clean(j), nil);
    }];
}

- (BOOL)preloadOnFocus:(NSString *)vid {
    if (!vid.length || !self.available || [SFYTBreaker shared].blockedUntil) return NO;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    while (_preloads.count && now - [_preloads[0] doubleValue] > kPreloadWindow) [_preloads removeObjectAtIndex:0];
    if (_preloads.count >= kPreloadBudget) return NO;
    [_preloads addObject:@(now)];
    // the engine caches the player response: the click then opens without a player request
    [self open:vid background:YES done:^(NSDictionary *r, NSError *e) {}];
    return YES;
}

- (void)closeSession:(NSString *)sid {
    if (!sid.length || _state != SFYTEngineReady) return;
    [self request:@"close" args:@[sid] timeout:kCallTimeout done:^(id v, NSError *e) {}];
}

- (void)sessionStatus:(NSString *)sid done:(void (^)(NSDictionary *))done {
    if (!sid.length || _state != SFYTEngineReady) { done(nil); return; }
    // a hanging engine must not hold up the player's decision
    [self request:@"status" args:@[sid] timeout:3 done:^(id v, NSError *e) { SFMain(^{ done(dict(v)); }); }];
}

- (void)innertube:(NSString *)endpoint body:(NSDictionary *)body background:(BOOL)bg done:(void (^)(id, NSError *))done {
    [self call:@"innertube" args:@[endpoint, body ?: @{}, @{@"bg": @(bg)}] timeout:kCallTimeout done:done];
}

- (void)suggest:(NSString *)prefix done:(void (^)(id, NSError *))done {
    [self call:@"suggest" args:@[prefix ?: @""] timeout:10 done:done];
}
@end
