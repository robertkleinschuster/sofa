// SofaRemote — Apple Remote helper (LaunchAgent).
//
// Holds the AppleIRController exclusively (seize), detects short/long presses of the
// aluminium remote (7 buttons), and
//   * forwards buttons to Sofa via Mach port (Sofa in the foreground),
//   * launches Sofa with MENU when it isn't running (Front Row principle),
//   * translates buttons into keyboard events when another app (e.g. Kodi) is in front,
//   * swallows the first press while the display sleeps (only wakes it).
// Unknown HID usages are logged (calibration).
#import <Cocoa/Cocoa.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <netinet/in.h>
#import "../src/Core/SFCore.h"
#import "../src/App/SFRemote.h"
#import "../src/Core/SFRuntime.h"

BOOL SFDevMode = NO;
CGFloat SFScale = 1;

typedef NS_ENUM(NSInteger, RButton) { RNone = -1, RUp, RDown, RLeft, RRight, RSelect, RMenu, RPlay };


@interface SRHelper : NSObject
- (void)start;
@end

// Display state via the IODisplayWrangler (CurrentPowerState < 4 = off/dimmed);
// CGDisplayIsAsleep alone is not reliable for "system awake, display off".
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
        off = st < 3;   // 4 = on, 3 = dimmed, <3 = off
        CFRelease(pm);
    }
    IOObjectRelease(w);
    return off;
}

static NSString *SofaAppPath(void) { return [[NSBundle mainBundle] bundlePath]; }
// If Sofa.app lives in a folder the helper may not write to (MacPorts port:
// /Applications/MacPorts is owned by root), tools/sofa-deploy puts the new bundle here and
// swaps it itself via sudo; the helper only handles save/quit/restart.
static NSString *ExternalUpdateDir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Sofa/update"];
}

#pragma mark PO token server (release bundle only)
// yt-dlp fetches YouTube PO tokens from the bgutil server on 127.0.0.1:4416. The release bundle
// ships it (Contents/Runtime/bgutil) and the helper runs it as a child process: if one is already
// running (e.g. the MacPorts daemon bgutil-pot-server), that one is used. When the helper exits
// (update, logout), the server ends with it -> never a server from an old bundle.
static pid_t gPotPid;   // 0 = no server of our own (also after it ended: terminationHandler)
static void SRStopPot(void) { pid_t p = gPotPid; gPotPid = 0; if (p > 0) kill(p, SIGTERM); }
static BOOL SRPortOpen(uint16_t port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return NO;
    struct sockaddr_in a = {0};
    a.sin_len = sizeof a; a.sin_family = AF_INET; a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL ok = connect(s, (struct sockaddr *)&a, sizeof a) == 0;
    close(s);
    return ok;
}

@implementation SRHelper {
    IOHIDDeviceRef _dev;
    NSTimer *_retry;
    NSString *_sofaPath;
    FILE *_log;
    // array fields of the AppleIRController: cookie -> list of usages (index = value, 1-based)
    NSMutableDictionary *_arrays;      // @(cookie) -> @[@(page<<16|usage), ...]
    NSMutableDictionary *_arrayDown;   // @(cookie) -> @(page<<16|usage) currently pressed
    NSTimer *_updateTimer;
    BOOL _updating;
    BOOL _external;     // update in progress: swap done by tools/sofa-deploy (app folder not writable)
    NSTask *_pot;
    int _potFails;
    ino_t _selfIno;     // file ID of our own executable at launch (Sofa.app replaced? -> restart)
    BOOL _replaced;     // "update" in progress: bundle was replaced from outside (new DMG), no swap
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
    // Sofa path = the bundle the helper itself lives in (Sofa.app/Contents/MacOS/SofaRemote):
    // whether /Applications, /Applications/MacPorts (port) or a development build
    _sofaPath = [[NSFileManager defaultManager] fileExistsAtPath:
                 [SofaAppPath() stringByAppendingPathComponent:@"Contents/MacOS/Sofa"]] ? SofaAppPath() : nil;
    [self log:[NSString stringWithFormat:@"SofaRemote start, Sofa=%@", _sofaPath]];
    [self open];
    _selfIno = [self selfInode];
    _updateTimer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(checkUpdate) userInfo:nil repeats:YES];
    [self checkUpdate];
    atexit(SRStopPot);
    // launchctl unload / logout send SIGTERM: without a handler the helper would end at once, atexit
    // wouldn't run and node would stay orphaned on 4416 (NSTask children have their own process group).
    static dispatch_source_t sigs[2];
    int nums[2] = {SIGTERM, SIGINT};
    for (int i = 0; i < 2; i++) {
        signal(nums[i], SIG_IGN);
        sigs[i] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, nums[i], 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sigs[i], ^{ [self log:@"signal - exiting (with PO token server)"]; exit(0); });
        dispatch_resume(sigs[i]);
    }
    [self superviseServer];
}

