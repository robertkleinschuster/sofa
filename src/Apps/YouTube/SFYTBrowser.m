#import "SFModel.h"
#import "SFYTBrowser.h"
#import "SFRuntime.h"
#import "SFYTPointer.h"
#import "SFYTProcess.h"
#import "SFYTPriority.h"
#include <poll.h>
#include <sys/wait.h>
#include <sys/resource.h>

static NSString *const kExtensionID = @"youtube-engine@sofa";
static const int kScreenW = 1920, kScreenH = 1080;   // the TV's screen is what the page sees
static const int kDisplayWaitMS = 10000;

// user.js of the engine profile. Every value is a reason, grouped by it.
static NSDictionary *EnginePrefs(void) {
    return @{
        // Sofa's own extension: unsigned and sideloaded (Firefox ESR honours these)
        @"xpinstall.signatures.required": @NO, @"extensions.autoDisableScopes": @0, @"extensions.enabledScopes": @15,
        // The firefox-x11 port's defaults are tuned for remote X (files/firefox-x11-remote.js); what
        // a page can see of them goes back to stock Firefox: a user's browser, not a remote-X one.
        // WebGL needs the GPU process (gfxPlatform disables it without); Mesa's softpipe needs force.
        @"layers.gpu-process.enabled": @YES, @"webgl.disabled": @NO, @"webgl.force-enabled": @YES,
        @"layout.frame_rate": @-1, @"ui.prefersReducedMotion": @0, @"image.animation_mode": @"normal",
        @"general.smoothScroll": @YES, @"toolkit.cosmeticAnimations.enabled": @YES,
        @"media.autoplay.default": @1, @"media.autoplay.blocking_policy": @0,
        @"media.hardware-video-decoding.enabled": @YES, @"fission.autostart": @YES, @"dom.ipc.processCount": @8,
        // One YouTube tab needs one warm spare, rather than desktop Firefox's three.
        // Preserve fission and the active-process limits; this saves two idle processes.
        @"dom.ipc.processPrelaunch.fission.number": @1,
        // nobody looks at this browser: no first-run pages, prompts or crash-restore dialogs
        @"browser.shell.checkDefaultBrowser": @NO, @"browser.aboutwelcome.enabled": @NO,
        @"browser.startup.homepage_override.mstone": @"ignore", @"browser.sessionstore.resume_from_crash": @NO,
        @"browser.startup.page": @0,
        @"datareporting.policy.dataSubmissionEnabled": @NO, @"toolkit.telemetry.reportingpolicy.firstRun": @NO,
        @"app.update.enabled": @NO, @"toolkit.telemetry.enabled": @NO,
        // the TV's languages
        @"intl.accept_languages": @"de-AT, de, en-US, en",
        // IPv4 only (user decision 2026-11-07): YouTube had blocked this home's IPv6 /64 (its own
        // player failed there with a fresh profile) while IPv4 played; one address family for the
        // one identity
        @"network.dns.disableIPv6": @YES,
        // the engine never plays anything itself; a page that does stays silent
        @"media.volume_scale": @"0.0",
        // HTTP cache in RAM only (64 MB): on disk it held ~1 GB, 986 MB of it SABR answers (POSTs,
        // never served again; Sofa's media store keeps the bytes) - ~12.5 MB/min written during
        // playback, and its index rebuilt after every hard restart (2533 reads/min). The requests
        // stay the same (a fetch with cache: 'no-store' would add Pragma/Cache-Control). 2026-11-17
        @"browser.cache.disk.enable": @NO, @"browser.cache.disk.smart_size.enabled": @NO,
        @"browser.cache.memory.capacity": @65536,
        // Slim engine (user 2026-11-17: as lean as sensible). Only browser-side services nobody uses
        // here: nothing a page can see and no request to YouTube changes (user agent, headers,
        // HTTP/2/3, TLS, JS features, WebGL/canvas/codecs, cookies/storage stay; page-driven
        // prefetch/preconnect, favicon loads, push, GMP codecs and remote settings - certificate
        // revocation - stay on purpose).
        // - the new-tab page and its feeds (topsites, Pocket stories, weather, sponsored tiles from
        //   contile): fetched and written to activity-stream.*.json for a tab nobody opens; no
        //   preloaded about:newtab (a privileged content process of its own)
        @"browser.newtabpage.enabled": @NO, @"browser.newtab.preload": @NO,
        @"browser.newtabpage.activity-stream.feeds.topsites": @NO,
        @"browser.newtabpage.activity-stream.feeds.section.topstories": @NO,
        @"browser.newtabpage.activity-stream.feeds.weatherfeed": @NO,
        @"browser.newtabpage.activity-stream.showWeather": @NO,
        @"browser.newtabpage.activity-stream.showSponsored": @NO,
        @"browser.newtabpage.activity-stream.showSponsoredTopSites": @NO,
        @"browser.newtabpage.activity-stream.feeds.telemetry": @NO,
        @"browser.newtabpage.activity-stream.telemetry": @NO,
        @"browser.topsites.contile.enabled": @NO, @"extensions.pocket.enabled": @NO,
        // - history: places.sqlite(-wal) written on every navigation of the engine page, nobody reads
        //   it (a page never sees history; :visited is not exposed to it)
        @"places.history.enabled": @NO,
        // - page thumbnails for the new-tab page
        @"browser.pagethumbnails.capturing_disabled": @YES,
        // - Safe Browsing list updates (MBs to safebrowsing/ on a timer, requests to Google's SB
        //   API, not to YouTube); the engine only ever loads youtube.com
        @"browser.safebrowsing.malware.enabled": @NO, @"browser.safebrowsing.phishing.enabled": @NO,
        @"browser.safebrowsing.downloads.enabled": @NO, @"browser.safebrowsing.blockedURIs.enabled": @NO,
        // - telemetry, studies, experiments, crash report uploads (pings and their files on disk)
        @"toolkit.telemetry.unified": @NO, @"toolkit.telemetry.archive.enabled": @NO,
        @"toolkit.telemetry.newProfilePing.enabled": @NO, @"toolkit.telemetry.shutdownPingSender.enabled": @NO,
        @"toolkit.telemetry.firstShutdownPing.enabled": @NO, @"toolkit.telemetry.updatePing.enabled": @NO,
        @"toolkit.telemetry.bhrPing.enabled": @NO,
        @"datareporting.healthreport.uploadEnabled": @NO, @"datareporting.usage.uploadEnabled": @NO,
        @"app.normandy.enabled": @NO, @"app.shield.optoutstudies.enabled": @NO,
        @"messaging-system.rsexperimentloader.enabled": @NO, @"nimbus.rollouts.enabled": @NO,
        @"browser.ping-centre.telemetry": @NO, @"browser.discovery.enabled": @NO,
        @"browser.tabs.crashReporting.sendReport": @NO,
        // - update checks of the add-ons, search engines and system add-ons (the browser's own are
        //   off above; the bundle replaces the browser, Sofa's extension is sideloaded)
        @"app.update.auto": @NO, @"extensions.update.enabled": @NO, @"extensions.getAddons.cache.enabled": @NO,
        @"extensions.systemAddon.update.enabled": @NO, @"browser.search.update": @NO,
        @"browser.region.update.enabled": @NO,
        // - captive-portal and connectivity probes (detectportal.firefox.com on every network
        //   change; the log's "Could not determine network status" is the service failing anyway)
        @"network.captive-portal-service.enabled": @NO, @"network.connectivity-service.enabled": @NO,
        // - search suggestions, page translation and local ML features (model downloads)
        @"browser.search.suggest.enabled": @NO, @"browser.translations.enable": @NO,
        @"browser.translations.automaticallyPopup": @NO, @"browser.ml.enable": @NO,
        // - tours, promos and the Firefox account (sync)
        @"browser.uitour.enabled": @NO, @"identity.fxaccounts.enabled": @NO, @"browser.vpn_promo.enabled": @NO,
        // - session store: Sofa deletes it before every start and never restores (prepareProfile);
        //   write the one-tab session rarely instead of every 15 s, no closed-tab/window history
        @"browser.sessionstore.interval": @3600000, @"browser.sessionstore.max_tabs_undo": @0,
        @"browser.sessionstore.max_windows_undo": @0,
        // - the profile backup service (periodic backups of the whole profile; it fails here on
        //   the Documents folder anyway, measured 2026-11-17)
        @"browser.backup.enabled": @NO, @"browser.backup.scheduled.enabled": @NO,
    };
}

