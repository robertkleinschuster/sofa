// Sofa — entry point, window/kiosk and dev mode.
//
// Dev mode (`Sofa --dev [--size WxH]`): window outside the visible
// screen, no Dock presence, no focus, muted. Controlled via the FIFO
// the dev FIFO (SFAppDelegate+Dev fifoPath; lines: "key <up|down|left|right|select|menu|play|
// selecthold|menuhold|next|prev>", "shot <path.png>", "home", "quit", "updatequit" - the update
// handover: save, stop, exit as before a new version starts).
#import "SFCore.h"
#import "SFLibraryPages.h"
#import "SFScreen.h"
#import "SFHome.h"
#import "SFTileStatus.h"
#import "SFHomeFeatures.h"
#import "SFCurl.h"
#import "SFMenuScreen.h"
#import "SFRemote.h"
#import "SFStore.h"
#import "SFMigration.h"
#import "SFMPVEngine.h"
#import "SFNet.h"
#import "SFFollows.h"
#import "SFApps.h"
#import "SFPower.h"
#import "SFDownloads.h"
#import "SFPlayerScreen.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "SFPlayerScreen.h"
#import "SFLayers.h"
#import "SFRuntime.h"
#import "SFSettings.h"
#import "SFUpdater.h"

#import <ImageIO/ImageIO.h>
#include <sys/stat.h>

BOOL SFDevMode = NO;
NSString *gInstance = @"view";

#import "SFAppDelegate.h"
#include <sys/file.h>

@implementation SFWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (NSRect)constrainFrameRect:(NSRect)r toScreen:(NSScreen *)s { return SFDevMode ? r : [super constrainFrameRect:r toScreen:s]; }
@end

@implementation SFAppDelegate {
    SFRemote *_remote;
    id _noNap;   // App Nap opt-out for the app's lifetime
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    SFCurlGlobalInit();   // before any worker thread uses curl/OpenSSL
    // Starting at login is the autostart agent's job (setting "Beim Anmelden starten"); macOS
    // reopening Sofa as well started a second one (2026-11-07, see SFAcquireInstanceLock).
    if (!SFDevMode) [NSApp disableRelaunchOnLogin];
    SFRegisterApps();   // first: themes and apps are looked up from here on
    // No App Nap (10.9+): Sofa works while not visible - downloads, follow refreshes, the phone
    // remote, the update handover. Napping coalesced its timers so far that a 0.5 s sleep took
    // > 15 s (the helper had to force-quit on every update, 2026-11-05). Idle system sleep stays allowed.
    _noNap = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                            reason:@"Sofa: downloads, phone remote, updates"];
    NSRect frame;
    if (SFDevMode) {
        NSSize s = self.devSize.width > 0 ? self.devSize : NSMakeSize(1920, 1080);
        frame = NSMakeRect(-20000, -20000, s.width, s.height);
    } else {
        frame = [NSScreen mainScreen].frame;
    }
    SFScale = frame.size.height / 1080.0;
    SFLog(@"Sofa start (dev=%d) %.0fx%.0f scale %.2f", SFDevMode, frame.size.width, frame.size.height, SFScale);

    self.window = [[SFWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.backgroundColor = [NSColor blackColor];
    self.window.opaque = YES;
    self.window.releasedWhenClosed = NO;
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    self.nav = [[SFNavigator alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    self.window.contentView = self.nav;

    [SFAppRegistry startAll];   // app services (YouTube engine warm-up)
    [SFTileLayer setStatusSource:[SFTileStatus new]];   // download chips + progress on tiles - before the first page builds
    [self.nav push:[SFHome homeScreen]];
    __weak SFNavigator *wnav = self.nav;
    self.nav.rootMenuHandler = ^{ [SFPower showPowerMenuOn:wnav]; };
    [SFPower setNavigator:self.nav];
    SFMigrateLibraryIfNeeded();
    [SFNet startMonitoring];
    [[SFFollows shared] start];   // after the apps (feeds)
    [[SFHomeFeatures shared] start];   // live + highlights rows of Home (after the apps)
    [SFLibraryPages watchStorage];          // before the queue starts: a full disk asks the user to make room
    [[SFDownloads shared] start];
    // remote control services (phone pairing): real app always; dev instance only with SOFA_LOUNGE=1 (own screenId)
    if (!SFDevMode || getenv("SOFA_LOUNGE")) {
        [SFAppRegistry startRemotesWithHost:self];
    }
    if (!SFDevMode) [self restoreAfterUpdate];
    [self welcomeIfFirstRun];
    [self askToMoveIfMisplaced];
    if (!SFDevMode) SFBackground(^{ SFInstallAgents(); });   // release bundle only (SFRuntime)
    [[SFUpdater shared] startWithNavigator:self.nav];        // release bundle in /Applications only

    if (SFDevMode) {
        [self.window setFrame:frame display:YES];
        [self.window orderFront:nil];      // visible to the window server, but off-screen
        SFLog(@"dev: window %ld", (long)self.window.windowNumber);   // for screencapture -l (incl. OpenGL content)
        [self startFifo];
    } else {
        [NSApp setPresentationOptions:NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar];
        self.window.level = NSMainMenuWindowLevel + 1;
        [self.window setFrame:frame display:YES];
        [self.window makeKeyAndOrderFront:nil];
        [self.window makeFirstResponder:self.nav];
        [NSApp activateIgnoringOtherApps:YES];
        [self hideCursor:YES];
        // TV shell: Sofa is in front after the display wakes up
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceScreensDidWakeNotification object:nil
            queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) { [NSApp activateIgnoringOtherApps:YES]; }];
        __weak SFAppDelegate *ws = self;
        _remote = [SFRemote new];
        _remote.handler = ^(SFKey k) { [ws.nav sendKey:k]; };
        _remote.updateHandler = ^{ [ws prepareForUpdate]; };
        [_remote start];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screensChanged:)
                                                     name:NSApplicationDidChangeScreenParametersNotification object:nil];
        // measuring on the real screen (frame meter, scripted keys): a local FIFO, no network port
        // (the HTTP viewer it replaces was not needed any more: the user tests via RustDesk, 2026-11-07)
        [self startFifo];
    }
}

