// SofaRemote — Apple-Remote-Helper (LaunchAgent).
//
// Hält den AppleIRController exklusiv (Seize), erkennt Kurz/Lang-Druck der
// Aluminium-Remote (7 Tasten), und
//   * leitet Tasten per Mach-Port an Sofa weiter (Sofa im Vordergrund),
//   * startet Sofa mit MENU, wenn es nicht läuft (Front-Row-Prinzip),
//   * übersetzt Tasten in Tastatur-Events, wenn eine andere App (z.B. Kodi) vorne ist,
//   * schluckt den ersten Druck bei schlafendem Display (weckt nur).
// Unbekannte HID-Usages werden geloggt (Kalibrierung).
#import <Cocoa/Cocoa.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "../src/SFCore.h"
#import "../src/SFRemote.h"

BOOL SFDevMode = NO;
CGFloat SFScale = 1;

typedef NS_ENUM(NSInteger, RButton) { RNone = -1, RUp, RDown, RLeft, RRight, RSelect, RMenu, RPlay };


@interface SRHelper : NSObject
- (void)start;
@end

// Display-Zustand über den IODisplayWrangler (CurrentPowerState < 4 = aus/gedimmt);
// CGDisplayIsAsleep allein ist bei "System wach, Display aus" nicht verlässlich.
static BOOL displayOff(void) {
    if (CGDisplayIsAsleep(CGMainDisplayID())) return YES;
    io_service_t w = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceNameMatching("IODisplayWrangler"));
    if (!w) return NO;
    BOOL off = NO;
    CFDictionaryRef pm = IORegistryEntryCreateCFProperty(w, CFSTR("IOPowerManagement"), NULL, 0);
    if (pm) {
        CFNumberRef n = CFDictionaryGetValue(pm, CFSTR("CurrentPowerState"));
        int st = 4;
        if (n) CFNumberGetValue(n, kCFNumberIntType, &st);
        off = st < 3;   // 4 = an, 3 = gedimmt, <3 = aus
        CFRelease(pm);
    }
    IOObjectRelease(w);
    return off;
}

static NSString *SofaAppPath(void) { return [[NSBundle mainBundle] bundlePath]; }

@implementation SRHelper {
    IOHIDDeviceRef _dev;
    NSTimer *_retry;
    NSString *_sofaPath;
    FILE *_log;
    // Array-Felder des AppleIRController: Cookie -> Liste der Usages (Index = Wert, 1-basiert)
    NSMutableDictionary *_arrays;      // @(cookie) -> @[@(page<<16|usage), ...]
    NSMutableDictionary *_arrayDown;   // @(cookie) -> @(page<<16|usage) aktuell gedrückt
    NSTimer *_updateTimer;
    BOOL _updating;
}


- (void)log:(NSString *)s {
    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS"; }
    fprintf(_log ?: stderr, "%s %s\n", [df stringFromDate:[NSDate date]].UTF8String, s.UTF8String);
    fflush(_log ?: stderr);
}

- (void)start {
    NSString *lp = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SofaRemote.log"];
    _log = fopen(lp.fileSystemRepresentation, "a");
    // Sofa-Pfad = das Bundle, in dem der Helper selbst liegt (Sofa.app/Contents/MacOS/SofaRemote):
    // egal ob /Applications, /Applications/MacPorts (Port) oder Entwicklungs-Build
    _sofaPath = [[NSFileManager defaultManager] fileExistsAtPath:
                 [SofaAppPath() stringByAppendingPathComponent:@"Contents/MacOS/Sofa"]] ? SofaAppPath() : nil;
    [self log:[NSString stringWithFormat:@"SofaRemote start, Sofa=%@", _sofaPath]];
    [self open];
    _updateTimer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(checkUpdate) userInfo:nil repeats:YES];
    [self checkUpdate];
}

#pragma mark Update
// tools/sofa-deploy legt /Applications/Sofa.app.staged ab. Der Helper (läuft
// dauerhaft, KeepAlive) bittet Sofa, Zustand zu sichern und sich zu beenden, tauscht
// die Bundles (alt -> Sofa.app.prev), startet Sofa neu und beendet sich selbst —
// launchd startet ihn dann aus dem neuen Bundle.


- (NSArray *)realSofaProcesses {
    NSMutableArray *a = [NSMutableArray new];
    for (NSRunningApplication *r in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"de.sofa.app"])
        // kill(pid,0) statt r.terminated: das Flag hinkt mehrere Sekunden hinterher
        if (r.activationPolicy != NSApplicationActivationPolicyProhibited && kill(r.processIdentifier, 0) == 0) [a addObject:r];
    return a;
}

