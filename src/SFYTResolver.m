#import "SFYTResolver.h"
#import "SFCurl.h"
#import "SFModel.h"
#import "SFStore.h"
#import "SFRuntime.h"

// yt-dlp kommt als offizielles Zipapp (enthält yt-dlp-ejs) – kein venv, kein pip:
//  - Grundausstattung im App-Bundle (Resources/yt-dlp, res/ytdlp.lock), dazu das bgutil-Plugin
//    passend zum mitgelieferten PO-Token-Server.
//  - Sofa holt neuere yt-dlp-Releases selbst (täglich) nach Application Support/Sofa/yt-dlp.
//    Netz ohne TLS-Zertifikatsprüfung (User-Entscheidung 2026-11-04); die Echtheit sichert die
//    Signatur der yt-dlp-Maintainer über SHA2-256SUMS (res/ytdlp_verify.py, Schlüssel im Bundle).
//  - Aktiv ist die neuere der beiden Versionen.
// Basis-Python: im Release-Bundle Contents/Runtime/python, sonst MacPorts python314 (SFRuntime)
#define kBasePython SFPythonPath()
static NSString *const kUpdatedKey = @"ytdlp.updated";
static const NSTimeInterval kUpdateEvery = 24 * 3600;
static NSString *const kReleaseAPI = @"https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest";

// Läuft synchron (nur im Hintergrund aufrufen); liefert Exit-Status, *out = stdout+stderr.
// Hängt ein Lauf länger als `timeout`, wird er beendet.
static int YTRun(NSString *path, NSArray *args, NSString **out, NSTimeInterval timeout) {
    NSTask *t = [NSTask new];
    t.launchPath = path; t.arguments = args;
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    [env removeObjectForKey:@"PYTHONPATH"];
    t.environment = env;
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p; t.standardError = p;
    @try { [t launch]; } @catch (NSException *e) { if (out) *out = e.reason; return -1; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ if (t.isRunning) [t terminate]; });
    NSData *d = [p.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    if (out) *out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    return t.terminationStatus;
}
static NSString *YTTail(NSString *s) { return s.length > 400 ? [s substringFromIndex:s.length - 400] : s; }
static NSString *YTTrim(NSString *s) { return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; }
// yt-dlp-Versionen „2026.10.26“, „2026.10.26.1“ … numerisch je Teil vergleichen
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
// Tests: SOFA_YTDLP_DIR = eigener Update-Ordner (erlaubt den Updater auch in Dev-Instanzen)
static NSString *YTTestDir(void) { return [NSProcessInfo processInfo].environment[@"SOFA_YTDLP_DIR"]; }
static NSString *YTUpdateDir(void) { return YTTestDir().length ? YTTestDir() : [SFAppSupportDir() stringByAppendingPathComponent:@"yt-dlp"]; }
static NSString *YTDirVersion(NSString *dir) {
    NSString *v = YTTrim([NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"VERSION"] encoding:NSUTF8StringEncoding error:NULL] ?: @"");
    BOOL ok = YTValidVersion(v) && [[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:@"yt-dlp"]];
    return ok ? v : nil;
}
// Ordner der aktiven yt-dlp-Version: Update, wenn neuer als die Grundausstattung
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
    NSMutableDictionary *_waiters;    // key (vid bzw. live:vid) -> Rückrufe; eine Auflösung je Video
    NSMutableSet *_prioKeys;          // keys, für die schon eine Wiedergabe-Anfrage läuft
    NSMutableDictionary *_cache;      // vid -> result (bis expires - 1 h)
    NSInteger _rid;
    NSInteger _crashes;
    BOOL _wantRunning;
    BOOL _updating;                   // yt-dlp-Update läuft
    NSTimer *_updateTimer;
}

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