- (void)screensChanged:(NSNotification *)n {
    NSRect f = [NSScreen mainScreen].frame;
    SFScale = f.size.height / 1080.0;
    [self.window setFrame:f display:YES];
}

// The mouse pointer makes no sense in the 10-foot UI: invisible while Sofa is in front.
// Three layers, because the system shows the pointer again in many situations (display wake,
// app switch, other processes setting the cursor) and the hide/show count drifts apart:
//  1. transparent cursor for the whole window (cursor rects in SFNavigator + set)
//  2. watchdog (1 s): pointer visible although Sofa is in front -> hide again (+ log)
//  3. reliably show it again when leaving (another app in front)
- (void)enforceCursorHidden {
    if (SFDevMode || ![NSApp isActive]) return;
    [SFBlankCursor() set];
    if (CGCursorIsVisible()) {
        CGDisplayHideCursor(kCGNullDirectDisplay);
        static NSDate *lastLog;
        if (!lastLog || -[lastLog timeIntervalSinceNow] > 60) { lastLog = [NSDate date]; SFLog(@"cursor: was visible -> hidden"); }
    }
}
- (void)hideCursor:(BOOL)hide {
    if (SFDevMode) return;
    static NSTimer *watch;
    if (hide) {
        [self.window invalidateCursorRectsForView:self.nav];
        [self enforceCursorHidden];
        if (!watch) watch = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(enforceCursorHidden) userInfo:nil repeats:YES];
    } else {
        [watch invalidate]; watch = nil;
        for (int i = 0; i < 8 && !CGCursorIsVisible(); i++) CGDisplayShowCursor(kCGNullDirectDisplay);
        [[NSCursor arrowCursor] set];
    }
}
- (void)applicationDidBecomeActive:(NSNotification *)n { [self hideCursor:YES]; }
- (void)applicationDidResignActive:(NSNotification *)n { [self hideCursor:NO]; }

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }
- (void)applicationWillTerminate:(NSNotification *)n {
    SFClearRunningMarker();
    [[SFDownloads shared] stopForExit];
    [SFAppRegistry stopRemotes];   // phone: "disconnected" (best effort, max 1.5 s). Not on update – we're back within 1 s then.
    [SFAppRegistry stopAll];       // processes the apps started (YouTube's browser)
    for (SFScreen *s in self.nav.stack.reverseObjectEnumerator) [s willDisappear];
    [[SFStore shared] flush];
    [self stopFifo];
    // Everything is saved. exit()'s library cleanup (OpenSSL, frameworks) races with worker
    // threads still in a request -> crash on quit; leave without it, like the update path.
    SFLogFlush();
    _exit(0);
}