- (void)checkUpdate {
    if (_updating) return;
    NSString *staged = [SofaAppPath() stringByAppendingString:@".staged"];
    NSString *bin = [staged stringByAppendingPathComponent:@"Contents/MacOS/Sofa"];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:bin]) return;
    _updating = YES;
    [self log:@"Update gefunden"];
    // Sofa ist die TV-Oberfläche (Kodi abgelöst): lief es, wird es nach dem Update immer
    // wieder gestartet. (Früher nur, wenn es vorne war – dann blieb es nach Updates aus.)
    BOOL wasRunning = [self realSofaProcesses].count > 0;
    if (wasRunning) {
        CFMessagePortRef port = CFMessagePortCreateRemote(NULL, CFSTR(SF_REMOTE_APP_PORT));
        if (port) { CFMessagePortSendRequest(port, SF_MSG_PREPARE_UPDATE, NULL, 1.0, 0, NULL, NULL); CFRelease(port); }
    }
    [self waitForExit:0 wasRunning:wasRunning];
}

- (void)waitForExit:(int)tries wasRunning:(BOOL)wasRunning {
    NSArray *procs = [self realSofaProcesses];
    if (procs.count && tries > 0 && tries % 8 == 0) {   // neu aufgetauchte Instanz erneut bitten
        CFMessagePortRef port = CFMessagePortCreateRemote(NULL, CFSTR(SF_REMOTE_APP_PORT));
        if (port) { CFMessagePortSendRequest(port, SF_MSG_PREPARE_UPDATE, NULL, 1.0, 0, NULL, NULL); CFRelease(port); }
    }
    if (procs.count && tries < 40) {   // bis 10 s warten
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self waitForExit:tries + 1 wasRunning:wasRunning];
        });
        return;
    }
    for (NSRunningApplication *r in procs) { [self log:@"Sofa beendet sich nicht, erzwinge"]; [r forceTerminate]; }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *prev = [SofaAppPath() stringByAppendingString:@".prev"], *staged = [SofaAppPath() stringByAppendingString:@".staged"];
    NSError *e = nil;
    [fm removeItemAtPath:prev error:nil];
    if (![fm moveItemAtPath:SofaAppPath() toPath:prev error:&e] || ![fm moveItemAtPath:staged toPath:SofaAppPath() error:&e]) {
        [self log:[NSString stringWithFormat:@"Update-Tausch fehlgeschlagen: %@ — Rollback", e]];
        if (![fm fileExistsAtPath:SofaAppPath()]) [fm moveItemAtPath:prev toPath:SofaAppPath() error:nil];
        [fm removeItemAtPath:staged error:nil];
        _updating = NO;
        if (wasRunning) [self launchSofa];
        return;
    }
    [self log:@"Update installiert, starte neu"];
    [self ensureSofaRunning:wasRunning ? 6 : 0 then:^{
        // Selbst beenden: launchd (KeepAlive) startet den Helper aus dem neuen Bundle.
        exit(0);
    }];
}

// launchctl start kann ins Leere gehen, solange launchd den alten Prozess noch nicht
// abgeräumt hat -> prüfen und wiederholen.
- (void)ensureSofaRunning:(int)tries then:(dispatch_block_t)then {
    if (tries <= 0 || [self realSofaProcesses].count) { then(); return; }
    [self launchSofa];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self realSofaProcesses].count) { [self log:@"Sofa läuft"]; then(); }
        else { [self log:@"Sofa noch nicht gestartet, erneut"]; [self ensureSofaRunning:tries - 1 then:then]; }
    });
}

#pragma mark HID

static void inputCallback(void *ctx, IOReturn result, void *sender, IOHIDValueRef value) {
    SRHelper *h = (__bridge SRHelper *)ctx;
    IOHIDElementRef el = IOHIDValueGetElement(value);
    [h page:IOHIDElementGetUsagePage(el) usage:IOHIDElementGetUsage(el) value:IOHIDValueGetIntegerValue(value)
     cookie:(uint32_t)IOHIDElementGetCookie(el)];
}

static void removalCallback(void *ctx, IOReturn result, void *sender) {
    SRHelper *h = (__bridge SRHelper *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{ [h deviceGone]; });
}

