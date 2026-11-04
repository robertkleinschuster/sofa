#import "SFYTResolver.h"
#import "SFModel.h"
#import "SFStore.h"
#import "SFRuntime.h"

// yt-dlp + Plugins leben in einem eigenen venv (nicht im App-Bundle): yt-dlp muss oft
// aktualisiert werden, schneller als jede Sofa-/MacPorts-Version. Sofa legt das venv beim
// ersten Bedarf selbst an und hält es täglich aktuell (pip install -U).
// Basis-Python: im Release-Bundle Contents/Runtime/python, sonst MacPorts python314 (SFRuntime)
#define kBasePython SFPythonPath()
static NSString *const kPotPlugin = @"bgutil-ytdlp-pot-provider";
// Plugin-Version muss zur Version des PO-Token-Servers passen (Port bgutil-pot-server) ->
// wird an dessen /ping-Antwort gepinnt; Server nicht erreichbar -> neueste Version.
static NSArray *YTPackages(NSString *potVersion) {
    return @[@"yt-dlp", @"yt-dlp-ejs", potVersion ? [kPotPlugin stringByAppendingFormat:@"==%@", potVersion] : kPotPlugin];
}
static NSString *YTServerVersion(void) {
    NSURLRequest *r = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:4416/ping"]
                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5];
    NSData *d = [NSURLConnection sendSynchronousRequest:r returningResponse:NULL error:NULL];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    NSString *v = [j isKindOfClass:[NSDictionary class]] ? j[@"version"] : nil;
    if (![v isKindOfClass:[NSString class]]) return nil;
    NSRegularExpression *ok = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(\\.[0-9]+)*$" options:0 error:NULL];
    return [ok numberOfMatchesInString:v options:0 range:NSMakeRange(0, v.length)] ? v : nil;
}
static NSString *const kUpdatedKey = @"ytdlp.updated";
static const NSTimeInterval kUpdateEvery = 24 * 3600;

// Läuft synchron (nur im Hintergrund aufrufen); liefert Exit-Status, *out = stdout+stderr.
// Hängt ein Lauf länger als `timeout`, wird er beendet (pip ohne Netz kann ewig warten).
static int YTRun(NSString *path, NSArray *args, NSString **out, NSTimeInterval timeout) {
    NSTask *t = [NSTask new];
    t.launchPath = path; t.arguments = args;
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    env[@"PIP_DISABLE_PIP_VERSION_CHECK"] = @"1";
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
// installierte Versionen von yt-dlp und Plugin, z.B. "2026.10.26 2.0.2"
static NSString *YTVersion(NSString *py) {
    NSString *o = nil;
    if (YTRun(py, @[@"-c", @"import importlib.metadata as m; print(m.version('yt-dlp'), m.version('bgutil-ytdlp-pot-provider'))"], &o, 60) != 0) return nil;
    return [o stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
// "2.0" == "2.0.0" (PEP 440 vs. Server-Angabe)
static BOOL YTSameVersion(NSString *a, NSString *b) {
    NSString *(^norm)(NSString *) = ^NSString *(NSString *v) {
        while ([v hasSuffix:@".0"]) v = [v substringToIndex:v.length - 2];
        return v;
    };
    return a && b && [norm(a) isEqualToString:norm(b)];
}
// Würde pip etwas ändern? Probelauf mit Bericht, ohne das venv anzufassen.
// Ergebnis: Anzahl zu installierender Pakete, -1 bei Fehler (z.B. offline, Version unbekannt).
static NSInteger YTPendingChanges(NSString *py, NSArray *pkgs) {
    NSString *report = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"sofa-pip-%d.json", getpid()]];
    NSMutableArray *args = [@[@"-m", @"pip", @"install", @"--upgrade", @"--dry-run", @"--quiet", @"--report", report] mutableCopy];
    [args addObjectsFromArray:pkgs];
    NSInteger n = -1;
    if (YTRun(py, args, NULL, 300) == 0) {
        id j = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:report] ?: [NSData data] options:0 error:NULL];
        id inst = [j isKindOfClass:[NSDictionary class]] ? j[@"install"] : nil;
        if ([inst isKindOfClass:[NSArray class]]) n = [inst count];
    }
    [[NSFileManager defaultManager] removeItemAtPath:report error:nil];
    return n;
}
// Stammt das venv vom aktuellen Basis-Python? (Wechsel MacPorts <-> Release-Bundle oder
// neue Python-Version im Bundle: das alte venv zeigt dann ins Leere bzw. aufs falsche Python.)
static BOOL YTVenvMatchesBase(NSString *dir) {
    NSString *cfg = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"pyvenv.cfg"]
                                              encoding:NSUTF8StringEncoding error:NULL];
    NSString *want = [kBasePython stringByResolvingSymlinksInPath];
    for (NSString *l in [cfg componentsSeparatedByString:@"\n"]) {
        NSRange eq = [l rangeOfString:@"="];
        if (![l hasPrefix:@"executable"] || eq.location == NSNotFound) continue;
        NSString *have = [[l substringFromIndex:NSMaxRange(eq)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return [[have stringByResolvingSymlinksInPath] isEqualToString:want];
    }
    return NO;
}
// Frisches venv in `tmp` bauen; gepinnte Plugin-Version nicht installierbar -> neueste.
static BOOL YTBuildVenv(NSString *tmp, NSString *server, NSString **out) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:tmp error:nil];
    [fm createDirectoryAtPath:[tmp stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    if (YTRun(kBasePython, @[@"-m", @"venv", tmp], out, 120) != 0) return NO;
    NSString *tpy = [tmp stringByAppendingPathComponent:@"bin/python"];
    NSArray *base = @[@"-m", @"pip", @"install", @"--upgrade", @"--quiet"];
    if (YTRun(tpy, [base arrayByAddingObjectsFromArray:YTPackages(server)], out, 900) == 0) return YES;
    if (!server) return NO;
    SFLog(@"yt: Plugin %@ nicht installierbar – nehme neueste Version", server);
    return YTRun(tpy, [base arrayByAddingObjectsFromArray:YTPackages(nil)], out, 900) == 0;
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
    BOOL _settingUp;                  // venv wird angelegt/aktualisiert
    NSTimeInterval _failedAt;         // letzter gescheiterter Versuch -> 10 min Pause (kein Dauerversuch bei jedem Fokus)
    NSTimer *_updateTimer;
}

+ (instancetype)shared {
    static SFYTResolver *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFYTResolver new]; });
    return s;
}

