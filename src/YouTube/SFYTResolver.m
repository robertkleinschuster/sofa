#import "SFYTResolver.h"
#import "SFYTSabr.h"
#import "SFYTBreaker.h"
#import "SFStats.h"
#import "SFEngine.h"
#import "SFSettings.h"
#import "SFCurl.h"
#import "SFModel.h"
#import "SFStore.h"
#import "SFRuntime.h"

// yt-dlp comes as the official zipapp (contains yt-dlp-ejs) - no venv, no pip:
//  - Base install in the app bundle (Resources/yt-dlp, res/ytdlp.lock); PO tokens via Sofa's own
//    provider plugin (Resources/yt-dlp-plugins), which asks the sofa-yt sidecar.
//  - Sofa fetches newer yt-dlp releases itself (daily) into Application Support/Sofa/yt-dlp.
//    Network without TLS certificate verification (user decision 2026-11-04); authenticity is ensured
//    by the yt-dlp maintainers' signature over SHA2-256SUMS (res/ytdlp_verify.py, key in the bundle).
//  - The newer of the two versions is active.
// Base Python: in the release bundle Contents/Runtime/python, otherwise MacPorts python314 (SFRuntime)
#define kBasePython SFPythonPath()
static NSString *const kUpdatedKey = @"ytdlp.updated";
static const NSTimeInterval kUpdateEvery = 24 * 3600;
static NSString *const kReleaseAPI = @"https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest";

// Runs synchronously (call only in the background); returns the exit status, *out = stdout+stderr.
// If a run hangs longer than `timeout`, it is terminated.
static int YTRun(NSString *path, NSArray *args, NSString **out, NSTimeInterval timeout) {
    // PYTHONPATH must not leak into the bundled Python; SFRunProcess handles timeout and DYLD
    NSString *pp = [[NSProcessInfo processInfo] environment][@"PYTHONPATH"];
    if (pp) unsetenv("PYTHONPATH");
    NSData *d = nil;
    int st = SFRunProcess(path, args, timeout, YES, &d);
    if (st == -2) SFLog(@"yt: %@ timed out after %.0f s and was killed", path.lastPathComponent, timeout);
    if (out) *out = [[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
    return st;
}
static NSString *YTTail(NSString *s) { return s.length > 400 ? [s substringFromIndex:s.length - 400] : s; }
static NSString *YTTrim(NSString *s) { return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; }
// compare yt-dlp versions "2026.10.26", "2026.10.26.1" ... numerically per part
static NSComparisonResult YTCompare(NSString *a, NSString *b) {
    NSArray *x = [a componentsSeparatedByString:@"."], *y = [b componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MAX(x.count, y.count); i++) {
        long long p = i < x.count ? [x[i] longLongValue] : 0, q = i < y.count ? [y[i] longLongValue] : 0;
        if (p != q) return p < q ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}
static BOOL YTValidVersion(NSString *v) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{4}\\.[0-9]{1,2}\\.[0-9]{1,2}(\\.[0-9]+)?$" options:0 error:NULL];
    return v && [re numberOfMatchesInString:v options:0 range:NSMakeRange(0, v.length)] == 1;
}
static NSString *YTBundledDir(void) { return [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"yt-dlp"]; }
// Tests: SOFA_YTDLP_DIR = separate update folder (allows the updater in dev instances too)
static NSString *YTTestDir(void) { return [NSProcessInfo processInfo].environment[@"SOFA_YTDLP_DIR"]; }
static NSString *YTUpdateDir(void) { return YTTestDir().length ? YTTestDir() : [SFAppSupportDir() stringByAppendingPathComponent:@"yt-dlp"]; }
static NSString *YTDirVersion(NSString *dir) {
    NSString *v = YTTrim([NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"VERSION"] encoding:NSUTF8StringEncoding error:NULL] ?: @"");
    BOOL ok = YTValidVersion(v) && [[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:@"yt-dlp"]];
    return ok ? v : nil;
}
// folder of the active yt-dlp version: the update if newer than the base install
static NSString *YTActiveDir(void) {
    NSString *b = YTBundledDir(), *u = YTUpdateDir();
    NSString *bv = YTDirVersion(b), *uv = YTDirVersion(u);
    if (uv && (!bv || YTCompare(uv, bv) == NSOrderedDescending)) return u;
    return bv ? b : nil;
}

@implementation SFYTResolver {
    NSTask *_task;
    NSFileHandle *_in;
    NSMutableData *_buf, *_ebuf;
    NSMutableDictionary *_pending;    // rid -> @[key, vid, prio]
    NSMutableDictionary *_waiters;    // key (vid or live:vid) -> callbacks; one resolution per video
    NSMutableSet *_prioKeys;          // keys with a playback request already running
    NSMutableDictionary *_cache;      // vid -> result (until expires - 1 h)
    NSInteger _rid;
    NSTimer *_idleTimer;              // ends the process when nothing was asked for a while
    BOOL _updating;                   // yt-dlp update running
    NSTimer *_updateTimer;
}

// The fallback runs on demand: Python + yt-dlp (~85 MB) only while it is needed, and a while
// longer for follow-up requests (a reopen, the next download).
static const NSTimeInterval kIdleExit = 600;

+ (instancetype)shared {
    static SFYTResolver *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFYTResolver new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _pending = [NSMutableDictionary new];
        _waiters = [NSMutableDictionary new];
        _prioKeys = [NSMutableSet new];
        _cache = [NSMutableDictionary new];
        [self loadSavedCache];
    }
    return self;
}