- (void)superviseServer {
    NSString *rt = SFRuntimeDir();
    if (!rt) return;   // port/development build: the server comes from the port bgutil-pot-server
    if (!_pot.isRunning && !SRPortOpen(4416)) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *lp = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Sofa-potserver.log"];
        [fm createDirectoryAtPath:[lp stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        // keep the log small: start over above 1 MB
        if ([[fm attributesOfItemAtPath:lp error:nil] fileSize] > 1024 * 1024) [fm removeItemAtPath:lp error:nil];
        if (![fm fileExistsAtPath:lp]) [fm createFileAtPath:lp contents:nil attributes:nil];
        NSFileHandle *lh = [NSFileHandle fileHandleForWritingAtPath:lp] ?: [NSFileHandle fileHandleWithNullDevice];
        [lh seekToEndOfFile];
        NSTask *t = [NSTask new];
        t.launchPath = SFTool(@"node");
        t.arguments = @[[rt stringByAppendingPathComponent:@"bgutil/build/main.js"], @"--host", @"127.0.0.1"];
        t.currentDirectoryPath = [rt stringByAppendingPathComponent:@"bgutil"];
        t.standardOutput = lh; t.standardError = lh;
        t.standardInput = [NSFileHandle fileHandleWithNullDevice];
        t.terminationHandler = ^(NSTask *x) { if (gPotPid == x.processIdentifier) gPotPid = 0; };
        _potFails = 0;
        @try { [t launch]; _pot = t; gPotPid = t.processIdentifier; [self log:@"PO token server started"]; }
        @catch (NSException *e) { [self log:[@"PO token server: " stringByAppendingString:e.reason]]; }
    }
    else if (_pot.isRunning) {
        // if our own server hangs (3 unanswered /ping), restart it
        NSTask *t = _pot;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSURLRequest *r = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:4416/ping"]
                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
            BOOL ok = [NSURLConnection sendSynchronousRequest:r returningResponse:NULL error:NULL] != nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_potFails = ok ? 0 : self->_potFails + 1;
                if (self->_potFails >= 3 && t.isRunning) { [self log:@"PO token server hangs - restarting"]; [t terminate]; }
            });
        });
    }
    // check every 30 s (crashed -> restart)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self superviseServer]; });
}

#pragma mark Update
// tools/sofa-deploy drops /Applications/Sofa.app.staged. The helper (runs
// permanently, KeepAlive) asks Sofa to save its state and quit, swaps
// the bundles (old -> Sofa.app.prev), relaunches Sofa and exits itself —
// launchd then starts it from the new bundle.


- (NSArray *)realSofaProcesses {
    NSMutableArray *a = [NSMutableArray new];
    for (NSRunningApplication *r in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"de.sofa.app"])
        // kill(pid,0) instead of r.terminated: the flag lags several seconds behind
        if (r.activationPolicy != NSApplicationActivationPolicyProhibited && kill(r.processIdentifier, 0) == 0) [a addObject:r];
    return a;
}

- (ino_t)selfInode {
    struct stat st;
    NSString *exe = [SofaAppPath() stringByAppendingPathComponent:@"Contents/MacOS/SofaRemote"];
    return stat(exe.fileSystemRepresentation, &st) == 0 ? st.st_ino : 0;
}