- (void)open {
    io_service_t s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleIRController"));
    if (!s) { [self log:@"kein AppleIRController"]; [self scheduleRetry]; return; }
    _dev = IOHIDDeviceCreate(kCFAllocatorDefault, s);
    IOObjectRelease(s);
    if (!_dev) { [self scheduleRetry]; return; }
    IOReturn r = IOHIDDeviceOpen(_dev, kIOHIDOptionsTypeSeizeDevice);
    if (r != kIOReturnSuccess) {
        static IOReturn lastErr;
        if (r != lastErr) [self log:[NSString stringWithFormat:@"Seize fehlgeschlagen 0x%x (XBMCHelper aktiv?) — neuer Versuch alle 5 s", r]];
        lastErr = r;
        CFRelease(_dev); _dev = NULL;
        [self scheduleRetry];
        return;
    }
    [self buildArrayMap];
    IOHIDDeviceRegisterInputValueCallback(_dev, inputCallback, (__bridge void *)self);
    IOHIDDeviceRegisterRemovalCallback(_dev, removalCallback, (__bridge void *)self);
    IOHIDDeviceScheduleWithRunLoop(_dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    [self log:@"Apple IR exklusiv geöffnet"];
}

// Auf 10.9 meldet die Aluminium-Remote Tasten über Array-Elemente (Usage 0xFFFFFFFF):
// der Wert n>0 ist der Index in die direkt folgenden Usage-Elemente derselben Page,
// 0 = losgelassen. Die Zuordnung wird beim Öffnen aus der Elementliste gebaut.
- (void)buildArrayMap {
    _arrays = [NSMutableDictionary new];
    _arrayDown = [NSMutableDictionary new];
    NSArray *els = (__bridge_transfer NSArray *)IOHIDDeviceCopyMatchingElements(_dev, NULL, 0);
    els = [els sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [@(IOHIDElementGetCookie((__bridge IOHIDElementRef)a)) compare:@(IOHIDElementGetCookie((__bridge IOHIDElementRef)b))];
    }];
    NSNumber *cur = nil; uint32_t curPage = 0;
    for (id e in els) {
        IOHIDElementRef el = (__bridge IOHIDElementRef)e;
        if (IOHIDElementGetType(el) == kIOHIDElementTypeCollection) continue;
        uint32_t page = IOHIDElementGetUsagePage(el), u = IOHIDElementGetUsage(el);
        if (u == 0xFFFFFFFF) { cur = @((uint32_t)IOHIDElementGetCookie(el)); curPage = page; _arrays[cur] = [NSMutableArray new]; continue; }
        if (cur && page == curPage) [_arrays[cur] addObject:@(page << 16 | u)];
        else cur = nil;
    }
    [self log:[NSString stringWithFormat:@"Array-Map: %@", _arrays]];
}

- (void)scheduleRetry {
    [_retry invalidate];
    _retry = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(open) userInfo:nil repeats:NO];
}

- (void)deviceGone {
    [self log:@"Gerät entfernt"];
    if (_dev) {
        IOHIDDeviceUnscheduleFromRunLoop(_dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDDeviceClose(_dev, kIOHIDOptionsTypeNone);
        CFRelease(_dev); _dev = NULL;
    }
    [self scheduleRetry];
}

- (RButton)buttonForPage:(uint32_t)page usage:(uint32_t)u {
    if (page == 0x0C) {
        switch (u) {
            case 0x40: return RMenu;
            case 0x41: return RSelect;
            case 0x42: return RUp;
            case 0x43: return RDown;
            case 0x44: return RLeft;
            case 0x45: return RRight;
            case 0xCD: case 0xB0: case 0xB1: return RPlay;
            case 0xB5: return RRight;
            case 0xB6: return RLeft;
            case 0xE9: return RUp;
            case 0xEA: return RDown;
        }
    } else if (page == 0x01) {
        switch (u) {
            case 0x86: case 0x85: return RMenu;
            case 0x89: return RSelect;
            case 0x8A: return RRight;
            case 0x8B: return RLeft;
            case 0x8C: return RUp;
            case 0x8D: return RDown;
        }
    }
    return RNone;
}

- (void)page:(uint32_t)page usage:(uint32_t)usage value:(CFIndex)v cookie:(uint32_t)cookie {
    if (usage == 0xFFFFFFFF) {
        NSArray *list = _arrays[@(cookie)];
        if (!list) return;
        if (v > 0 && v <= (CFIndex)list.count) {
            uint32_t pu = [list[v - 1] unsignedIntValue];
            NSNumber *prev = _arrayDown[@(cookie)];
            if (prev && prev.unsignedIntValue != pu) [self decoded:prev.unsignedIntValue down:NO];
            _arrayDown[@(cookie)] = @(pu);
            [self decoded:pu down:YES];
        } else if (v == 0) {
            NSNumber *prev = _arrayDown[@(cookie)];
            [_arrayDown removeObjectForKey:@(cookie)];
            if (prev) [self decoded:prev.unsignedIntValue down:NO];
        }
        return;
    }
    // Direkte Usage-Elemente spiegeln die Array-Werte -> nicht doppelt auswerten
    if (_arrays.count) return;
    [self decoded:(page << 16 | usage) down:v != 0];
}

// Kalibriert 2026-11-03 (Aluminium-Remote, 10.9): Drücken+Loslassen kommen innerhalb
// ~2 ms — es gibt KEINEN Halte-Zustand. "Lang" erkennt man nur an eigenen Codes,
// die die Remote selbst schickt (Mitte lang 0x82, Links/Rechts lang 0xB4/0xB3).
// MENU lang ist nicht unterscheidbar. Ausgewertet wird daher nur DOWN.
- (void)decoded:(uint32_t)pu down:(BOOL)down {
    if (!down) return;
    uint32_t page = pu >> 16, usage = pu & 0xFFFF;
    SFKey k; RButton b;
    switch (pu) {
        case 0x0001008C: case 0x000C0042: k = SFKeyUp; b = RUp; break;
        case 0x0001008D: case 0x000C0043: k = SFKeyDown; b = RDown; break;
        case 0x0001008B: case 0x000C0044: k = SFKeyLeft; b = RLeft; break;
        case 0x0001008A: case 0x000C0045: k = SFKeyRight; b = RRight; break;
        case 0x000C0041: case 0x00010089: k = SFKeySelect; b = RSelect; break;
        case 0x00010086: case 0x000C0040: k = SFKeyMenu; b = RMenu; break;
        case 0x000C00CD: k = SFKeyPlayPause; b = RPlay; break;
        case 0x000C0082: k = SFKeySelectHold; b = RSelect; break;
        case 0x000C00B4: k = SFKeyPrev; b = RLeft; break;
        case 0x000C00B3: k = SFKeyNext; b = RRight; break;
        default:
            [self log:[NSString stringWithFormat:@"unbekannt page=0x%x usage=0x%x", page, usage]];
            return;
    }
    [self log:[NSString stringWithFormat:@"key page=0x%x usage=0x%x -> %ld", page, usage, (long)k]];
    BOOL wasOff = displayOff();
    static IOPMAssertionID act = kIOPMNullAssertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("Apple Remote"), kIOPMUserActiveLocal, &act);
    if (wasOff) { [self log:@"Display war aus: Druck nur zum Wecken"]; [self bringSofaFront]; return; }
    BOOL hold = (k == SFKeySelectHold || k == SFKeyPrev || k == SFKeyNext);
    [self dispatch:k button:b hold:hold];
}