// Carry the result cache over an update restart: the resumed video then starts without
// a new resolution (~5 s). Readable once only (the file is deleted), expired entries are dropped.
static const NSInteger kResultVersion = 2;   // = RESULT_VERSION in ytresolver.py
+ (NSString *)savedCachePath { return [SFCacheDir() stringByAppendingPathComponent:@"yt-resolved.json"]; }
- (void)loadSavedCache {
    if (SFDevMode) return;   // dev instances share the folder with the real app -> don't touch
    NSString *path = [SFYTResolver savedCachePath];
    NSData *d = [NSData dataWithContentsOfFile:path];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSDictionary *c = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![c isKindOfClass:[NSDictionary class]]) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    [c enumerateKeysAndObjectsUsingBlock:^(NSString *vid, NSDictionary *r, BOOL *stop) {
        // only results of the current resolver version (older ones may have the wrong audio track)
        if ([r isKindOfClass:[NSDictionary class]] && [r[@"expires"] doubleValue] - 3600 > now && [r[@"v"] integerValue] >= kResultVersion)
            self->_cache[vid] = r;
    }];
    if (_cache.count) SFLog(@"yt: %lu resolutions carried over from the last run", (unsigned long)_cache.count);
}
- (void)saveCache {
    if (!_cache.count || SFDevMode) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:_cache options:0 error:nil];
    NSString *path = [SFYTResolver savedCachePath];
    if (d && [d writeToFile:path atomically:YES])
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
}

// App start: housekeeping and the yt-dlp update schedule. The process itself starts with the first
// request (-launch).
- (void)start {
    // YouTube cookies formerly copied from Firefox (sign-in no longer exists) -> delete the copy
    static dispatch_once_t cleanup;
    dispatch_once(&cleanup, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:[SFAppSupportDir() stringByAppendingPathComponent:@"youtube-cookies.txt"] error:nil];
        // former venv (yt-dlp via pip, up to 0.2.x) is no longer needed - not from dev instances
        if (!SFDevMode) SFBackground(^{
            for (NSString *n in @[@"ytdlp", @"ytdlp.new", @"ytdlp.old"])
                [fm removeItemAtPath:[SFAppSupportDir() stringByAppendingPathComponent:n] error:nil];
        });
    });
    signal(SIGPIPE, SIG_IGN);   // writing into a dead pipe must not kill the app
    if (!_updateTimer) {   // Sofa runs for weeks -> check regularly whether an update is due
        _updateTimer = [NSTimer scheduledTimerWithTimeInterval:6 * 3600 target:self
                                                      selector:@selector(updateTick:) userInfo:nil repeats:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((YTTestDir().length ? 5 : 120) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self updateYTDLP];   // only after the start, not in the middle of starting up
        });
    }
}

