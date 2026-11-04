#import "SFUpdater.h"
#import <CommonCrypto/CommonDigest.h>
#import "SFCore.h"
#import "SFCurl.h"
#import "SFRuntime.h"
#import "SFSettings.h"
#import "SFScreen.h"
#import "SFPlayerScreen.h"

static NSString *const kReleasesAPI = @"https://api.github.com/repos/robertkleinschuster/sofa/releases/latest";
// Nur für Tests (tools/test-updater): andere Release-Quelle; erlaubt den Updater auch in Dev-Instanzen.
static NSString *SFTestAPI(void) { return [NSProcessInfo processInfo].environment[@"SOFA_UPDATE_API"]; }
static const NSTimeInterval kFirstCheck = 5 * 60, kCheckEvery = 6 * 3600, kIdleFor = 15 * 60;

static NSString *SFAppVersion(NSString *bundle) {
    NSDictionary *i = bundle ? [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Contents/Info.plist"]]
                             : [[NSBundle mainBundle] infoDictionary];
    return i[@"CFBundleShortVersionString"];
}

// "0.10.1" > "0.9.3"; fehlende Stellen = 0
static NSComparisonResult SFCompareVersions(NSString *a, NSString *b) {
    NSArray *x = [a componentsSeparatedByString:@"."], *y = [b componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MAX(x.count, y.count); i++) {
        NSInteger p = i < x.count ? [x[i] integerValue] : 0, q = i < y.count ? [y[i] integerValue] : 0;
        if (p != q) return p < q ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}

static NSString *SFSHA256OfFile(NSString *path) {
    NSInputStream *in = [NSInputStream inputStreamWithFileAtPath:path];
    if (!in) return nil;
    [in open];
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    uint8_t buf[1 << 16]; NSInteger n;
    while ((n = [in read:buf maxLength:sizeof buf]) > 0) CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
    [in close];
    if (n < 0) return nil;
    unsigned char md[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(md, &ctx);
    NSMutableString *s = [NSMutableString new];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", md[i]];
    return s;
}

static int SFRun(NSString *tool, NSArray *args, NSData **out) {
    NSTask *t = [NSTask new];
    t.launchPath = tool; t.arguments = args;
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p; t.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [t launch]; } @catch (NSException *e) { return -1; }
    NSData *d = [p.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    if (out) *out = d;
    return t.terminationStatus;
}

@implementation SFUpdater {
    __weak SFNavigator *_nav;
    NSTimer *_checkTimer, *_applyTimer;
    BOOL _busy;
    NSString *_latest, *_dmgURL, *_shaURL, *_notes;
    NSDate *_lastCheck;
}

+ (instancetype)shared {
    static SFUpdater *u; static dispatch_once_t o;
    dispatch_once(&o, ^{ u = [SFUpdater new]; });
    return u;
}

- (NSString *)appPath { return [[NSBundle mainBundle] bundlePath]; }
- (NSString *)readyPath { return [[self appPath] stringByAppendingString:@".update"]; }     // geprüft, wartet auf Ruhe
- (NSString *)stagedPath { return [[self appPath] stringByAppendingString:@".staged"]; }    // Übergabe an den Helper
- (NSString *)workDir { return [SFCacheDir() stringByAppendingPathComponent:@"update"]; }

- (BOOL)available {
    BOOL writable = [[NSFileManager defaultManager] isWritableFileAtPath:[[self appPath] stringByDeletingLastPathComponent]];
    if (SFTestAPI().length) return writable;
    return SFRuntimeDir() && !SFDevMode && !SFRuntimeMisplaced() && writable;
}

- (void)startWithNavigator:(SFNavigator *)nav {
    _nav = nav;
    if (!self.available) return;
    // Reste: ein bereitliegendes Update, das nicht (mehr) neuer ist, verwerfen
    NSString *v = SFAppVersion([self readyPath]);
    if (v && SFCompareVersions(v, SFAppVersion(nil)) != NSOrderedDescending)
        [[NSFileManager defaultManager] removeItemAtPath:[self readyPath] error:nil];
    _checkTimer = [NSTimer scheduledTimerWithTimeInterval:kCheckEvery target:self selector:@selector(periodicCheck) userInfo:nil repeats:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFirstCheck * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self periodicCheck]; });
    _applyTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(applyIfIdle) userInfo:nil repeats:YES];
}

- (NSString *)installedVersion { return SFAppVersion(nil); }
- (BOOL)updateAvailable { return _latest && SFCompareVersions(_latest, self.installedVersion) == NSOrderedDescending; }
- (NSString *)latestVersion { return _latest; }
- (NSDate *)lastCheck { return _lastCheck; }
- (NSString *)releaseNotes { return _notes; }
- (BOOL)busy { return _busy; }