// Ergebnis-Cache über einen Update-Neustart retten: das fortgesetzte Video startet dann ohne
// neue Auflösung (~5 s). Nur einmal lesbar (Datei wird gelöscht), Abgelaufenes fällt weg.
+ (NSString *)savedCachePath { return [SFCacheDir() stringByAppendingPathComponent:@"yt-resolved.json"]; }
- (void)loadSavedCache {
    if (SFDevMode) return;   // Dev-Instanzen teilen den Ordner mit der echten App -> nicht anfassen
    NSString *path = [SFYTResolver savedCachePath];
    NSData *d = [NSData dataWithContentsOfFile:path];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSDictionary *c = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![c isKindOfClass:[NSDictionary class]]) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    [c enumerateKeysAndObjectsUsingBlock:^(NSString *vid, NSDictionary *r, BOOL *stop) {
        if ([r isKindOfClass:[NSDictionary class]] && [r[@"expires"] doubleValue] - 3600 > now) self->_cache[vid] = r;
    }];
    if (_cache.count) SFLog(@"yt: %lu Auflösungen aus dem letzten Lauf übernommen", (unsigned long)_cache.count);
}
- (void)saveCache {
    if (!_cache.count || SFDevMode) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:_cache options:0 error:nil];
    NSString *path = [SFYTResolver savedCachePath];
    if (d && [d writeToFile:path atomically:YES])
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
}

- (void)start {
    _wantRunning = YES;
    // Früher aus Firefox kopierte YouTube-Cookies (Anmeldung gibt es nicht mehr) -> Kopie löschen
    static dispatch_once_t cleanup;
    dispatch_once(&cleanup, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:[SFAppSupportDir() stringByAppendingPathComponent:@"youtube-cookies.txt"] error:nil];
        // Früheres venv (yt-dlp per pip, bis 0.2.x) wird nicht mehr gebraucht – nicht aus Dev-Instanzen
        if (!SFDevMode) SFBackground(^{
            for (NSString *n in @[@"ytdlp", @"ytdlp.new", @"ytdlp.old"])
                [fm removeItemAtPath:[SFAppSupportDir() stringByAppendingPathComponent:n] error:nil];
        });
    });
    signal(SIGPIPE, SIG_IGN);   // Schreiben in eine tote Pipe darf die App nicht beenden
    if (_task.isRunning) return;
    NSString *py = kBasePython, *ytdir = YTActiveDir();
    NSString *script = [[NSBundle mainBundle] pathForResource:@"ytresolver" ofType:@"py"];
    if (!_updateTimer) {   // Sofa läuft wochenlang durch -> regelmäßig prüfen, ob ein Update fällig ist
        _updateTimer = [NSTimer scheduledTimerWithTimeInterval:6 * 3600 target:self
                                                      selector:@selector(updateTick:) userInfo:nil repeats:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((YTTestDir().length ? 5 : 120) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self updateYTDLP];   // erst nach dem Start, nicht mitten ins Hochfahren
        });
    }
    if (!script || !ytdir) { SFLog(@"yt: ytresolver.py bzw. yt-dlp fehlt im Bundle"); return; }
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:py]) { SFLog(@"yt: %@ fehlt – YouTube nicht möglich", py); return; }
    NSString *cache = [SFCacheDir() stringByAppendingPathComponent:@"yt-dlp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    NSTask *t = [NSTask new];
    t.launchPath = py;
    t.arguments = @[@"-s", script, cache];   // -s: keine Pakete aus ~/Library/Python
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    env[@"PYTHONUNBUFFERED"] = @"1";
    // yt-dlp aus dem Zipapp, Plugins (bgutil) immer aus dem Bundle (passend zum PO-Token-Server)
    env[@"PYTHONPATH"] = [NSString stringWithFormat:@"%@:%@", [ytdir stringByAppendingPathComponent:@"yt-dlp"],
                          [YTBundledDir() stringByAppendingPathComponent:@"plugins"]];
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
    SFLog(@"yt: resolver started pid %d (yt-dlp %@%@)", t.processIdentifier, YTDirVersion(ytdir),
          [ytdir isEqualToString:YTBundledDir()] ? @", Grundausstattung" : @"");
}

- (void)updateTick:(NSTimer *)t { [self updateYTDLP]; }