#pragma mark First launch

// One-time welcome with the button layout (7-button Apple Remote): only on a truly new
// installation – anyone already following shows/channels or with progress knows Sofa.
// Dev: SOFA_WELCOME=1 always shows it (test), otherwise never.
- (void)welcomeIfFirstRun {
    SFStore *st = [SFStore shared];
    BOOL force = SFDevMode && getenv("SOFA_WELCOME");
    if (!force) {
        if (SFDevMode || [st setting:@"welcome.shown"].length) return;
        [st setSetting:@"1" forKey:@"welcome.shown"];
        if ([[SFFollows shared] follows:nil].count || [st continueWatching:1 source:nil].count) return;
    }
    // afterwards: ask for the startup settings (new installation only; changeable under "Einstellungen")
    __weak SFAppDelegate *ws = self;
    SFMenuOption *go = [SFMenuOption option:@"Weiter" action:^{
        dispatch_async(dispatch_get_main_queue(), ^{ [ws askAutostart]; });
    }];
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:@"Willkommen bei Sofa"
        subtitle:@"Alles geht mit der Apple Remote:\n"
                 @"Pfeile – auswählen · Mitte – öffnen\n"
                 @"Mitte halten – Optionen (Folgen, Später ansehen, Herunterladen)\n"
                 @"MENU – zurück · MENU halten – Startseite\n"
                 @"▶❚❚ – Wiedergabe und Pause\n"
                 @"Im Video: Links/Rechts halten spult, Hoch/Runter regelt die Lautstärke."
        options:@[go] theme:[SFTheme themeNamed:@"home"]];
    m.subtitleLines = 8;
    [self.nav push:m];
}

// Release launched directly from the DMG (or another folder): remote and autostart are
// deliberately not set up then (they would point at the DMG) -- tell the user what to do.
- (void)askToMoveIfMisplaced {
    if (SFDevMode || !SFRuntimeMisplaced()) return;
    SFLog(@"start: Sofa is not running from /Applications (%@)", [[NSBundle mainBundle] bundlePath]);
    SFMenuOption *quit = [SFMenuOption option:@"Sofa beenden" action:^{ [NSApp terminate:nil]; }];
    SFMenuOption *look = [SFMenuOption option:@"Trotzdem umsehen" action:^{}];
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:@"Bitte Sofa in „Programme“ ziehen"
        subtitle:@"Sofa läuft gerade direkt aus dem Installations-Fenster.\n"
                 @"Zieh Sofa im Finder auf „Programme“ und starte es von dort –\n"
                 @"erst dann richtet Sofa die Apple Remote und den Autostart ein."
        options:@[quit, look] theme:[SFTheme themeNamed:@"home"]];
    m.subtitleLines = 4;
    [self.nav push:m];
}

// First-run setup, question 1/2: launch at login?
- (void)askAutostart {
    __weak SFAppDelegate *ws = self;
    void (^next)(BOOL) = ^(BOOL on) {
        SFSetAutostartEnabled(on);
        dispatch_async(dispatch_get_main_queue(), ^{ [ws askRemoteLaunch]; });
    };
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:@"Sofa automatisch starten?"
        subtitle:@"Sofa startet von selbst, sobald du dich am Mac anmeldest – "
                 @"ideal, wenn der Mac vor allem Fernseher ist.\n"
                 @"Später änderbar in den Einstellungen."
        options:@[[SFMenuOption option:@"Ja, automatisch starten" action:^{ next(YES); }],
                  [SFMenuOption option:@"Nein, nur wenn ich es öffne" action:^{ next(NO); }]]
        theme:[SFTheme themeNamed:@"home"]];
    m.subtitleLines = 6;
    [self.nav push:m];
}