- (void)periodicCheck {
    if (!SFAutoUpdateEnabled() || _busy) return;
    [self check:^(NSString *m) {
        SFLog(@"update-check: %@", m);
        if (!self.updateAvailable || !SFAutoUpdateEnabled()) return;
        if (SFCompareVersions(SFAppVersion([self readyPath]) ?: @"0", self->_latest) == NSOrderedSame) return;   // liegt schon bereit
        [self fetch:NO done:^(NSString *m2) { SFLog(@"update: %@", m2); }];
    }];
}

// Ruhe = keine Wiedergabe und 15 min keine Taste (oder Sofa gar nicht vorne)
- (BOOL)idle {
    SFNavigator *nav = _nav;
    for (id s in nav.stack) if ([s isKindOfClass:[SFPlayerScreen class]]) return NO;
    if (![NSApp isActive]) return YES;
    return [NSDate timeIntervalSinceReferenceDate] - nav.lastInput > kIdleFor;
}

- (void)applyIfIdle {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!SFAutoUpdateEnabled() || ![fm fileExistsAtPath:[self readyPath]] || [fm fileExistsAtPath:[self stagedPath]] || ![self idle]) return;
    [self handOver];
}

- (void)handOver {
    SFLog(@"update: %@ bereit – übergebe an den Helper", SFAppVersion([self readyPath]));
    if (![[NSFileManager defaultManager] moveItemAtPath:[self readyPath] toPath:[self stagedPath] error:nil])
        SFLog(@"update: Übergabe fehlgeschlagen");
}

// Nur nachsehen, was GitHub als neueste Version hat (merkt sich die Download-Adressen)
- (void)check:(void (^)(NSString *))done {
    if (!self.available) {
        done(SFRuntimeDir() ? @"Updates gehen nur, wenn Sofa im Ordner „Programme“ liegt"
                            : @"Diese Sofa-Installation wird über MacPorts aktualisiert");
        return;
    }
    if (_busy) { done(@"Suche läuft bereits"); return; }
    _busy = YES;
    SFBackground(^{
        NSInteger status = 0;
        NSData *d = SFCurlFetch(SFTestAPI().length ? SFTestAPI() : kReleasesAPI, @"GET", @{@"Accept": @"application/vnd.github+json"}, nil, &status, NULL);
        NSDictionary *rel = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
        NSString *msg;
        if (status != 200 || ![rel isKindOfClass:[NSDictionary class]] || ![rel[@"tag_name"] isKindOfClass:[NSString class]]) {
            msg = @"GitHub nicht erreichbar – später erneut versuchen";
            SFMain(^{ self->_busy = NO; done(msg); });
            return;
        }
        NSString *tag = rel[@"tag_name"], *ver = [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;
        NSString *dmgName = [NSString stringWithFormat:@"Sofa-%@.dmg", ver], *dmgURL = nil, *shaURL = nil;
        for (NSDictionary *a in rel[@"assets"]) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            if ([a[@"name"] isEqual:dmgName]) dmgURL = a[@"browser_download_url"];
            if ([a[@"name"] isEqual:[dmgName stringByAppendingString:@".sha256"]]) shaURL = a[@"browser_download_url"];
        }
        SFMain(^{
            self->_busy = NO;
            self->_lastCheck = [NSDate date];
            // Release ohne DMG/Prüfsumme (z.B. nur Quellcode) zählt nicht als installierbares Update
            self->_latest = (dmgURL && shaURL) ? ver : self.installedVersion;
            self->_dmgURL = dmgURL; self->_shaURL = shaURL;
            self->_notes = [rel[@"body"] isKindOfClass:[NSString class]] ? rel[@"body"] : nil;
            done(self.updateAvailable ? [NSString stringWithFormat:@"Update verfügbar: %@ → %@", self.installedVersion, ver]
                                      : [NSString stringWithFormat:@"Sofa ist aktuell (%@)", self.installedVersion]);
        });
    });
}

- (void)install:(void (^)(NSString *))progress {
    if (!self.updateAvailable) { progress(@"Kein Update gefunden"); return; }
    if (SFCompareVersions(SFAppVersion([self readyPath]) ?: @"0", _latest) == NSOrderedSame) {
        progress([NSString stringWithFormat:@"Sofa %@ wird installiert …", _latest]);
        [self handOver];
        return;
    }
    [self fetch:YES done:progress];
}

