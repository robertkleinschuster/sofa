// Sofa — Einstiegspunkt, Fenster/Kiosk und Dev-Modus.
//
// Dev-Modus (`Sofa --dev [--size WxH]`): Fenster außerhalb des sichtbaren
// Bildschirms, keine Dock-Präsenz, kein Fokus, stumm. Steuerung über die FIFO
// ~/Library/Caches/Sofa/dev.fifo (Zeilen: "key <up|down|left|right|select|menu|play|
// selecthold|menuhold|next|prev>", "shot <pfad.png>", "home", "quit").
#import "SFCore.h"
#import "SFScreen.h"
#import "SFHome.h"
#import "SFMenuScreen.h"
#import "SFRemote.h"
#import "SFStore.h"
#import "SFDevServer.h"
#import "SFMigration.h"
#import "SFPairScreen.h"
#import "SFMPVEngine.h"
#import "SFNet.h"
#import "SFFollows.h"
#import "SFProviderCCC.h"
#import "SFProviderARD.h"
#import "SFProviderZDF.h"
#import "SFProviderORF.h"
#import "SFYouTube.h"
#import "SFYTResolver.h"
#import "SFLounge.h"
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
static uint16_t gPort = 8765;

#import "SFAppDelegate.h"

@implementation SFWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (NSRect)constrainFrameRect:(NSRect)r toScreen:(NSScreen *)s { return SFDevMode ? r : [super constrainFrameRect:r toScreen:s]; }
@end

@implementation SFAppDelegate {
    SFRemote *_remote;
    SFDevServer *_dev;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
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

    [SFProviderCCC registerResolver];
    [SFProviderARD registerResolver];
    [SFProviderZDF registerResolver];
    [SFProviderORF registerResolver];
    [SFYouTube setup];
    [self.nav push:[SFHome homeScreen]];
    __weak SFNavigator *wnav = self.nav;
    self.nav.rootMenuHandler = ^{ [SFPower showPowerMenuOn:wnav]; };
    [SFPower setNavigator:self.nav];
    SFMigrateLibraryIfNeeded();
    [SFNet startMonitoring];
    [[SFFollows shared] start];   // nach SFYouTube setup (Seiten/Feeds registriert)
    [[SFDownloads shared] start];
    // Handy-Koppeln: echte App immer; Dev-Instanz nur mit SOFA_LOUNGE=1 (eigene screenId)
    if (!SFDevMode || getenv("SOFA_LOUNGE")) {
        __weak SFAppDelegate *wl = self;
        [SFLounge shared].commandHandler = ^(NSString *cmd, NSDictionary *args) { [wl loungeCommand:cmd args:args]; };
        [SFLounge shared].playerProvider = ^id { return [wl topPlayer]; };
        [[SFLounge shared] start];
    }
    if (!SFDevMode) [self restoreAfterUpdate];
    [self welcomeIfFirstRun];
    [self askToMoveIfMisplaced];
    if (!SFDevMode) SFBackground(^{ SFInstallAgents(); });   // nur Release-Bundle (SFRuntime)
    [[SFUpdater shared] startWithNavigator:self.nav];        // nur Release-Bundle in „Programme“

    if (SFDevMode) {
        [self.window setFrame:frame display:YES];
        [self.window orderFront:nil];      // sichtbar für den Window-Server, aber außerhalb
        SFLog(@"dev: window %ld", (long)self.window.windowNumber);   // für screencapture -l (inkl. OpenGL-Inhalt)
        [self startFifo];
        _dev = [[SFDevServer alloc] initWithNavigator:self.nav port:gPort];
        __weak SFAppDelegate *ws = self;
        _dev.keyHandler = ^(NSString *k) { [ws devCommand:[@"key " stringByAppendingString:k]]; };
        [_dev start];
    } else {
        [NSApp setPresentationOptions:NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar];
        self.window.level = NSMainMenuWindowLevel + 1;
        [self.window setFrame:frame display:YES];
        [self.window makeKeyAndOrderFront:nil];
        [self.window makeFirstResponder:self.nav];
        [NSApp activateIgnoringOtherApps:YES];
        [self hideCursor:YES];
        // TV-Shell: nach dem Aufwachen des Bildschirms ist Sofa vorne
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceScreensDidWakeNotification object:nil
            queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) { [NSApp activateIgnoringOtherApps:YES]; }];
        __weak SFAppDelegate *ws = self;
        _remote = [SFRemote new];
        _remote.handler = ^(SFKey k) { [ws.nav sendKey:k]; };
        _remote.updateHandler = ^{ [ws prepareForUpdate]; };
        [_remote start];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screensChanged:)
                                                     name:NSApplicationDidChangeScreenParametersNotification object:nil];
        // Browser-Viewer + Fernbedienung (nur Tailscale-IP/localhost), rendert nur bei Zuschauer
        _dev = [[SFDevServer alloc] initWithNavigator:self.nav port:8765];
        _dev.keyHandler = ^(NSString *k) { [ws devCommand:[@"key " stringByAppendingString:k]]; };
        [_dev start];
    }
}

- (void)screensChanged:(NSNotification *)n {
    NSRect f = [NSScreen mainScreen].frame;
    SFScale = f.size.height / 1080.0;
    [self.window setFrame:f display:YES];
}