// First-run setup, question 2/2: launch with the Apple Remote?
- (void)askRemoteLaunch {
    __weak SFAppDelegate *ws = self;
    void (^done)(BOOL) = ^(BOOL on) {
        SFSetRemoteLaunchEnabled(on);
        SFLog(@"start: first-run setup autostart=%d remoteLaunch=%d", SFAutostartEnabled(), on);
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws.nav toast:@"Fertig – viel Spaß mit Sofa!"];
        });
    };
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:@"Sofa mit der Apple Remote öffnen?"
        subtitle:@"Ein Tastendruck öffnet Sofa, auch wenn es geschlossen ist. Bei „Nein“ "
                 @"steuert die Remote den Mac (z. B. iTunes), solange Sofa zu ist.\n"
                 @"Später änderbar in den Einstellungen."
        options:@[[SFMenuOption option:@"Ja, die Remote öffnet Sofa" action:^{ done(YES); }],
                  [SFMenuOption option:@"Nein" action:^{ done(NO); }]]
        theme:[SFTheme themeNamed:@"home"]];
    m.subtitleLines = 6;
    [self.nav push:m];
}

@end

#pragma mark Autostart (setting "Beim Anmelden starten")
// The autostart agent (de.sofa.app) launches Sofa with --autostart and relaunches it after a crash
// (KeepAlive). If autostart is off, Sofa quits silently right away at login – but after a
// crash (marker "running" still present) it keeps running.
static NSString *SFRunningMarker(void) { return [SFAppSupportDir() stringByAppendingPathComponent:@"running"]; }
void SFClearRunningMarker(void) {
    if (!SFDevMode) [[NSFileManager defaultManager] removeItemAtPath:SFRunningMarker() error:nil];
}
static void SFSetRunningMarker(void) {
    if (!SFDevMode) [[NSFileManager defaultManager] createFileAtPath:SFRunningMarker() contents:nil attributes:nil];
}

#pragma mark One instance per data directory
// Two Sofas on one data directory share the database and - worse - the YouTube engine's profile:
// two browsers, one identity (2026-11-07: after a reboot macOS reopened Sofa next to the one the
// autostart agent started; they fought over the engine and the database). The lock is an flock on
// a file in the data directory, held for the process' lifetime - the kernel drops it when the
// process ends, also on a crash. A second start waits a little (an update hands over: the old
// instance is still ending) and then quits before touching anything.
static BOOL SFAcquireInstanceLock(NSTimeInterval wait) {
    NSString *path = [SFAppSupportDir() stringByAppendingPathComponent:@"instance.lock"];
    int fd = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) return YES;   // cannot tell - a broken lock file must not stop Sofa
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:wait];
    while (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if ([until timeIntervalSinceNow] <= 0) { close(fd); return NO; }
        usleep(100000);
    }
    return YES;   // fd stays open: the lock lives as long as this process
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        SFRuntimeSetup();
        NSApplication *app = [NSApplication sharedApplication];
        SFAppDelegate *del = [SFAppDelegate new];
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--dev")) SFDevMode = YES;
            else if (!strcmp(argv[i], "--instance") && i + 1 < argc) gInstance = @(argv[++i]);
            else if (!strcmp(argv[i], "--size") && i + 1 < argc) {
                int w = 0, h = 0;
                if (sscanf(argv[++i], "%dx%d", &w, &h) == 2) del.devSize = NSMakeSize(w, h);
            }
        }
        if (SFDevMode) {
            SFSetDevInstance(gInstance);   // own data directory and log (docs/architecture.md, Dev instances)
        }
        const char *lockWait = getenv("SOFA_INSTANCE_LOCK_WAIT");   // tests: shorter than an update's handover
        if (!SFAcquireInstanceLock(lockWait ? atof(lockWait) : 10)) {
            SFLog(@"start: another Sofa runs on this data directory – quitting");
            SFLogFlush();   // SFLog writes asynchronously; the process ends right here
            return 0;   // exit 0: launchd (KeepAlive SuccessfulExit=false) doesn't relaunch
        }
        BOOL autostart = NO;
        for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--autostart")) autostart = YES;
        if (autostart && !SFDevMode && !SFAutostartEnabled()) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:SFRunningMarker()]) {
                SFLog(@"start: autostart is off – quitting");
                SFLogFlush();
                return 0;   // exit 0: launchd (KeepAlive SuccessfulExit=false) doesn't relaunch
            }
            SFLog(@"start: autostart off, but the last run ended unexpectedly – starting anyway");
        }
        SFSetRunningMarker();
        // Dev: never in the Dock, never in the foreground (doesn't disturb Kodi).
        app.activationPolicy = SFDevMode ? NSApplicationActivationPolicyProhibited : NSApplicationActivationPolicyRegular;
        app.delegate = del;
        [app run];
    }
    return 0;
}