+ (NSString *)envDir {
    NSString *o = [NSProcessInfo processInfo].environment[@"SOFA_YTDLP_DIR"];   // Tests: eigenes venv
    return o.length ? o : [SFAppSupportDir() stringByAppendingPathComponent:@"ytdlp"];
}
+ (NSString *)python { return [[self envDir] stringByAppendingPathComponent:@"bin/python"]; }

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
        [[NSFileManager defaultManager] removeItemAtPath:[SFAppSupportDir() stringByAppendingPathComponent:@"youtube-cookies.txt"] error:nil];
    });
    signal(SIGPIPE, SIG_IGN);   // Schreiben in eine tote Pipe darf die App nicht beenden
    if (_task.isRunning) return;
    NSString *py = [SFYTResolver python];
    NSString *script = [[NSBundle mainBundle] pathForResource:@"ytresolver" ofType:@"py"];
    if (!_updateTimer) {   // Sofa läuft wochenlang durch -> regelmäßig prüfen, ob ein Update fällig ist
        _updateTimer = [NSTimer scheduledTimerWithTimeInterval:6 * 3600 target:self
                                                      selector:@selector(updateTick:) userInfo:nil repeats:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self ensureEnvironment];   // erst nach dem Start, nicht mitten ins Hochfahren
        });
    }
    if (!script) { SFLog(@"yt: ytresolver.py fehlt im Bundle"); return; }
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:py]) {
        [self ensureEnvironment];   // startet den Resolver nach dem Anlegen selbst
        return;
    }
    NSString *cache = [SFCacheDir() stringByAppendingPathComponent:@"yt-dlp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    NSTask *t = [NSTask new];
    t.launchPath = py;
    t.arguments = @[script, cache];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
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
    NSString *old = [[SFYTResolver envDir] stringByAppendingString:@".old"];   // vom letzten venv-Tausch
    SFBackground(^{ [[NSFileManager defaultManager] removeItemAtPath:old error:nil]; });
}

- (BOOL)isSettingUp { return _settingUp; }

- (void)updateTick:(NSTimer *)t { [self ensureEnvironment]; }

