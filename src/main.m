// Sofa — Einstiegspunkt, Fenster/Kiosk und Dev-Modus.
//
// Dev-Modus (`Sofa --dev [--size WxH]`): Fenster außerhalb des sichtbaren
// Bildschirms, keine Dock-Präsenz, kein Fokus, stumm. Steuerung über die FIFO
// ~/Library/Caches/Sofa/dev.fifo (Zeilen: "key <up|down|left|right|select|menu|play|
// selecthold|menuhold|next|prev>", "shot <pfad.png>", "home", "quit").
#import "SFCore.h"
#import "SFScreen.h"
#import "SFHome.h"
#import "SFRemote.h"
#import "SFStore.h"
#import "SFDevServer.h"
#import "SFMigration.h"
#import "SFNet.h"
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
    [[SFDownloads shared] start];
    // Handy-Koppeln: echte App immer; Dev-Instanz nur mit SOFA_LOUNGE=1 (eigene screenId)
    if (!SFDevMode || getenv("SOFA_LOUNGE")) {
        __weak SFAppDelegate *wl = self;
        [SFLounge shared].commandHandler = ^(NSString *cmd, NSDictionary *args) { [wl loungeCommand:cmd args:args]; };
        [SFLounge shared].playerProvider = ^id { return [wl topPlayer]; };
        [[SFLounge shared] start];
    }
    if (!SFDevMode) [self restoreAfterUpdate];

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
    [[SFLounge shared] stop];   // Handy: "getrennt" (best effort, max 1,5 s). Nicht beim Update – da sind wir in 1 s zurück.
    for (SFScreen *s in self.nav.stack.reverseObjectEnumerator) [s willDisappear];
    [[SFStore shared] flush];
}

#pragma mark Update (Helper tauscht die App; Zustand überlebt)

- (NSString *)resumePath { return [SFAppSupportDir() stringByAppendingPathComponent:@"resume.json"]; }

- (void)prepareForUpdate {
    SFLog(@"update: Zustand sichern und beenden");
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ _exit(0); });
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
        [self.nav toast:@"Sofa wurde aktualisiert"];
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
    } else if ([cmd isEqualToString:@"home"]) {
        [self.nav popToRoot];
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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
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
        // Dev: nie im Dock, nie im Vordergrund (stört Kodi nicht).
        app.activationPolicy = SFDevMode ? NSApplicationActivationPolicyProhibited : NSApplicationActivationPolicyRegular;
        app.delegate = del;
        [app run];
    }
    return 0;
}