static NSString *UserJS(NSDictionary *prefs) {
    NSMutableString *s = [NSMutableString stringWithString:@"// written by Sofa on every engine start (SFYTBrowser.m)\n"];
    for (NSString *k in [prefs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *v = [NSJSONSerialization dataWithJSONObject:@[prefs[k]] options:0 error:nil];   // a JSON literal, unwrapped
        NSString *lit = [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding];
        [s appendFormat:@"user_pref(\"%@\", %@);\n", k, [lit substringWithRange:NSMakeRange(1, lit.length - 2)]];
    }
    return s;
}

@implementation SFYTBrowser {
    NSString *_profile;
    pid_t _xvfb, _firefox;
    int _display;
    SFYTWatcher *_watcher;
    dispatch_source_t _xvfbWatch, _firefoxWatch;
    BOOL _stopping;
    SFYTPointer *_pointer;      // on the running display; set on the launch queue (@synchronized)
    SFYTPriority *_prio;        // background priority while resting; its queue also orders background stops
    dispatch_queue_t _procQ;    // = _prio.queue
    BOOL _appliedBg;            // on _procQ: what the last run set (for the log)
    NSUInteger _appliedN;
    NSMutableSet *_throttled;   // on _procQ: the pids Sofa put at background priority (only these go back)
    BOOL _unknownPriority;      // on _procQ: a browser not set by this Sofa yet (taken over: maybe throttled by the last one)
}

- (instancetype)initWithProfile:(NSString *)profileDir {
    if ((self = [super init])) {
        _profile = profileDir; _display = -1;
        __weak SFYTBrowser *ws = self;
        _prio = [[SFYTPriority alloc] initWithApply:^(BOOL bg) { [ws applyBackgroundNow:bg]; }];
        _procQ = _prio.queue;
        _unknownPriority = YES;
    }
    return self;
}

// The browser itself, not MacPorts' bin/firefox wrapper script: one path in the bundle and in dev.
static NSString *FirefoxPath(void) { return SFRuntimePath(@"lib/firefox/firefox"); }
// Mesa's software driver for GLX (Xvfb) and WebGL (Firefox's libGL)
static NSDictionary *MesaEnv(void) { return @{@"LIBGL_DRIVERS_PATH": SFRuntimePath(@"lib/dri")}; }

static NSString *BuiltExtension(void) { return [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"youtube-engine"]; }
- (NSString *)extensionCopy { return [_profile stringByAppendingString:@"-extension"]; }
- (NSString *)pidFile { return [_profile stringByAppendingString:@"-processes.json"]; }
- (NSString *)logFile { return [_profile stringByAppendingString:@"-firefox.log"]; }

- (BOOL)available {
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm isExecutableFileAtPath:FirefoxPath()] && [fm isExecutableFileAtPath:SFTool(@"Xvfb")]
        && [fm fileExistsAtPath:[BuiltExtension() stringByAppendingPathComponent:@"manifest.json"]];
}