// Legt das venv an (fehlt es) bzw. aktualisiert es (einmal täglich). Nie zwei Läufe gleichzeitig.
// Updates werden wie die Ersteinrichtung NEBENAN gebaut und erst fertig getauscht: das laufende
// venv wird nie halb umgebaut (pip-Abbruch, kein Netz).
- (void)ensureEnvironment {
    if (_settingUp) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (_failedAt && now - _failedAt < 600) return;
    NSString *dir = [SFYTResolver envDir], *py = [SFYTResolver python];
    BOOL exists = [[NSFileManager defaultManager] isExecutableFileAtPath:py];
    BOOL due = now - [[[SFStore shared] setting:kUpdatedKey] doubleValue] > kUpdateEvery;
    // Dev-Instanzen teilen sich das venv der echten App: nie anlegen oder umbauen
    BOOL custom = [(NSString *)[NSProcessInfo processInfo].environment[@"SOFA_YTDLP_DIR"] length] > 0;
    if (SFDevMode && !custom) return;
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:kBasePython]) {
        SFLog(@"yt: %@ fehlt – YouTube-Wiedergabe nicht möglich", kBasePython);
        return;
    }
    _settingUp = YES;
    SFBackground(^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *server = YTServerVersion();
        void (^finish)(BOOL, NSString *, NSString *, NSString *) = ^(BOOL ok, NSString *before, NSString *after, NSString *out) {
            SFMain(^{
                self->_settingUp = NO;
                if (!ok) { self->_failedAt = now; SFLog(@"yt: venv fehlgeschlagen: %@", YTTail(out)); return; }
                self->_failedAt = 0;
                [[SFStore shared] setSetting:[NSString stringWithFormat:@"%.0f", now] forKey:kUpdatedKey];
                if (!after) return;   // nichts zu tun
                SFLog(@"yt: yt-dlp + Plugin %@%@", after, before ? [@" (vorher " stringByAppendingFormat:@"%@)", before] : @"");
                if (!exists) { if (self->_wantRunning) [self start]; }
                else [self restartWhenIdle];
            });
        };
        NSString *before = nil;
        // Ordner da, aber Python tot (App verschoben, alte Bundle-Version, MacPorts weg) oder von
        // einem anderen Basis-Python: neu bauen und den alten Ordner beim Tausch beiseite legen.
        BOOL present = [fm fileExistsAtPath:dir];
        BOOL foreign = present && (!exists || !YTVenvMatchesBase(dir));
        if (foreign) SFLog(@"yt: venv stammt von anderem Python – neu anlegen");
        if (exists && !foreign) {
            // Server (noch) nicht erreichbar: lieber warten als ein unpassendes Plugin holen
            if (!server) { SFMain(^{ self->_settingUp = NO; }); return; }
            before = YTVersion(py);
            NSString *plugin = [before componentsSeparatedByString:@" "].lastObject;
            BOOL mismatch = before && !YTSameVersion(plugin, server);
            if (!due && !mismatch) { SFMain(^{ self->_settingUp = NO; }); return; }
            if (YTPendingChanges(py, YTPackages(server)) == 0) { finish(YES, before, nil, nil); return; }
        }
        SFLog(@"yt: %@ venv %@ (PO-Server %@)", exists ? @"erneuere" : @"lege an", dir, server ?: @"nicht erreichbar");
        NSString *tmp = [dir stringByAppendingString:@".new"], *old = [dir stringByAppendingString:@".old"], *out = nil;
        BOOL ok = YTBuildVenv(tmp, server, &out);
        NSString *after = ok ? YTVersion([tmp stringByAppendingPathComponent:@"bin/python"]) : nil;
        ok = ok && after.length;
        if (ok) {
            // Tausch: altes venv beiseite, neues an seinen Platz. Der laufende Resolver lädt Module über
            // denselben Pfad bis zu seinem Neustart (gleich danach, sobald frei) schon aus dem neuen.
            [fm removeItemAtPath:old error:nil];
            if (present) [fm moveItemAtPath:dir toPath:old error:nil];
            ok = [fm moveItemAtPath:tmp toPath:dir error:nil];
            if (!ok && present) [fm moveItemAtPath:old toPath:dir error:nil];
        }
        if (!ok) [fm removeItemAtPath:tmp error:nil];
        finish(ok, before, after, out);
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
    if (c && [c[@"expires"] doubleValue] - 3600 > [[NSDate date] timeIntervalSince1970] && !live) { done(c, nil); return; }
    [self start];
    if (!_in) {
        done(nil, SFError(_settingUp ? @"YouTube wird eingerichtet (einmalig, etwa eine Minute) – bitte gleich noch einmal versuchen."
                          : _failedAt ? @"YouTube konnte nicht eingerichtet werden (Internetverbindung?). Sofa versucht es in einigen Minuten erneut."
                                      : @"YouTube-Wiedergabe nicht eingerichtet."));
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
