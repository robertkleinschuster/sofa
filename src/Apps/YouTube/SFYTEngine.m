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
// a call timed out: the page must answer this liveness check within this time, or it hangs - long:
// a page starved of CPU (software video decode next to it) answers late but is not stuck
static const NSTimeInterval kAliveTimeout = 30;
// at most one restart for an unresponsive page in this time: every restart is a new page and a new
// BotGuard attestation for YouTube (2026-11-07: three within minutes -> bot check)
static const NSTimeInterval kUnresponsiveRestartGap = 15 * 60;
// the consent dialog is read for a moment before it is answered (seconds, uniform)
static const double kConsentReadMin = 2.5, kConsentReadMax = 5.5;

typedef NS_ENUM(NSInteger, SFYTEngineState) { SFYTEngineIdle, SFYTEngineStarting, SFYTEngineReady };

@implementation SFYTEngine {
    SFLocalHTTP *_server;
    NSString *_channelFile;       // the channel's port and token, kept across starts (startServer)
    NSDictionary *_savedChannel;  // {port, token} as in the file
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
    BOOL _consentPending;         // a consent click is scheduled or in progress
    BOOL _aliveCheck;             // a liveness check after a timed-out call is running
    NSDate *_unresponsiveRestartAt;   // the last restart for an unresponsive page
}

+ (instancetype)shared {
    static SFYTEngine *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SFYTEngine new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("sofa.yt-engine", DISPATCH_QUEUE_SERIAL);
        // dev instances: their own profile (SFAppSupportDir is theirs) - never the real identity's state
        NSString *dir = [SFAppSupportDir() stringByAppendingPathComponent:@"youtube-engine"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        _channelFile = [dir stringByAppendingPathComponent:@"channel.json"];
        NSData *cd = [NSData dataWithContentsOfFile:_channelFile];
        _savedChannel = dict(cd ? [NSJSONSerialization JSONObjectWithData:cd options:0 error:nil] : nil);
        NSString *token = str(_savedChannel[@"token"]);
        _channel = [[SFYTChannel alloc] initWithQueue:_queue token:token.length == 32 ? token : SFYTChannelNewToken()];
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
        _browser = [[SFYTBrowser alloc] initWithProfile:[dir stringByAppendingPathComponent:@"profile"]];
        _browser.onExit = ^(NSString *why) { [ws runFailed:why]; };
    }
    return self;
}

- (BOOL)available { return _browser.available; }

#pragma mark Lifecycle

// The channel's address goes into the extension's config.json; it stays the same on every start
// (the last port again, the token kept in channel.json), so the installed extension changes only
// with a new build. A changed extension is an update to Firefox: it restarts the extension and runs
// its content scripts once more in the already loaded page - a second engine, which Sofa rightly
// takes for a new page, every session dropped, at every start (a new token each launch did that,
// 2026-11-07; seen as "page reloaded (navigate, injected late)").
- (BOOL)startServer {
    uint16_t saved = (uint16_t)num(_savedChannel[@"port"]).unsignedIntValue;
    if (![_server startPreferringPort:saved]) return NO;
    NSDictionary *now = @{@"port": @(_server.port), @"token": _channel.token};
    if (![now isEqualToDictionary:_savedChannel]) {
        if (saved && saved != _server.port) SFLog(@"yt-engine: channel port %u taken - now %u (the extension is updated once)", saved, _server.port);
        NSData *d = [NSJSONSerialization dataWithJSONObject:now options:0 error:nil];
        if ([d writeToFile:_channelFile atomically:YES])   // the token: the owner only
            [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:_channelFile error:nil];
        _savedChannel = now;
    }
    return YES;
}

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
    if (!_server.port && ![self startServer]) return;
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
    if ([type isEqualToString:@"consent"]) { [self acceptConsent:e]; return; }
    // ready: once per document the extension runs in; the engine's page is the youtube.com one
    if ([type isEqualToString:@"ready"] && [str(e[@"url"]) hasPrefix:@"https://www.youtube.com/"] && _state != SFYTEngineIdle) {
        BOOL wasReady = _state == SFYTEngineReady;
        // starting again BEFORE anyone hears of it: a player that reopens on the notification must
        // wait for the new document's engine - it used to be sent to it before its start ("engine
        // not started", the video stopped after an update restart, 2026-11-07)
        _state = SFYTEngineStarting;
        if (wasReady) {   // a new document: the old page's sessions are gone
            SFLog(@"yt-engine: page reloaded (%@%@, %@) - sessions lost", str(e[@"navigation"]) ?: @"?",
                  [e[@"late"] boolValue] ? @", injected late" : @"", str(e[@"url"]));
            // and its calls: one it had fetched would wait out its whole timeout (an open: 60 s,
            // seen 2026-11-07) for an answer no document will send
            [_channel failAll:[NSError errorWithDomain:SFYTChannelErrorDomain code:SFYTChannelPageGone
                                              userInfo:@{NSLocalizedDescriptionKey: @"engine: the page reloaded"}]];
            [[NSNotificationCenter defaultCenter] postNotificationName:SFYTEngineSessionsLostNotification object:self];
        }
        [self startPage:++_page polls:kPagePolls];
    }
}