- (BOOL)running { return _firefox > 0; }

#pragma mark Profile

static NSData *ExtensionConfig(uint16_t port, NSString *token) {
    return [NSJSONSerialization dataWithJSONObject:@{@"port": @(port), @"token": token} options:0 error:nil];
}

// The installed extension is this build's, pointed at this channel.
- (BOOL)extensionCurrentForPort:(uint16_t)port token:(NSString *)token {
    NSString *ext = [self extensionCopy];
    NSString *stamp = [NSString stringWithContentsOfFile:[BuiltExtension() stringByAppendingPathComponent:@"STAMP"] encoding:NSUTF8StringEncoding error:nil];
    return stamp && [stamp isEqualToString:[NSString stringWithContentsOfFile:[ext stringByAppendingPathComponent:@"STAMP"] encoding:NSUTF8StringEncoding error:nil]]
        && [ExtensionConfig(port, token) isEqualToData:[NSData dataWithContentsOfFile:[ext stringByAppendingPathComponent:@"config.json"]]];
}

// The profile as the engine needs it: prefs, and the extension installed unpacked (a copy with
// config.json, referenced by a proxy file). MV2: its host permissions come with the install.
- (BOOL)prepareProfileForPort:(uint16_t)port token:(NSString *)token {
    NSFileManager *fm = [NSFileManager defaultManager];
    // one tab, the one Sofa opens: no session restore after a hard end (it brought the previous
    // tab back next to the new one - two engine pages, the second replacing the first mid-start,
    // measured 2026-11-07). Cookies and storage are elsewhere and stay.
    for (NSString *f in @[@"sessionstore.jsonlz4", @"sessionstore-backups"]) [fm removeItemAtPath:[_profile stringByAppendingPathComponent:f] error:nil];
    NSString *ext = [self extensionCopy], *exts = [_profile stringByAppendingPathComponent:@"extensions"];
    [fm createDirectoryAtPath:exts withIntermediateDirectories:YES attributes:nil error:nil];
    // The installed copy changes only when its content does (a new build, another port or token -
    // both kept across starts by SFYTEngine): Firefox takes a changed unpacked extension for an
    // update and injects its content scripts into the already loaded tab - a second engine in the
    // same document (measured 2026-11-07).
    NSData *cfg = ExtensionConfig(port, token);
    NSError *e = nil;
    if (![self extensionCurrentForPort:port token:token]) {
        [fm removeItemAtPath:ext error:nil];
        if (![fm copyItemAtPath:BuiltExtension() toPath:ext error:&e]) { SFLog(@"yt-browser: extension copy failed: %@", e.localizedDescription); return NO; }
        if (![cfg writeToFile:[ext stringByAppendingPathComponent:@"config.json"] atomically:YES]) return NO;
        SFLog(@"yt-browser: extension installed (new build or channel) - Firefox will start its engine twice once");
        self.secondStartPending = YES;
    }
    NSString *proxy = [exts stringByAppendingPathComponent:kExtensionID];   // unchanged unless it must (as above)
    BOOL proxyOK = [[NSString stringWithContentsOfFile:proxy encoding:NSUTF8StringEncoding error:nil] isEqualToString:ext]
        || [ext writeToFile:proxy atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return proxyOK
        && [UserJS(EnginePrefs()) writeToFile:[_profile stringByAppendingPathComponent:@"user.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark Processes

- (void)launchWithChannelPort:(uint16_t)port token:(NSString *)token done:(void (^)(BOOL, BOOL))done {
    _stopping = NO;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_sync(self->_procQ, ^{});   // a background stop still ending the last browser: one profile
        BOOL adopted = self.handoverGrace > 0 && [self adoptForPort:port token:token];
        BOOL ok = adopted;
        if (!adopted) {
            [self endLeftovers];
            ok = [self prepareProfileForPort:port token:token] && [self startDisplayAndBrowser];
        }
        SFMain(^{
            if (ok) { [self watchProcesses]; [self applyPriority]; }   // taken over at background priority, or started while resting
            else [self stop];
            done(ok, adopted);
        });
    });
}

- (NSDictionary *)record {
    NSData *d = [NSData dataWithContentsOfFile:[self pidFile]];
    NSDictionary *r = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [r isKindOfClass:[NSDictionary class]] ? r : nil;
}

- (void)writeRecord {
    NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"xvfb": @(_xvfb), @"firefox": @(_firefox), @"display": @(_display),
                                                          @"watcher": @(_watcher.pid)} options:0 error:nil];
    [d writeToFile:[self pidFile] atomically:YES];
}

