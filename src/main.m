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

void SFClearRunningMarker(void);   // Autostart-Absturzerkennung, siehe main()
#import <ImageIO/ImageIO.h>
#include <sys/stat.h>

BOOL SFDevMode = NO;
static NSString *gInstance = @"view";
static uint16_t gPort = 8765;

@interface SFWindow : NSWindow @end
@implementation SFWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (NSRect)constrainFrameRect:(NSRect)r toScreen:(NSScreen *)s { return SFDevMode ? r : [super constrainFrameRect:r toScreen:s]; }
@end

@interface SFAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) SFWindow *window;
@property (nonatomic, strong) SFNavigator *nav;
@property (nonatomic) NSSize devSize;
@end

@implementation SFAppDelegate {
    dispatch_source_t _fifoSrc;
    NSMutableString *_fifoBuf;
    SFRemote *_remote;
    SFDevServer *_dev;
    NSUInteger _loungeGen;
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

#pragma mark Handy-Koppeln

- (SFPlayerScreen *)topPlayer { return [self.nav.top isKindOfClass:[SFPlayerScreen class]] ? (SFPlayerScreen *)self.nav.top : nil; }

- (void)wakeAndFront {
    if (SFDevMode) return;
    IOPMAssertionID a = 0;
    IOPMAssertionDeclareUserActivity(CFSTR("Sofa: Handy"), kIOPMUserActiveLocal, &a);   // weckt das Display
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)loungeCommand:(NSString *)cmd args:(NSDictionary *)args {
    SFPlayerScreen *p = [self topPlayer];
    if ([cmd isEqualToString:@"remoteConnected"]) {
        [self.nav toast:[NSString stringWithFormat:@"„%@“ verbunden", args[@"name"] ?: @"Handy"]];
    } else if ([cmd isEqualToString:@"setPlaylist"] || [cmd isEqualToString:@"setVideo"]) {
        NSString *ids = args[@"videoIds"] ?: args[@"videoId"] ?: @"";
        NSMutableArray *vids = [NSMutableArray new];
        for (NSString *v in [ids componentsSeparatedByString:@","]) if (v.length == 11) [vids addObject:v];
        if (!vids.count) return;
        NSUInteger idx = MIN((NSUInteger)MAX(0, [args[@"currentIndex"] integerValue]), vids.count - 1);
        NSString *want = args[@"videoId"];
        if (want && ![vids[idx] isEqualToString:want] && [vids indexOfObject:want] != NSNotFound) idx = [vids indexOfObject:want];
        NSTimeInterval t = [args[@"currentTime"] doubleValue];
        NSString *list = args[@"listId"] ?: @"";
        // Läuft genau dieses Video schon (z.B. Handy hat sich neu verbunden): nur springen
        NSMutableArray *curIDs = [NSMutableArray new];
        for (SFItem *q in p.queue) [curIDs addObject:q.externalID ?: @""];
        if (p && [p.item.externalID isEqualToString:vids[idx]] && [p.remoteListID isEqualToString:list] && [curIDs isEqualToArray:vids]) {
            if (fabs([p currentTime] - t) > 3) [p remoteSeekTo:t];
            [p remotePlay];
            return;
        }
        NSMutableArray *items = [NSMutableArray new];
        for (NSString *v in vids) [items addObject:[SFYouTube itemForVideoID:v]];
        [self wakeAndFront];
        NSUInteger gen = ++_loungeGen;   // spätere setPlaylist gewinnt
        [SFYouTube fillDetails:items[idx] done:^{
            if (gen != self->_loungeGen) return;
            SFPlayerScreen *cur = [self topPlayer];
            if (cur.remoteListID) { cur.remoteListID = list; [cur replaceQueue:items index:idx at:t]; }
            else {
                SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:items[idx] queue:items index:idx];
                ps.remoteListID = list;
                if (t > 1) ps.startPosition = t; else ps.startFromBeginning = YES;
                if (cur) [self.nav replaceTop:ps]; else [self.nav push:ps];
            }
            for (NSUInteger k = 0; k < items.count; k++) if (k != idx) [SFYouTube fillDetails:items[k] done:nil];
        }];
    } else if (!p) {
        return;
    } else if ([cmd isEqualToString:@"play"]) { [p remotePlay];
    } else if ([cmd isEqualToString:@"pause"]) { [p remotePause];
    } else if ([cmd isEqualToString:@"seekTo"]) { [p remoteSeekTo:[args[@"newTime"] doubleValue]];
    } else if ([cmd isEqualToString:@"next"]) { [p remoteNext];
    } else if ([cmd isEqualToString:@"previous"]) { [p remotePrevious];
    } else if ([cmd isEqualToString:@"stopVideo"]) { [self.nav pop];
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

#pragma mark Update (Helper tauscht die App; Zustand überlebt)

- (NSString *)resumePath { return [SFAppSupportDir() stringByAppendingPathComponent:@"resume.json"]; }

- (void)prepareForUpdate {
    SFLog(@"update: Zustand sichern und beenden");
    SFClearRunningMarker();   // geplantes Ende, kein Absturz
    NSMutableDictionary *st = [NSMutableDictionary new];
    st[@"t"] = @([NSDate date].timeIntervalSince1970);
    NSMutableArray *keys = [NSMutableArray new];
    for (SFScreen *s in self.nav.stack) if (s.restoreKey) [keys addObject:s.restoreKey];
    st[@"screens"] = keys;
    for (SFScreen *s in self.nav.stack.reverseObjectEnumerator) {
        if (![s isKindOfClass:[SFPlayerScreen class]]) continue;
        SFPlayerScreen *p = (SFPlayerScreen *)s;
        if (p.item) {
            st[@"item"] = [p.item dictionaryRepresentation];
            if ([p currentTime] > 2) st[@"pos"] = @([p currentTime]);
            st[@"paused"] = @([p isPaused]);
        }
        break;
    }
    [[NSJSONSerialization dataWithJSONObject:st options:0 error:nil] writeToFile:[self resumePath] atomically:YES];
    // "Wird aktualisiert"-Bildschirm über allem
    CALayer *ov = [CALayer layer];
    ov.frame = self.nav.layer.bounds;
    ov.backgroundColor = [NSColor colorWithDeviceWhite:0.04 alpha:0.94].CGColor;
    ov.zPosition = 5000;
    SFLabel *l = [SFLabel labelWithFont:[NSFont fontWithName:@"AvenirNext-DemiBold" size:U(44)] color:[NSColor whiteColor]];
    l.text = @"Sofa wird aktualisiert …";
    l.alignment = NSCenterTextAlignment;
    CGFloat h = [l sizeToFitWidth:ov.bounds.size.width];
    l.position = CGPointMake(0, (ov.bounds.size.height - h) / 2);
    [ov addSublayer:l];
    SFNoAnimate(^{ [self.nav.layer addSublayer:ov]; });
    [CATransaction flush];
    for (SFScreen *s in self.nav.stack.reverseObjectEnumerator) [s willDisappear];   // Positionen speichern
    [[SFStore shared] flush];
    SFLog(@"update: gesichert, beende");
    // _exit statt exit: alles ist gespeichert; exit() blieb in Framework-Aufräumhandlern hängen.
    // Auf einer Hintergrund-Queue: ein Main-Queue-Block lief nicht, solange der Main-Runloop
    // in einem anderen Modus steckte -> Helper musste nach 5 s hart beenden (Log „erzwinge“).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{ _exit(0); });
}

- (void)restoreAfterUpdate {
    NSData *d = [NSData dataWithContentsOfFile:[self resumePath]];
    [[NSFileManager defaultManager] removeItemAtPath:[self resumePath] error:nil];
    NSDictionary *st = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![st isKindOfClass:[NSDictionary class]] || [NSDate date].timeIntervalSince1970 - [st[@"t"] doubleValue] > 300) return;
    SFLog(@"update: Wiederherstellung %@", st[@"screens"]);
    for (NSString *k in st[@"screens"]) {
        if ([k hasPrefix:@"app:"]) [self.nav push:[SFHome appScreen:[k substringFromIndex:4]]];
    }
    if ([st[@"item"] isKindOfClass:[NSDictionary class]]) {
        SFItem *it = [SFItem itemWithDictionary:st[@"item"]];
        // Stream-Adresse des alten Prozesses nicht wiederverwenden (scheiterte mit -1102) -> neu auflösen
        if (it.playURL && !it.playURL.isFileURL && it.resolverRef.length) it.playURL = nil;
        SFPlayerScreen *p = [[SFPlayerScreen alloc] initWithItem:it queue:nil index:0];
        if ([st[@"pos"] doubleValue] > 2) p.startPosition = [st[@"pos"] doubleValue] - 2;
        p.startPaused = [st[@"paused"] boolValue];
        [self.nav push:p];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.nav toast:[@"Sofa wurde aktualisiert – Version " stringByAppendingString:[[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"]]];
    });
}

#pragma mark Dev-FIFO

- (void)startFifo {
    NSString *p = [SFCacheDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"dev-%@.fifo", gInstance]];
    unlink(p.fileSystemRepresentation);
    mkfifo(p.fileSystemRepresentation, 0600);
    int fd = open(p.fileSystemRepresentation, O_RDWR | O_NONBLOCK);
    if (fd < 0) { SFLog(@"dev: fifo open failed"); return; }
    _fifoBuf = [NSMutableString new];
    _fifoSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_fifoSrc, ^{
        char buf[4096];
        ssize_t r = read(fd, buf, sizeof buf);
        if (r <= 0) return;
        [self->_fifoBuf appendString:[[NSString alloc] initWithBytes:buf length:r encoding:NSUTF8StringEncoding] ?: @""];
        NSRange nl;
        while ((nl = [self->_fifoBuf rangeOfString:@"\n"]).location != NSNotFound) {
            NSString *line = [self->_fifoBuf substringToIndex:nl.location];
            [self->_fifoBuf deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
            [self devCommand:[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        }
    });
    dispatch_resume(_fifoSrc);
    SFLog(@"dev: fifo ready at %@", p);
}

- (void)devCommand:(NSString *)line {
    if (!line.length) return;
    NSArray *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts[0];
    NSString *arg = parts.count > 1 ? [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" "] : nil;
    SFLog(@"dev: %@", line);
    if ([cmd isEqualToString:@"key"]) {
        NSDictionary *m = @{@"up": @(SFKeyUp), @"down": @(SFKeyDown), @"left": @(SFKeyLeft), @"right": @(SFKeyRight),
                            @"select": @(SFKeySelect), @"menu": @(SFKeyMenu), @"play": @(SFKeyPlayPause),
                            @"selecthold": @(SFKeySelectHold), @"menuhold": @(SFKeyMenuHold),
                            @"next": @(SFKeyNext), @"prev": @(SFKeyPrev), @"uphold": @(SFKeyUpHold), @"downhold": @(SFKeyDownHold)};
        NSNumber *k = m[arg.lowercaseString];
        if (k) [self.nav sendKey:k.integerValue];
    } else if ([cmd isEqualToString:@"shot"] && arg) {
        [self screenshot:arg];
    } else if ([cmd isEqualToString:@"frameshot"] && arg) {   // Dev: echtes mpv-Bild aus dem GL-Framebuffer
        SFMPVDevFrameShot(arg);
    } else if ([cmd isEqualToString:@"home"]) {
        [self.nav popToRoot];
    } else if ([cmd isEqualToString:@"open"] && [arg isEqualToString:@"pair"]) {   // Dev: Seiten direkt öffnen (stabiler als Tastenfolgen)
        [self.nav push:[[SFPairScreen alloc] initWithTheme:[SFTheme themeNamed:@"youtube"]]];
    } else if ([cmd isEqualToString:@"open"] && [arg hasPrefix:@"zdfmeta:"]) {   // Dev: ZDF-Markenseite (Absturztest)
        SFItem *f = [SFItem new]; f.kind = SFItemFolder; f.themeName = @"zdf";
        f.pageLoader = [SFProviderZDF categoryLoader:[arg substringFromIndex:8] title:@"Test"];
        SFOpenItem(self.nav, f, nil, 0);
    } else if ([cmd isEqualToString:@"open"] && [arg hasPrefix:@"ytchannel:"]) {   // Dev: beliebige YouTube-Kanalseite
        SFItem *f = [SFItem new]; f.kind = SFItemFolder; f.themeName = @"youtube"; f.source = @"youtube";
        f.pageLoader = [SFYouTube channelLoader:[arg substringFromIndex:10] title:@"Kanal"];
        SFOpenItem(self.nav, f, nil, 0);
    } else if ([cmd isEqualToString:@"open"] && [arg isEqualToString:@"history"]) {
        SFItem *h = [SFHome historyTile]; SFOpenItem(self.nav, h, nil, 0);
    } else if ([cmd isEqualToString:@"quit"]) {
        [NSApp terminate:nil];
    }
}

- (void)screenshot:(NSString *)path {
    // Kurz warten, damit laufende Animationen/Bildladungen abgeschlossen sind.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Ebenenbaum direkt in eine Bitmap rendern (unabhängig vom Window-Server,
        // funktioniert für das Offscreen-Fenster; Videoebenen bleiben schwarz).
        CALayer *root = self.nav.layer;
        CGSize sz = root.bounds.size;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)sz.width, (size_t)sz.height, 8, 0, cs,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
        CGColorSpaceRelease(cs);
        CGContextTranslateCTM(ctx, 0, sz.height);
        CGContextScaleCTM(ctx, 1, -1);
        SFRenderLayerTree(root, ctx);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        if (!img) { SFLog(@"dev: screenshot failed"); return; }
        CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
        if (!d) { SFLog(@"dev: shot path invalid %@", path); CGImageRelease(img); return; }
        CGImageDestinationAddImage(d, img, NULL);
        CGImageDestinationFinalize(d);
        CFRelease(d); CGImageRelease(img);
        SFLog(@"dev: shot %@", path);
    });
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