- (void)launch {
    if (_task.isRunning) return;
    NSString *py = kBasePython, *ytdir = YTActiveDir();
    NSString *script = [[NSBundle mainBundle] pathForResource:@"ytresolver" ofType:@"py"];
    if (!script || !ytdir) { SFLog(@"yt: ytresolver.py or yt-dlp missing from the bundle"); return; }
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:py]) { SFLog(@"yt: %@ missing - YouTube not possible", py); return; }
    NSString *cache = [SFCacheDir() stringByAppendingPathComponent:@"yt-dlp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    NSTask *t = [NSTask new];
    t.launchPath = py;
    t.arguments = @[@"-s", script, cache];   // -s: no packages from ~/Library/Python
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    env[@"PYTHONUNBUFFERED"] = @"1";
    // yt-dlp from the zipapp (bundle or update), Sofa's PO token plugin always from the bundle
    env[@"PYTHONPATH"] = [NSString stringWithFormat:@"%@:%@", [ytdir stringByAppendingPathComponent:@"yt-dlp"],
                          [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"yt-dlp-plugins"]];
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
    SFLog(@"yt: fallback resolver started pid %d (yt-dlp %@%@)", t.processIdentifier, YTDirVersion(ytdir),
          [ytdir isEqualToString:YTBundledDir()] ? @", Grundausstattung" : @"");
}

- (void)updateTick:(NSTimer *)t { [self updateYTDLP]; }

// Fetch a newer yt-dlp release (at most daily): download, verify signature + checksum, trial run,
// then swap it into Application Support and restart the resolver as soon as it is idle.
// Without TLS verification - only the signature counts (res/ytdlp_verify.py).
- (void)updateYTDLP {
    BOOL test = YTTestDir().length > 0;
    if (_updating || (SFDevMode && !test)) return;   // dev instances share the folder with the real app
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!test && now - [[[SFStore shared] setting:kUpdatedKey] doubleValue] < kUpdateEvery) return;
    NSString *py = kBasePython;
    NSString *verify = [[NSBundle mainBundle] pathForResource:@"ytdlp_verify" ofType:@"py"];
    NSString *key = [[NSBundle mainBundle] pathForResource:@"yt-dlp-public" ofType:@"key"];
    if (!verify || !key || ![[NSFileManager defaultManager] isExecutableFileAtPath:py]) return;
    _updating = YES;
    SFBackground(^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *have = YTDirVersion(YTActiveDir()), *out = nil, *err = nil;
        NSInteger st = 0; NSError *e = nil;
        NSData *d = SFCurlFetch(kReleaseAPI, @"GET", @{@"Accept": @"application/vnd.github+json"}, nil, &st, &e);
        id j = d && st == 200 ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
        NSString *tag = [j isKindOfClass:[NSDictionary class]] && [j[@"tag_name"] isKindOfClass:[NSString class]] ? j[@"tag_name"] : nil;
        NSString *dir = YTUpdateDir(), *tmp = [dir stringByAppendingString:@".new"], *old = [dir stringByAppendingString:@".old"];
        BOOL ok = NO, newer = NO;
        if (!YTValidVersion(tag)) err = [NSString stringWithFormat:@"release query: HTTP %ld %@", (long)st, e.localizedDescription ?: @""];
        else if (have && YTCompare(tag, have) != NSOrderedDescending) ok = YES;   // up to date
        else {
            newer = YES;
            [fm removeItemAtPath:tmp error:nil];
            [fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *base = [@"https://github.com/yt-dlp/yt-dlp/releases/download/" stringByAppendingString:tag];
            for (NSString *f in @[@"yt-dlp", @"SHA2-256SUMS", @"SHA2-256SUMS.sig"]) {
                if (!SFCurlDownload([base stringByAppendingPathComponent:f], [tmp stringByAppendingPathComponent:f], &e)) {
                    err = [NSString stringWithFormat:@"Download %@: %@", f, e.localizedDescription]; break;
                }
            }
            NSString *zip = [tmp stringByAppendingPathComponent:@"yt-dlp"];
            if (!err && YTRun(py, @[@"-I", verify, key, [tmp stringByAppendingPathComponent:@"SHA2-256SUMS"],
                                    [tmp stringByAppendingPathComponent:@"SHA2-256SUMS.sig"], zip, @"yt-dlp"], &out, 60) != 0)
                err = [@"signature check: " stringByAppendingString:YTTrim(out)];
            if (!err && (YTRun(py, @[@"-s", zip, @"--version"], &out, 60) != 0 || ![YTTrim(out) isEqualToString:tag]))
                err = [@"trial run: " stringByAppendingString:YTTail(YTTrim(out))];
            if (!err) {
                [tag writeToFile:[tmp stringByAppendingPathComponent:@"VERSION"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                for (NSString *f in @[@"SHA2-256SUMS", @"SHA2-256SUMS.sig"]) [fm removeItemAtPath:[tmp stringByAppendingPathComponent:f] error:nil];
                // swap: the running resolver has the old zipapp open and reads from it until the restart
                [fm removeItemAtPath:old error:nil];
                BOOL present = [fm fileExistsAtPath:dir];
                if (present) [fm moveItemAtPath:dir toPath:old error:nil];
                ok = [fm moveItemAtPath:tmp toPath:dir error:nil];
                if (!ok && present) [fm moveItemAtPath:old toPath:dir error:nil];
                if (!ok) err = @"swap failed";
            }
            [fm removeItemAtPath:tmp error:nil];
        }
        SFMain(^{
            self->_updating = NO;
            if (!ok) { SFLog(@"yt: yt-dlp update failed: %@", err); return; }   // next attempt on the next tick
            if (!test) [[SFStore shared] setSetting:[NSString stringWithFormat:@"%.0f", now] forKey:kUpdatedKey];
            if (!newer) return;
            SFLog(@"yt: yt-dlp %@ installed (previously %@), signature verified", tag, have ?: @"-");
            [self restartWhenIdle];
        });
    });
}

// Adopt a new yt-dlp version without aborting a running resolution
- (void)restartWhenIdle {
    if (_pending.count) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self restartWhenIdle]; });
        return;
    }
    if (_task.isRunning) { SFLog(@"yt: resolver ends for the new yt-dlp version (next request starts it)"); [self retireTask]; }
}