// The EU consent dialog of a fresh profile (consent.ts reports its accept button): accepted once,
// as a user does - read for a moment, then clicked with the display's pointer, a trusted event.
// Accept, not reject: a profile that accepted keeps a lasting visitor identity, one that rejected
// starts from nothing on every visit (user decision 2026-11-07). The page reports the button again
// while it stays; whatever follows (a reload) is handled as any reload.
- (void)acceptConsent:(NSDictionary *)e {
    NSNumber *x = num(e[@"x"]), *y = num(e[@"y"]), *w = num(e[@"width"]), *h = num(e[@"height"]);
    if (_consentPending || !x || !y || w.doubleValue < 4 || h.doubleValue < 4) return;
    CGRect rect = CGRectMake(x.doubleValue, y.doubleValue, w.doubleValue, h.doubleValue);
    _consentPending = YES;
    NSUInteger run = _run;
    double read = kConsentReadMin + (kConsentReadMax - kConsentReadMin) * arc4random_uniform(1000) / 1000.0;
    SFLog(@"yt-engine: consent dialog - accepting in %.1f s", read);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(read * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (run != self->_run) { self->_consentPending = NO; return; }
        [self->_browser clickInRect:rect done:^(BOOL ok) {
            self->_consentPending = NO;
            SFLog(ok ? @"yt-engine: consent accepted (click)" : @"yt-engine: consent click failed");
        }];
    });
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
        if (e) {
            if ([e.domain isEqualToString:SFYTChannelErrorDomain] && e.code == SFYTChannelTimedOut && ![method isEqualToString:@"health"])
                SFMain(^{ [self checkAliveAfter:method]; });
            done(nil, [NSError errorWithDomain:@"SFYTEngine" code:504 userInfo:@{NSLocalizedDescriptionKey: e.localizedDescription, @"unanswered": @YES}]);
            return;
        }
        NSDictionary *r = dict(reply);
        if (!r || ![r objectForKey:@"ok"]) { done(reply, nil); return; }   // a plain value (health)
        if ([r[@"ok"] boolValue]) { done(nn(r[@"value"]), nil); return; }
        NSMutableDictionary *info = [dict(r[@"body"]) mutableCopy] ?: [NSMutableDictionary new];
        info[NSLocalizedDescriptionKey] = [str(info[@"error"]) ?: @"engine error" copy];
        done(nil, [NSError errorWithDomain:@"SFYTEngine" code:[r[@"status"] integerValue] userInfo:info]);
    }];
}

// A call went unanswered. That alone proves nothing (a read waits for data, a page short of CPU
// answers late); a page that does not even answer health within kAliveTimeout hangs (incident
// 2026-11-07 08:28: every open stalled for minutes) - its browser is restarted like one that died,
// at most once per kUnresponsiveRestartGap: restarts are what YouTube sees (08:44-08:46: three
// 5-s-check restarts, then a bot check). What the browser was doing goes to the log either way.
// Hangs inside a live page are the engine's own deadlines' (lib/webpo.ts, youtube.ts).
- (void)checkAliveAfter:(NSString *)method {
    if (_state != SFYTEngineReady || _aliveCheck) return;
    _aliveCheck = YES;
    NSUInteger run = _run;
    [self request:@"health" args:@[] timeout:kAliveTimeout done:^(id h, NSError *e) { SFMain(^{
        self->_aliveCheck = NO;
        if (run != self->_run || !e) return;
        SFLog(@"yt-engine: page unresponsive (no answer to %@, nor to health within %.0f s); browser: %@",
              method, kAliveTimeout, [self->_browser processSnapshot] ?: @"-");
        if (self->_unresponsiveRestartAt && -[self->_unresponsiveRestartAt timeIntervalSinceNow] < kUnresponsiveRestartGap) {
            SFLog(@"yt-engine: no restart - the last one for an unresponsive page was %.0f s ago", -[self->_unresponsiveRestartAt timeIntervalSinceNow]);
            return;
        }
        self->_unresponsiveRestartAt = [NSDate date];
        [self runFailed:[NSString stringWithFormat:@"engine page unresponsive (no answer to %@, nor to health within %.0f s)", method, kAliveTimeout]];
    }); }];
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

- (void)availability:(NSString *)vid done:(void (^)(NSInteger))done {
    [self call:@"availability" args:@[vid ?: @""] timeout:kCallTimeout done:^(id v, NSError *e) {
        NSInteger st = [v isKindOfClass:[NSNumber class]] ? [v integerValue] : 0;
        done(st == 200 ? 1 : (st == 400 || st == 404) ? 0 : -1);
    }];
}
@end