- (void)checkUpdate {
    if (_updating) return;
    [self syncRemote];
    // New version dragged over the old one in Finder: restart Sofa (saving state) and the helper,
    // otherwise the old helper + old PO token server would keep running until the next login.
    ino_t ino = [self selfInode];
    if (!_selfIno) _selfIno = ino;
    else if (ino && ino != _selfIno &&
             [[NSFileManager defaultManager] isExecutableFileAtPath:[SofaAppPath() stringByAppendingPathComponent:@"Contents/MacOS/Sofa"]]) {
        _updating = YES; _replaced = YES;
        [self log:@"Sofa.app was replaced - restarting"];
        BOOL wasRunning = [self realSofaProcesses].count > 0;
        if (wasRunning) {
            CFMessagePortRef port = CFMessagePortCreateRemote(NULL, CFSTR(SF_REMOTE_APP_PORT));
            if (port) { CFMessagePortSendRequest(port, SF_MSG_PREPARE_UPDATE, NULL, 1.0, 0, NULL, NULL); CFRelease(port); }
        }
        [self waitForExit:0 wasRunning:wasRunning];
        return;
    }
    NSString *staged = [SofaAppPath() stringByAppendingString:@".staged"];
    NSString *ext = [ExternalUpdateDir() stringByAppendingPathComponent:@"Sofa.app"];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL external = NO;
    if (![fm isExecutableFileAtPath:[staged stringByAppendingPathComponent:@"Contents/MacOS/Sofa"]]) {
        if (![fm isExecutableFileAtPath:[ext stringByAppendingPathComponent:@"Contents/MacOS/Sofa"]]) return;
        external = YES;
    }
    _updating = YES;
    [self log:@"update found"];
    // Sofa is the TV front end (replaced Kodi): if it was running, it is always relaunched
    // after the update. (Previously only when it was in front - then it stayed off after updates.)
    BOOL wasRunning = [self realSofaProcesses].count > 0;
    _external = external;
    if (wasRunning) {
        CFMessagePortRef port = CFMessagePortCreateRemote(NULL, CFSTR(SF_REMOTE_APP_PORT));
        if (port) { CFMessagePortSendRequest(port, SF_MSG_PREPARE_UPDATE, NULL, 1.0, 0, NULL, NULL); CFRelease(port); }
    }
    [self waitForExit:0 wasRunning:wasRunning];
}

- (void)waitForExit:(int)tries wasRunning:(BOOL)wasRunning {
    NSArray *procs = [self realSofaProcesses];
    if (procs.count && tries > 0 && tries % 8 == 0) {   // ask a newly appeared instance again
        CFMessagePortRef port = CFMessagePortCreateRemote(NULL, CFSTR(SF_REMOTE_APP_PORT));
        if (port) { CFMessagePortSendRequest(port, SF_MSG_PREPARE_UPDATE, NULL, 1.0, 0, NULL, NULL); CFRelease(port); }
    }
    if (procs.count && tries < 40) {   // wait up to 10 s
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self waitForExit:tries + 1 wasRunning:wasRunning];
        });
        return;
    }
    for (NSRunningApplication *r in procs) { [self log:@"Sofa does not quit, forcing"]; [r forceTerminate]; }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (_replaced) {   // nothing to swap: launch the new Sofa, then restart ourselves from the new bundle
        [self ensureSofaRunning:wasRunning ? 6 : 0 then:^{ exit(0); }];
        return;
    }
    if (_external) {   // tools/sofa-deploy does the swap (sudo); we signal "ready" and wait
        [@"" writeToFile:[ExternalUpdateDir() stringByAppendingPathComponent:@"ready"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [self log:@"update (external): Sofa quit, waiting for the swap"];
        [self waitForExternalSwap:0 wasRunning:wasRunning];
        return;
    }
    NSString *prev = [SofaAppPath() stringByAppendingString:@".prev"], *staged = [SofaAppPath() stringByAppendingString:@".staged"];
    NSError *e = nil;
    [fm removeItemAtPath:prev error:nil];
    if (![fm moveItemAtPath:SofaAppPath() toPath:prev error:&e] || ![fm moveItemAtPath:staged toPath:SofaAppPath() error:&e]) {
        [self log:[NSString stringWithFormat:@"update swap failed: %@ — rollback", e]];
        if (![fm fileExistsAtPath:SofaAppPath()]) [fm moveItemAtPath:prev toPath:SofaAppPath() error:nil];
        [fm removeItemAtPath:staged error:nil];
        _updating = NO;
        if (wasRunning) [self launchSofa];
        return;
    }
    [self log:@"update installed, restarting"];
    [self ensureSofaRunning:wasRunning ? 6 : 0 then:^{
        // Exit ourselves: launchd (KeepAlive) starts the helper from the new bundle.
        exit(0);
    }];
}

- (void)waitForExternalSwap:(int)tries wasRunning:(BOOL)wasRunning {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = ExternalUpdateDir(), *ext = [dir stringByAppendingPathComponent:@"Sofa.app"];
    if ([fm fileExistsAtPath:ext] && tries < 240) {   // up to 60 s
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self waitForExternalSwap:tries + 1 wasRunning:wasRunning];
        });
        return;
    }
    [fm removeItemAtPath:[dir stringByAppendingPathComponent:@"ready"] error:nil];
    if ([fm fileExistsAtPath:ext]) {   // nobody swapped -> relaunch the old Sofa
        [self log:@"update (external): no swap within 60 s - discarded"];
        [fm removeItemAtPath:ext error:nil];
        _updating = NO;
        if (wasRunning) [self launchSofa];
        return;
    }
    [self log:@"update installed, restarting"];
    [self ensureSofaRunning:wasRunning ? 6 : 0 then:^{ exit(0); }];   // launchd starts the helper from the new bundle
}