// End the process without letting a request slip into it: detach first (a request right after this
// starts a fresh process instead of writing into the dying one), then terminate. Only when idle.
- (void)retireTask {
    NSTask *t = _task;
    ((NSPipe *)t.standardOutput).fileHandleForReading.readabilityHandler = nil;
    ((NSPipe *)t.standardError).fileHandleForReading.readabilityHandler = nil;
    _task = nil; _in = nil;
    [_idleTimer invalidate]; _idleTimer = nil;
    [t terminate];
}

- (void)armIdleExit {
    [_idleTimer invalidate];
    _idleTimer = [NSTimer scheduledTimerWithTimeInterval:kIdleExit target:self selector:@selector(idleExit:) userInfo:nil repeats:NO];
}
- (void)idleExit:(NSTimer *)t {
    _idleTimer = nil;
    if (_pending.count) { [self armIdleExit]; return; }
    if (_task.isRunning) { SFLog(@"yt: fallback resolver idle - ending it"); [self retireTask]; }
}

- (void)terminated:(NSTask *)t {
    if (t != _task) return;
    SFLog(@"yt: resolver exited (%d)", t.terminationStatus);
    ((NSPipe *)t.standardOutput).fileHandleForReading.readabilityHandler = nil;
    ((NSPipe *)t.standardError).fileHandleForReading.readabilityHandler = nil;
    _task = nil; _in = nil;
    [_pending removeAllObjects];
    // first collect and clear everything, then call back: a callback may request again right away
    NSDictionary *w = [_waiters copy];
    [_waiters removeAllObjects]; [_prioKeys removeAllObjects];
    NSError *err = SFError(@"YouTube-Auflösung abgebrochen.");
    for (NSString *key in w) for (void (^done)(NSDictionary *, NSError *) in w[key]) done(nil, err);
    [_idleTimer invalidate]; _idleTimer = nil;
    // no restart here: the next request starts it again (a crash loop costs one try per request)
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
        if (j[@"ready"]) continue;
        NSNumber *rid = j[@"rid"];
        NSArray *p = rid ? _pending[rid] : nil;
        if (!p) continue;
        [_pending removeObjectForKey:rid];
        NSString *key = p[0], *vid = p[1];
        if ([j[@"blocked_until"] doubleValue] > 0) [[SFYTBreaker shared] noteBlockedUntil:[j[@"blocked_until"] doubleValue]];
        SFCount([j[@"url"] isKindOfClass:[NSString class]] ? @"yt.ytdlp.ok" : @"yt.ytdlp.failed");
        if ([j[@"url"] isKindOfClass:[NSString class]]) {
            SFLog(@"yt: resolved %@ -> %@p %@ in %.1fs (%@)", vid, j[@"height"], j[@"format"], [j[@"secs"] doubleValue], j[@"pool"]);
            if (![key hasPrefix:@"live:"]) _cache[vid] = j;
            // playlist into the local proxy right away (also when preloading on focus): start without a network fetch
            if ([j[@"url"] isKindOfClass:[NSString class]]) [[SFStreamProxy shared] warmPlaylist:[NSURL URLWithString:j[@"url"]]];
            [self finish:key result:j error:nil];
        } else {
            SFLog(@"yt: resolve %@ failed: %@", vid, j[@"error"]);
            // playback failed -> report right away; only a failed preload waits for a still
            // running playback request for the same video
            if ([p[2] boolValue] || ![self hasPending:key]) [self finish:key result:nil error:SFError([self friendly:j[@"error"]])];
        }
    }
}