// Mauszeiger hat in der 10-Fuß-UI keinen Sinn: unsichtbar, solange Sofa vorne ist.
// Drei Schichten, weil das System den Zeiger in vielen Lagen wieder einblendet (Display-Wake,
// App-Wechsel, Cursor-Setzen anderer Prozesse) und Hide/Show-Zählung dabei auseinanderläuft:
//  1. transparenter Cursor für das ganze Fenster (Cursor-Rects in SFNavigator + set)
//  2. Wächter (1 s): ist der Zeiger sichtbar, obwohl Sofa vorne ist -> wieder ausblenden (+ Log)
//  3. beim Verlassen (andere App vorne) zuverlässig wieder einblenden
- (void)enforceCursorHidden {
    if (SFDevMode || ![NSApp isActive]) return;
    [SFBlankCursor() set];
    if (CGCursorIsVisible()) {
        CGDisplayHideCursor(kCGNullDirectDisplay);
        static NSDate *lastLog;
        if (!lastLog || -[lastLog timeIntervalSinceNow] > 60) { lastLog = [NSDate date]; SFLog(@"cursor: war sichtbar -> ausgeblendet"); }
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
    [[SFLounge shared] stop];   // Handy: "getrennt" (best effort, max 1,5 s). Nicht beim Update – da sind wir in 1 s zurück.
    for (SFScreen *s in self.nav.stack.reverseObjectEnumerator) [s willDisappear];
    [[SFStore shared] flush];
}

#pragma mark Erster Start

// Einmalige Begrüßung mit der Tastenbelegung (7-Tasten-Apple-Remote): nur bei wirklich neuer
// Installation – wer schon Sendungen/Kanälen folgt oder Fortschritt hat, kennt Sofa.
// Dev: SOFA_WELCOME=1 zeigt sie immer (Test), sonst nie.
- (void)welcomeIfFirstRun {
    SFStore *st = [SFStore shared];
    BOOL force = SFDevMode && getenv("SOFA_WELCOME");
    if (!force) {
        if (SFDevMode || [st setting:@"welcome.shown"].length) return;
        [st setSetting:@"1" forKey:@"welcome.shown"];
        if ([[SFFollows shared] follows:nil].count || [st continueWatching:1 source:nil].count) return;
    }
    // danach: Start-Einstellungen abfragen (nur Neuinstallation; änderbar unter „Einstellungen“)
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

// Release direkt aus der DMG (oder einem anderen Ordner) gestartet: Fernbedienung und Autostart
// werden dann bewusst nicht eingerichtet (sie zeigten auf die DMG) -- sagen, was zu tun ist.
- (void)askToMoveIfMisplaced {
    if (SFDevMode || !SFRuntimeMisplaced()) return;
    SFLog(@"start: Sofa läuft nicht aus „Programme“ (%@)", [[NSBundle mainBundle] bundlePath]);
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

// Ersteinrichtung, Frage 1/2: beim Anmelden starten?
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

// Ersteinrichtung, Frage 2/2: mit der Apple Remote starten?
- (void)askRemoteLaunch {
    __weak SFAppDelegate *ws = self;
    void (^done)(BOOL) = ^(BOOL on) {
        SFSetRemoteLaunchEnabled(on);
        SFSetStartupQuestionsAsked();
        SFLog(@"start: Ersteinrichtung autostart=%d remoteLaunch=%d", SFAutostartEnabled(), on);
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

#pragma mark Autostart (Einstellung „Beim Anmelden starten“)
// Der Autostart-Agent (de.sofa.app) startet Sofa mit --autostart und startet es nach einem Absturz
// neu (KeepAlive). Ist Autostart aus, beendet sich Sofa beim Anmelden sofort still – nach einem
// Absturz (Marker „running“ noch da) läuft es aber weiter.
static NSString *SFRunningMarker(void) { return [SFAppSupportDir() stringByAppendingPathComponent:@"running"]; }
void SFClearRunningMarker(void) {
    if (!SFDevMode) [[NSFileManager defaultManager] removeItemAtPath:SFRunningMarker() error:nil];
}
static void SFSetRunningMarker(void) {
    if (!SFDevMode) [[NSFileManager defaultManager] createFileAtPath:SFRunningMarker() contents:nil attributes:nil];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        SFRuntimeSetup();
        NSApplication *app = [NSApplication sharedApplication];
        SFAppDelegate *del = [SFAppDelegate new];
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--dev")) SFDevMode = YES;
            else if (!strcmp(argv[i], "--instance") && i + 1 < argc) gInstance = @(argv[++i]);
            else if (!strcmp(argv[i], "--port") && i + 1 < argc) gPort = (uint16_t)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--size") && i + 1 < argc) {
                int w = 0, h = 0;
                if (sscanf(argv[++i], "%dx%d", &w, &h) == 2) del.devSize = NSMakeSize(w, h);
            }
        }
        if (SFDevMode) SFLogFileName = [NSString stringWithFormat:@"Sofa-dev-%@.log", gInstance];
        BOOL autostart = NO;
        for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--autostart")) autostart = YES;
        if (autostart && !SFDevMode && !SFAutostartEnabled()) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:SFRunningMarker()]) {
                SFLog(@"start: Autostart ist aus – beende");
                return 0;   // exit 0: launchd (KeepAlive SuccessfulExit=false) startet nicht neu
            }
            SFLog(@"start: Autostart aus, aber letzter Lauf endete unerwartet – starte trotzdem");
        }
        SFSetRunningMarker();
        // Dev: nie im Dock, nie im Vordergrund (stört Kodi nicht).
        app.activationPolicy = SFDevMode ? NSApplicationActivationPolicyProhibited : NSApplicationActivationPolicyRegular;
        app.delegate = del;
        [app run];
    }
    return 0;
}