#pragma mark Weiterleitung

- (BOOL)sofaFrontmost {
    NSRunningApplication *f = [NSWorkspace sharedWorkspace].frontmostApplication;
    return [f.bundleIdentifier isEqualToString:@"de.sofa.app"];
}

- (BOOL)sendToSofa:(SFKey)k {
    CFMessagePortRef port = CFMessagePortCreateRemote(NULL, CFSTR(SF_REMOTE_APP_PORT));
    if (!port) return NO;
    SInt32 r = CFMessagePortSendRequest(port, (SInt32)k, NULL, 1.0, 0, NULL, NULL);
    CFRelease(port);
    return r == kCFMessagePortSuccess;
}

- (void)launchSofa {
    if (!_sofaPath) { [self log:@"Sofa nicht gefunden"]; return; }
    [self log:@"starte Sofa"];
    // Einziger Startweg: der LaunchAgent de.sofa.app (gleiche Umgebung wie beim Login).
    NSTask *t = [NSTask launchedTaskWithLaunchPath:@"/bin/launchctl" arguments:@[@"start", @"de.sofa.app"]];
    [t waitUntilExit];
    if (t.terminationStatus != 0) [[NSWorkspace sharedWorkspace] launchApplication:_sofaPath];
}

// Sofa ist die TV-Shell: die Remote bedient IMMER Sofa (Kodi-Kompatibilität entfällt,
// User 2026-11-03). Läuft Sofa nicht -> jede Taste startet es ("Fernseher an");
// ist eine andere App vorne -> erster Druck holt Sofa nach vorne (wird geschluckt).
- (NSRunningApplication *)realSofa {
    for (NSRunningApplication *a in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"de.sofa.app"])
        if (a.activationPolicy != NSApplicationActivationPolicyProhibited) return a;   // nie Dev-Instanzen
    return nil;
}

- (void)bringSofaFront {
    NSRunningApplication *a = [self realSofa];
    if (a && !a.active) { [self log:@"Sofa nach vorne"]; [a activateWithOptions:NSApplicationActivateIgnoringOtherApps]; }
}

- (void)dispatch:(SFKey)k button:(RButton)b hold:(BOOL)hold {
    if (_updating) { [self log:@"Taste während Update ignoriert"]; return; }
    if (![self realSofa]) { [self launchSofa]; return; }
    if (![self sofaFrontmost]) { [self bringSofaFront]; return; }
    if (![self sendToSofa:k]) [self log:@"Sofa-Port nicht erreichbar"];
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication].activationPolicy = NSApplicationActivationPolicyProhibited;
        SRHelper *h = [SRHelper new];
        [h start];
        [NSApp run];
    }
    return 0;
}