- (NSString *)friendly:(NSString *)e {
    if (![e isKindOfClass:[NSString class]]) return @"Video nicht abspielbar.";
    NSString *l = e.lowercaseString;
    if ([l rangeOfString:@"private"].location != NSNotFound) return @"Dieses Video ist privat.";
    if ([l rangeOfString:@"age"].location != NSNotFound && [l rangeOfString:@"confirm"].location != NSNotFound) return @"Dieses Video ist altersbeschränkt und kann hier nicht abgespielt werden.";
    if ([l rangeOfString:@"premiere"].location != NSNotFound || [l rangeOfString:@"live event will begin"].location != NSNotFound) return @"Dieser Livestream hat noch nicht begonnen.";
    // YouTube throttles at times ("Sign in to confirm you're not a bot") - temporary, don't circumvent
    if ([l rangeOfString:@"not a bot"].location != NSNotFound) return @"YouTube lässt gerade keine Wiedergabe zu – bitte in ein paar Minuten noch einmal versuchen.";
    if ([l rangeOfString:@"playback on other websites has been disabled"].location != NSNotFound) return @"Der Kanal erlaubt dieses Video nur auf youtube.com.";
    if ([l rangeOfString:@"unavailable"].location != NSNotFound || [l rangeOfString:@"nicht verfügbar"].location != NSNotFound) return @"Video nicht verfügbar.";
    if ([l hasPrefix:@"youtube startet"]) return e;   // our own message
    return @"YouTube liefert dieses Video gerade nicht aus.";   // the original text is in the log (yt: resolve ... failed)
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
    if (c && [c[@"expires"] doubleValue] - 3600 > [[NSDate date] timeIntervalSince1970] && !live) {
        if (prio) [[SFStreamProxy shared] warmPlaylist:[NSURL URLWithString:c[@"url"]]];
        done(c, nil); return;
    }
    [self launch];
    [self armIdleExit];
    if (!_in) {
        done(nil, SFError(@"YouTube startet gerade – bitte gleich noch einmal versuchen."));
        return;
    }
    NSString *key = live ? [@"live:" stringByAppendingString:vid] : vid;
    NSMutableArray *w = _waiters[key];
    if (w) {   // the same video is already being resolved (e.g. preload on focus) -> wait along
        [w addObject:[done copy]];
        if (!prio || [_prioKeys containsObject:key]) return;
        // only a preload in flight: additionally request as playback - the resolver overtakes
        // a still waiting preload or attaches to a running one
    } else {
        _waiters[key] = [NSMutableArray arrayWithObject:[done copy]];
    }
    if (prio) [_prioKeys addObject:key];
    NSNumber *rid = @(++_rid);
    _pending[rid] = @[key, vid, @(prio)];
    // pot: where the PO token plugin asks (the sidecar; its port changes with every sidecar start)
    NSData *line = [NSJSONSerialization dataWithJSONObject:@{@"rid": rid, @"vid": vid, @"live": @(live), @"prio": @(prio),
                                                             @"pot": [SFYTSabr shared].baseURL ?: @""} options:0 error:nil];
    NSMutableData *m = [line mutableCopy]; [m appendBytes:"\n" length:1];
    @try { [_in writeData:m]; }
    @catch (NSException *ex) {
        [_pending removeObjectForKey:rid];
        if (![self hasPending:key]) [self finish:key result:nil error:SFError(@"YouTube-Auflösung nicht erreichbar.")];
        return;
    }
    // time limit: first run after a player rollout ~25 s, afterwards ~3 s
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_pending[rid]) return;
        [self->_pending removeObjectForKey:rid];
        if (![self hasPending:key]) [self finish:key result:nil error:SFError(@"YouTube antwortet nicht.")];
    });
}
- (void)forget:(NSString *)videoID { if (videoID) [_cache removeObjectForKey:videoID]; }

@end