// The browser an earlier Sofa left running (an update, a crash: its watcher waits out the grace)
// is taken over as it is - the same page, no new document, no new attestation for YouTube - if
// display and browser still run, the installed extension is this build's on this channel (a
// changed one would be updated into the loaded page: a second engine, see prepareProfile) and it
// started with this build's prefs.
- (BOOL)adoptForPort:(uint16_t)port token:(NSString *)token {
    NSDictionary *r = [self record];
    pid_t ff = [r[@"firefox"] intValue], xv = [r[@"xvfb"] intValue];
    int display = r[@"display"] ? [r[@"display"] intValue] : -1;
    if (!r || display < 0 || !SFYTProcessIs(ff, @"firefox") || !SFYTProcessIs(xv, @"Xvfb")) return NO;
    if (![self extensionCurrentForPort:port token:token]) { SFLog(@"yt-browser: the running browser has another extension build - starting anew"); return NO; }
    // prefs are read at Firefox's start: the running one must have started with these
    if (![[NSString stringWithContentsOfFile:[_profile stringByAppendingPathComponent:@"user.js"] encoding:NSUTF8StringEncoding error:nil] isEqualToString:UserJS(EnginePrefs())]) {
        SFLog(@"yt-browser: the running browser has other prefs - starting anew");
        return NO;
    }
    [SFYTWatcher endEarlier:[r[@"watcher"] intValue]];   // its processes are this Sofa's now
    @synchronized (self) { _firefox = ff; _xvfb = xv; }
    _display = display;
    NSString *name = [NSString stringWithFormat:@":%d", display];
    @synchronized (self) { _pointer = [[SFYTPointer alloc] initWithDisplay:name]; }
    int log = open([self logFile].fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
    [self startWatcher:log];
    if (log >= 0) close(log);
    [self writeRecord];
    SFLog(@"yt-browser: took over the running Firefox %d on display %@ (Xvfb %d)", ff, name, xv);
    return YES;
}

// What an earlier Sofa left running on this profile and is not taken over (Firefox would refuse
// a locked profile), with its watcher.
- (void)endLeftovers {
    NSDictionary *old = [self record];
    if (!old) return;
    [SFYTWatcher endEarlier:[old[@"watcher"] intValue]];
    SFYTEndProcess([old[@"firefox"] intValue], @"firefox");
    SFYTEndProcess([old[@"xvfb"] intValue], @"Xvfb");
    [[NSFileManager defaultManager] removeItemAtPath:[self pidFile] error:nil];
}

- (BOOL)startDisplayAndBrowser {
    // the previous run's log stays next to it: a run that ended badly is read after the restart
    NSString *previous = [[self logFile] stringByAppendingString:@".1"];
    [[NSFileManager defaultManager] removeItemAtPath:previous error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:[self logFile] toPath:previous error:nil];
    int log = open([self logFile].fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (log < 0) return NO;
    int p[2];
    if (pipe(p) != 0) { close(log); return NO; }
    // -displayfd: Xvfb picks a free display and writes its number once it accepts clients;
    // -terminate: it ends with its last client (the browser) - no display outlives the browser;
    // keymaps, xkbcomp and fonts from where Xvfb is (bundle or MacPorts: same as its built-in paths there)
    _xvfb = SFYTSpawn(SFTool(@"Xvfb"), @[@"-displayfd", @"3", @"-terminate", @"-screen", @"0", [NSString stringWithFormat:@"%dx%dx24", kScreenW, kScreenH],
                                     @"-nolisten", @"tcp", @"-xkbdir", SFRuntimePath(@"share/X11/xkb"), @"-xkbbindir", SFRuntimePath(@"bin"),
                                     @"-fp", [NSString stringWithFormat:@"%@,built-ins", SFRuntimePath(@"share/fonts/misc")]],
                  MesaEnv(), -1, log, p[1]);
    close(p[1]);
    // the whole line: Xvfb writes the number and its newline separately, and dies ("Cannot write
    // display number to fd 3") when the pipe closed in between (seen under load, 2026-11-07)
    char buf[16] = {0};
    ssize_t n = 0;
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:kDisplayWaitMS / 1000.0];
    while (_xvfb > 0 && n < (ssize_t)sizeof buf - 1 && !memchr(buf, '\n', (size_t)n)) {
        int left = (int)([until timeIntervalSinceNow] * 1000);
        struct pollfd pf = {p[0], POLLIN, 0};
        if (left <= 0 || poll(&pf, 1, left) != 1) break;
        ssize_t r = read(p[0], buf + n, sizeof buf - 1 - (size_t)n);
        if (r <= 0) break;
        n += r;
    }
    close(p[0]);
    _display = n > 0 && buf[0] >= '0' && buf[0] <= '9' ? atoi(buf) : -1;
    if (_display < 0) { SFLog(@"yt-browser: no display from Xvfb"); close(log); return NO; }
    NSMutableDictionary *ffEnv = [MesaEnv() mutableCopy];
    ffEnv[@"DISPLAY"] = [NSString stringWithFormat:@":%d", _display];
    @synchronized (self) { _pointer = [[SFYTPointer alloc] initWithDisplay:ffEnv[@"DISPLAY"]]; }
    _firefox = SFYTSpawn(FirefoxPath(), @[@"--no-remote", @"--profile", _profile, @"--width", @(kScreenW).stringValue,
                                           @"--height", @(kScreenH).stringValue, @"https://www.youtube.com/"],
                     ffEnv, -1, log, -1);
    if (_firefox > 0) [self startWatcher:log];
    close(log);
    [self writeRecord];
    if (_firefox <= 0) return NO;
    SFLog(@"yt-browser: Firefox %d on display :%d (Xvfb %d)", _firefox, _display, _xvfb);
    return YES;
}

// No browser outlives Sofa for long: the watcher (SFYTProcess.h) ends browser and display when
// Sofa is gone - after the hand-over grace (the next Sofa takes them over), at once without one.
- (void)startWatcher:(int)log {
    _watcher = [SFYTWatcher watch:@{@(_firefox): @"firefox", @(_xvfb): @"Xvfb"} grace:self.handoverGrace log:log];
}

- (dispatch_source_t)watch:(pid_t)pid name:(NSString *)name {
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    __weak SFYTBrowser *ws = self;
    dispatch_source_set_event_handler(s, ^{
        int st = 0;   // a taken-over process is not our child: no status
        NSString *why = waitpid(pid, &st, WNOHANG) == pid ? [NSString stringWithFormat:@"%@ exited (%d)", name, WIFEXITED(st) ? WEXITSTATUS(st) : -WTERMSIG(st)]
                                                         : [name stringByAppendingString:@" exited"];
        [ws exited:pid why:why];
    });
    dispatch_resume(s);
    if (kill(pid, 0) != 0) dispatch_async(dispatch_get_main_queue(), ^{ [ws exited:pid why:[name stringByAppendingString:@" ended at once"]]; });
    return s;
}

- (void)watchProcesses {
    _xvfbWatch = [self watch:_xvfb name:@"Xvfb"];
    _firefoxWatch = [self watch:_firefox name:@"Firefox"];
}

- (void)exited:(pid_t)pid why:(NSString *)why {
    if (_stopping || (pid != _xvfb && pid != _firefox)) return;
    SFLog(@"yt-browser: %@", why);
    [self stop];   // one without the other is of no use
    if (self.onExit) self.onExit(why);
}

- (NSString *)processSnapshot {
    pid_t group = _firefox;   // Spawn gives Firefox a process group of its own: its children are in it
    if (group <= 0) return nil;
    NSTask *ps = [NSTask new];
    ps.launchPath = @"/bin/ps";
    ps.arguments = @[@"-o", @"pid=,pcpu=,rss=,command=", @"-g", @(group).stringValue];
    NSPipe *out = [NSPipe pipe];
    ps.standardOutput = out;
    ps.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [ps launch]; } @catch (NSException *e) { return nil; }
    NSData *d = [out.fileHandleForReading readDataToEndOfFile];
    [ps waitUntilExit];
    NSMutableArray *lines = [NSMutableArray new];
    for (NSString *l in [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"]) {
        NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [lines addObject:[t substringToIndex:MIN(t.length, (NSUInteger)140)]];   // cpu + the process kind; no URLs/profile paths beyond
    }
    return [lines componentsJoinedByString:@" | "];
}

- (NSUInteger)memoryMB {
    pid_t group = _firefox;
    if (group <= 0) return 0;
    NSTask *ps = [NSTask new];
    ps.launchPath = @"/bin/ps";
    ps.arguments = @[@"-o", @"rss=", @"-g", @(group).stringValue];
    NSPipe *out = [NSPipe pipe];
    ps.standardOutput = out;
    ps.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [ps launch]; } @catch (NSException *e) { return 0; }
    NSData *d = [out.fileHandleForReading readDataToEndOfFile];
    [ps waitUntilExit];
    unsigned long long kb = 0;
    for (NSString *l in [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"]) kb += (unsigned long long)l.longLongValue;
    return (NSUInteger)(kb / 1024);
}

- (void)setWantBackground:(BOOL)want { _prio.want = want; }
- (BOOL)wantBackground { return _prio.want; }
- (void)applyPriority { [_prio reapply]; }

// on _procQ (SFYTPriority): the group's processes (Firefox and its children) and the display
- (void)applyBackgroundNow:(BOOL)bg {
    pid_t group, xvfb;
    @synchronized (self) { group = _firefox; xvfb = _xvfb; }
    if (group <= 0) return;
    // back to normal: only what Sofa throttled - a priority Firefox may set itself stays its own
    NSArray *pids = SFYTGroupPids(group, xvfb);
    if (!_throttled) _throttled = [NSMutableSet new];
    if (bg) [_throttled addObjectsFromArray:pids];
    else if (!_unknownPriority) pids = [pids filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF IN %@", _throttled]];
    _unknownPriority = NO;
    NSUInteger n = SFYTSetBackground(pids, bg);
    if (!bg) [_throttled removeAllObjects];
    if (bg != _appliedBg || n != _appliedN)   // a repeat (memory checks) logs only a change
        SFLog(@"yt-browser: %lu processes %@", (unsigned long)n, bg ? @"at background priority" : @"at normal priority");
    _appliedBg = bg; _appliedN = n;
}

- (void)clickInRect:(CGRect)rect done:(void (^)(BOOL))done {
    SFYTPointer *pointer;
    @synchronized (self) { pointer = _pointer; }
    if (!pointer) { if (done) done(NO); return; }
    [pointer clickInRect:rect done:done];
}

- (void)stop { [self stopWaiting:YES]; }
- (void)stopInBackground { [self stopWaiting:NO]; }

- (void)stopWaiting:(BOOL)wait {
    _stopping = YES;
    @synchronized (self) { _pointer = nil; }
    for (dispatch_source_t s in @[_xvfbWatch ?: [NSNull null], _firefoxWatch ?: [NSNull null]]) if ((id)s != [NSNull null]) dispatch_source_cancel(s);
    _xvfbWatch = _firefoxWatch = nil;
    [_watcher cancel];   // this stop ends them, nobody takes them over
    _watcher = nil;
    pid_t ff, xv;
    @synchronized (self) { ff = _firefox; xv = _xvfb; _firefox = _xvfb = 0; }
    _display = -1;
    void (^end)(void) = ^{
        self->_appliedBg = NO; self->_appliedN = 0; [self->_throttled removeAllObjects]; self->_unknownPriority = YES;   // the next browser starts anew
        // throttled processes end slowly (profile flush on the disk) - normal priority first
        SFYTSetGroupBackground(ff, xv, NO);
        SFYTEndProcess(ff, @"firefox");
        SFYTEndProcess(xv, @"Xvfb");
        [[NSFileManager defaultManager] removeItemAtPath:[self pidFile] error:nil];
    };
    if (wait) dispatch_sync(_procQ, end); else dispatch_async(_procQ, end);
}
@end