// launchctl start can go nowhere while launchd hasn't reaped the old process yet
// -> check and retry.
- (void)ensureSofaRunning:(int)tries then:(dispatch_block_t)then {
    if (tries <= 0 || [self realSofaProcesses].count) { then(); return; }
    [self launchSofa];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self realSofaProcesses].count) { [self log:@"Sofa running"]; then(); }
        else { [self log:@"Sofa not started yet, retrying"]; [self ensureSofaRunning:tries - 1 then:then]; }
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

// Setting "Mit der Apple Remote starten" (Sofa → settings; preferences domain de.sofa.app,
// default on). Off: while Sofa is closed, the helper releases the IR receiver - the
// remote then controls the Mac again (iTunes, Keynote, volume).
- (BOOL)remoteLaunch {
    CFPreferencesAppSynchronize(CFSTR("de.sofa.app"));
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("remoteLaunch"), CFSTR("de.sofa.app"));
    BOOL on = v ? CFBooleanGetTypeID() == CFGetTypeID(v) && CFBooleanGetValue((CFBooleanRef)v) : YES;
    if (v) CFRelease(v);
    return on;
}

- (BOOL)wantsRemote { return [self remoteLaunch] || [self realSofa] != nil; }

// every 3 s (checkUpdate): seize or release IR when the situation or the setting changes
- (void)syncRemote {
    BOOL want = [self wantsRemote];
    if (want && !_dev && !_retry.isValid) [self open];
    else if (!want && _dev) {
        [self log:@"Sofa closed, launch via remote off - Apple Remote released"];
        [self closeDevice];
    }
}

- (void)closeDevice {
    [_retry invalidate]; _retry = nil;
    if (!_dev) return;
    IOHIDDeviceUnscheduleFromRunLoop(_dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDDeviceClose(_dev, kIOHIDOptionsTypeNone);
    CFRelease(_dev); _dev = NULL;
}

- (void)open {
    if (![self wantsRemote]) return;   // syncRemote catches up as soon as Sofa runs
    io_service_t s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleIRController"));
    // Macs without an IR receiver: report once, not every 5 s (Sofa then runs with keyboard/phone)
    static BOOL saidNoIR;
    if (!s) { if (!saidNoIR) [self log:@"no AppleIRController (no IR receiver?) - still looking"]; saidNoIR = YES; [self scheduleRetry]; return; }
    _dev = IOHIDDeviceCreate(kCFAllocatorDefault, s);
    IOObjectRelease(s);
    if (!_dev) { [self scheduleRetry]; return; }
    IOReturn r = IOHIDDeviceOpen(_dev, kIOHIDOptionsTypeSeizeDevice);
    if (r != kIOReturnSuccess) {
        static IOReturn lastErr;
        if (r != lastErr) [self log:[NSString stringWithFormat:@"seize failed 0x%x (XBMCHelper active?) — retrying every 5 s", r]];
        lastErr = r;
        CFRelease(_dev); _dev = NULL;
        [self scheduleRetry];
        return;
    }
    [self buildArrayMap];
    IOHIDDeviceRegisterInputValueCallback(_dev, inputCallback, (__bridge void *)self);
    IOHIDDeviceRegisterRemovalCallback(_dev, removalCallback, (__bridge void *)self);
    IOHIDDeviceScheduleWithRunLoop(_dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    [self log:@"Apple IR opened exclusively"];
}

// On 10.9 the aluminium remote reports buttons via array elements (usage 0xFFFFFFFF):
// the value n>0 is the index into the directly following usage elements of the same page,
// 0 = released. The mapping is built from the element list when opening.
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
    [self log:[NSString stringWithFormat:@"array map: %@", _arrays]];
}

- (void)scheduleRetry {
    [_retry invalidate];
    _retry = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(open) userInfo:nil repeats:NO];
}