// Neueres yt-dlp-Release holen (höchstens täglich): laden, Signatur + Prüfsumme prüfen, Probelauf,
// dann fertig nach Application Support tauschen und den Resolver neu starten, sobald er frei ist.
// Ohne TLS-Prüfung – maßgeblich ist allein die Signatur (res/ytdlp_verify.py).
- (void)updateYTDLP {
    BOOL test = YTTestDir().length > 0;
    if (_updating || (SFDevMode && !test)) return;   // Dev-Instanzen teilen den Ordner mit der echten App
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
        if (!YTValidVersion(tag)) err = [NSString stringWithFormat:@"Release-Abfrage: HTTP %ld %@", (long)st, e.localizedDescription ?: @""];
        else if (have && YTCompare(tag, have) != NSOrderedDescending) ok = YES;   // aktuell
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
                err = [@"Signaturprüfung: " stringByAppendingString:YTTrim(out)];
            if (!err && (YTRun(py, @[@"-s", zip, @"--version"], &out, 60) != 0 || ![YTTrim(out) isEqualToString:tag]))
                err = [@"Probelauf: " stringByAppendingString:YTTail(YTTrim(out))];
            if (!err) {
                [tag writeToFile:[tmp stringByAppendingPathComponent:@"VERSION"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                for (NSString *f in @[@"SHA2-256SUMS", @"SHA2-256SUMS.sig"]) [fm removeItemAtPath:[tmp stringByAppendingPathComponent:f] error:nil];
                // Tausch: der laufende Resolver hat das alte Zipapp offen und liest bis zum Neustart daraus
                [fm removeItemAtPath:old error:nil];
                BOOL present = [fm fileExistsAtPath:dir];
                if (present) [fm moveItemAtPath:dir toPath:old error:nil];
                ok = [fm moveItemAtPath:tmp toPath:dir error:nil];
                if (!ok && present) [fm moveItemAtPath:old toPath:dir error:nil];
                if (!ok) err = @"Tausch fehlgeschlagen";
            }
            [fm removeItemAtPath:tmp error:nil];
        }
        SFMain(^{
            self->_updating = NO;
            if (!ok) { SFLog(@"yt: yt-dlp-Update gescheitert: %@", err); return; }   // nächster Versuch beim nächsten Tick
            if (!test) [[SFStore shared] setSetting:[NSString stringWithFormat:@"%.0f", now] forKey:kUpdatedKey];
            if (!newer) return;
            SFLog(@"yt: yt-dlp %@ installiert (vorher %@), Signatur geprüft", tag, have ?: @"-");
            [self restartWhenIdle];
        });
    });
}

// Neue yt-dlp-Version übernehmen, ohne eine laufende Auflösung abzubrechen
- (void)restartWhenIdle {
    if (_pending.count) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self restartWhenIdle]; });
        return;
    }
    SFLog(@"yt: Resolver-Neustart für neue yt-dlp-/Plugin-Version");
    [self restart];
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
    // erst alles einsammeln und leeren, dann zurückrufen: ein Rückruf darf sofort neu anfragen
    NSDictionary *w = [_waiters copy];
    [_waiters removeAllObjects]; [_prioKeys removeAllObjects];
    NSError *err = SFError(@"YouTube-Auflösung abgebrochen.");
    for (NSString *key in w) for (void (^done)(NSDictionary *, NSError *) in w[key]) done(nil, err);
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
            // Playlist schon jetzt in den lokalen Proxy (auch beim Vorladen bei Fokus): Start ohne Netz-Abruf
            if ([j[@"url"] isKindOfClass:[NSString class]]) [[SFStreamProxy shared] warmPlaylist:[NSURL URLWithString:j[@"url"]]];
            [self finish:key result:j error:nil];
        } else {
            SFLog(@"yt: resolve %@ failed: %@", vid, j[@"error"]);
            // Wiedergabe gescheitert -> sofort melden; nur ein gescheitertes Vorladen wartet auf eine
            // noch laufende Wiedergabe-Anfrage für dasselbe Video
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
    if (c && [c[@"expires"] doubleValue] - 3600 > [[NSDate date] timeIntervalSince1970] && !live) {
        if (prio) [[SFStreamProxy shared] warmPlaylist:[NSURL URLWithString:c[@"url"]]];
        done(c, nil); return;
    }
    [self start];
    if (!_in) {
        done(nil, SFError(@"YouTube startet gerade – bitte gleich noch einmal versuchen."));
        return;
    }
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
    _pending[rid] = @[key, vid, @(prio)];
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