// Laden + prüfen (Hintergrund); now = danach sofort installieren
- (void)fetch:(BOOL)now done:(void (^)(NSString *))done {
    if (_busy) { done(@"Update wird bereits geladen"); return; }
    _busy = YES;
    NSString *ver = _latest, *dmgURL = _dmgURL, *shaURL = _shaURL;
    if (now) done([NSString stringWithFormat:@"Lade Sofa %@ … (etwa 100 MB)", ver]);
    SFBackground(^{
        NSString *err = [self downloadAndStage:dmgURL sha:shaURL version:ver];
        SFMain(^{
            self->_busy = NO;
            if (err) { done(err); return; }
            if (now) { done([NSString stringWithFormat:@"Sofa %@ wird installiert …", ver]); [self handOver]; }
            else done([NSString stringWithFormat:@"Sofa %@ geladen – Installation, sobald Sofa ruht", ver]);
        });
    });
}

// Hintergrund: DMG laden, Prüfsumme, Bundle nach <App>.update. nil = ok, sonst Fehlermeldung.
- (NSString *)downloadAndStage:(NSString *)dmgURL sha:(NSString *)shaURL version:(NSString *)ver {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *work = [self workDir], *dmg = [work stringByAppendingPathComponent:@"Sofa.dmg"];
    NSString *mnt = [work stringByAppendingPathComponent:@"mnt"];
    [fm removeItemAtPath:work error:nil];
    [fm createDirectoryAtPath:mnt withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *e = nil;
    NSData *shaData = SFCurlFetch(shaURL, @"GET", nil, nil, NULL, &e);
    NSString *want = [[[[NSString alloc] initWithData:shaData ?: [NSData data] encoding:NSUTF8StringEncoding]
                       componentsSeparatedByString:@" "].firstObject lowercaseString];
    if (want.length != 64) return @"Update: Prüfsumme nicht ladbar";
    SFLog(@"update: lade %@", dmgURL);
    if (!SFCurlDownload(dmgURL, dmg, &e)) return [@"Update-Download fehlgeschlagen: " stringByAppendingString:e.localizedDescription ?: @"?"];
    if (![SFSHA256OfFile(dmg) isEqualToString:want]) { [fm removeItemAtPath:work error:nil]; return @"Update verworfen: Prüfsumme stimmt nicht"; }

    // DMG einhängen (unsichtbar, nur lesen), Bundle kopieren, aushängen
    NSString *result = nil;
    if (SFRun(@"/usr/bin/hdiutil", @[@"attach", @"-nobrowse", @"-readonly", @"-noautoopen", @"-mountpoint", mnt, dmg], NULL) != 0)
        result = @"Update: DMG lässt sich nicht öffnen";
    NSString *src = [mnt stringByAppendingPathComponent:@"Sofa.app"], *tmp = [[self readyPath] stringByAppendingString:@".tmp"];
    if (!result) {
        [fm removeItemAtPath:tmp error:nil];
        if (SFRun(@"/usr/bin/ditto", @[src, tmp], NULL) != 0) result = @"Update: Kopieren fehlgeschlagen";
        SFRun(@"/usr/bin/hdiutil", @[@"detach", @"-quiet", @"-force", mnt], NULL);
    }
    [fm removeItemAtPath:dmg error:nil];
    if (result) { [fm removeItemAtPath:tmp error:nil]; return result; }

    // Plausibel? Richtige App, richtige Version, vollständige Laufzeit
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[tmp stringByAppendingPathComponent:@"Contents/Info.plist"]];
    BOOL ok = [info[@"CFBundleIdentifier"] isEqual:@"de.sofa.app"] && [info[@"CFBundleShortVersionString"] isEqual:ver] &&
              [fm isExecutableFileAtPath:[tmp stringByAppendingPathComponent:@"Contents/MacOS/Sofa"]] &&
              [fm isExecutableFileAtPath:[tmp stringByAppendingPathComponent:@"Contents/MacOS/SofaRemote"]] &&
              [fm fileExistsAtPath:[tmp stringByAppendingPathComponent:@"Contents/Runtime/bin"]];
    if (!ok) { [fm removeItemAtPath:tmp error:nil]; return @"Update verworfen: Paket unvollständig"; }
    [fm removeItemAtPath:[self readyPath] error:nil];
    if (![fm moveItemAtPath:tmp toPath:[self readyPath] error:nil]) return @"Update: Ablegen fehlgeschlagen";
    [fm removeItemAtPath:work error:nil];
    SFLog(@"update: Sofa %@ geprüft und bereit", ver);
    return nil;
}
@end