- (void)deviceGone {
    [self log:@"device removed"];
    [self closeDevice];
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
    // direct usage elements mirror the array values -> don't evaluate twice
    if (_arrays.count) return;
    [self decoded:(page << 16 | usage) down:v != 0];
}

// Calibrated 2026-11-03 (aluminium remote, 10.9): press+release arrive within
// ~2 ms — there is NO hold state. "Long" is only recognisable by dedicated codes
// the remote sends itself (centre long 0x82, left/right long 0xB4/0xB3).
// MENU long cannot be distinguished. Hence only DOWN is evaluated.
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
            [self log:[NSString stringWithFormat:@"unknown page=0x%x usage=0x%x", page, usage]];
            return;
    }
    [self log:[NSString stringWithFormat:@"key page=0x%x usage=0x%x -> %ld", page, usage, (long)k]];
    BOOL wasOff = displayOff();
    static IOPMAssertionID act = kIOPMNullAssertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("Apple Remote"), kIOPMUserActiveLocal, &act);
    if (wasOff) { [self log:@"display was off: press only wakes it"]; [self bringSofaFront]; return; }
    BOOL hold = (k == SFKeySelectHold || k == SFKeyPrev || k == SFKeyNext);
    [self dispatch:k button:b hold:hold];
}

#pragma mark Forwarding

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
    if (!_sofaPath) { [self log:@"Sofa not found"]; return; }
    [self log:@"launching Sofa"];
    // Via LaunchServices like a click in Finder. Not via the agent de.sofa.app: it launches
    // with --autostart, and with autostart switched off Sofa would then quit immediately.
    NSError *e = nil;
    if (![[NSWorkspace sharedWorkspace] launchApplicationAtURL:[NSURL fileURLWithPath:_sofaPath]
                                                       options:NSWorkspaceLaunchDefault configuration:@{} error:&e]) {
        [self log:[NSString stringWithFormat:@"LaunchServices: %@ - launching directly", e.localizedDescription]];
        NSTask *t = [NSTask new];
        t.launchPath = [_sofaPath stringByAppendingPathComponent:@"Contents/MacOS/Sofa"];
        @try { [t launch]; } @catch (NSException *x) { [self log:[@"launch failed: " stringByAppendingString:x.reason]]; }
    }
}

// Sofa is the TV shell: the remote ALWAYS controls Sofa (Kodi compatibility dropped,
// user 2026-11-03). If Sofa isn't running -> any button launches it ("TV on");
// if another app is in front -> the first press brings Sofa to the front (swallowed).
- (NSRunningApplication *)realSofa {
    for (NSRunningApplication *a in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"de.sofa.app"])
        if (a.activationPolicy != NSApplicationActivationPolicyProhibited) return a;   // never dev instances
    return nil;
}

- (void)bringSofaFront {
    NSRunningApplication *a = [self realSofa];
    if (a && !a.active) { [self log:@"Sofa to front"]; [a activateWithOptions:NSApplicationActivateIgnoringOtherApps]; }
}

- (void)dispatch:(SFKey)k button:(RButton)b hold:(BOOL)hold {
    if (_updating) { [self log:@"button ignored during update"]; return; }
    if (![self realSofa]) {   // Sofa closed: any button launches it (setting "Mit der Apple Remote starten")
        if ([self remoteLaunch]) [self launchSofa];
        return;
    }
    if (![self sofaFrontmost]) { [self bringSofaFront]; return; }
    if (![self sendToSofa:k]) [self log:@"Sofa port unreachable"];
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        SFRuntimeSetup();
        // No NSApplication: otherwise the helper registers with LaunchServices as app "Sofa"
        // (same bundle ID de.sofa.app), and Finder/open/NSWorkspace would only activate it
        // instead of launching Sofa. A pure background service only needs the run loop.
        SRHelper *h = [SRHelper new];
        [h start];
        while (1) CFRunLoopRun();
    }
    return 0;
}
