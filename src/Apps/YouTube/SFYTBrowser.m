#import "SFModel.h"
#import "SFYTBrowser.h"
#import "SFRuntime.h"
#import "SFYTPointer.h"
#import "SFYTProcess.h"
#import "SFYTPriority.h"
#import "SFYTEnginePrefs.h"
#import "SFYTRamProfile.h"
#import "SFRest.h"
#include <poll.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <copyfile.h>
#include <sys/stat.h>

static NSString *const kExtensionID = @"youtube-engine@sofa";
static const int kScreenW = 1920, kScreenH = 1080;   // the TV's screen is what the page sees
static const int kDisplayWaitMS = 10000;

@implementation SFYTBrowser {
    NSString *_profile;         // the one the browser uses: the RAM profile, else the disk one (launch queue)
    NSString *_diskProfile;     // the lasting one (and where pid record, extension and log live)
    SFYTRamProfile *_ram;       // real app only
    NSTimer *_syncTimer;        // RAM profile -> disk now and then (main)
    NSTimeInterval _lastSync;
    BOOL _ramFull;              // the RAM disk ran nearly full: the next start runs on the disk profile
    volatile BOOL _onRam;       // the running browser uses the RAM profile: only then is it synced back
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
        _profile = _diskProfile = profileDir; _display = -1;
        // the profile in RAM (SFYTRamProfile): the real app's; dev instances and tests keep theirs on disk
        if (!SFDevMode) _ram = [[SFYTRamProfile alloc] initWithDiskProfile:profileDir mountPoint:[profileDir stringByAppendingString:@"-ram"] sizeMB:512];
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
- (NSString *)extensionCopy { return [_diskProfile stringByAppendingString:@"-extension"]; }
- (NSString *)pidFile { return [_diskProfile stringByAppendingString:@"-processes.json"]; }
- (NSString *)diskLogFile { return [_diskProfile stringByAppendingString:@"-firefox.log"]; }
// the browser's console: on the RAM disk when there is one (copied to the disk log with each sync)
- (NSString *)logFile { NSString *t = [_ram tmpDir]; return t ? [[t stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"firefox.log"] : [self diskLogFile]; }
// TMPDIR for the browser and its display: not /var/folders (macOS removes files there it thinks
// unused for 3 days - by their access time, which noatime no longer keeps)
- (NSString *)tmpDir {
    NSString *t = [_ram tmpDir] ?: [SFSharedCacheDir() stringByAppendingPathComponent:@"engine-tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:t withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    return t;
}

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
        && [SFYTUserJS(SFYTEnginePrefs()) writeToFile:[_profile stringByAppendingPathComponent:@"user.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark Processes

- (void)launchWithChannelPort:(uint16_t)port token:(NSString *)token done:(void (^)(BOOL, BOOL))done {
    _stopping = NO;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_sync(self->_procQ, ^{});   // a background stop still ending the last browser: one profile
        // the profile a running browser uses: its record says (a crash mid-sync may have left the RAM
        // disk's mark behind - the browser on it is still the one to take over and keep syncing)
        NSString *recorded = [self record][@"profile"], *mounted = [self->_ram mountedProfile];
        self->_profile = mounted && [recorded isEqualToString:mounted] ? mounted : [self->_ram existing] ?: self->_diskProfile;
        self->_onRam = mounted && [self->_profile isEqualToString:mounted];
        BOOL adopted = self.handoverGrace > 0 && [self adoptForPort:port token:token];
        BOOL ok = adopted;
        if (!adopted) {
            [self endLeftovers];   // first: the disk profile is filled into RAM only while nobody uses it
            NSString *ram = self->_ramFull ? nil : [self->_ram attach];
            self->_profile = ram ?: self->_diskProfile;
            self->_onRam = ram != nil;
            ok = [self prepareProfileForPort:port token:token] && [self startDisplayAndBrowser];
        }
        SFMain(^{
            if (ok) { [self watchProcesses]; [self applyPriority]; [self scheduleSync]; }   // priority: taken over at background priority, or started while resting
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
                                                          @"watcher": @(_watcher.pid), @"profile": _profile ?: @""} options:0 error:nil];
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
    if (![[NSString stringWithContentsOfFile:[_profile stringByAppendingPathComponent:@"user.js"] encoding:NSUTF8StringEncoding error:nil] isEqualToString:SFYTUserJS(SFYTEnginePrefs())]) {
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
    int log = open([self logFile].fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);   // O_APPEND: it may be truncated (syncNow)
    if (log < 0) return NO;
    int p[2];
    if (pipe(p) != 0) { close(log); return NO; }
    // -displayfd: Xvfb picks a free display and writes its number once it accepts clients;
    // -terminate: it ends with its last client (the browser) - no display outlives the browser;
    // keymaps, xkbcomp and fonts from where Xvfb is (bundle or MacPorts: same as its built-in paths there)
    NSMutableDictionary *xEnv = [MesaEnv() mutableCopy];
    xEnv[@"TMPDIR"] = [self tmpDir];
    pid_t xv = SFYTSpawn(SFTool(@"Xvfb"), @[@"-displayfd", @"3", @"-terminate", @"-screen", @"0", [NSString stringWithFormat:@"%dx%dx24", kScreenW, kScreenH],
                                     @"-nolisten", @"tcp", @"-xkbdir", SFRuntimePath(@"share/X11/xkb"), @"-xkbbindir", SFRuntimePath(@"bin"),
                                     @"-fp", [NSString stringWithFormat:@"%@,built-ins", SFRuntimePath(@"share/fonts/misc")]],
                  xEnv, -1, log, p[1]);
    @synchronized (self) { _xvfb = xv; }
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
    ffEnv[@"TMPDIR"] = xEnv[@"TMPDIR"];
    @synchronized (self) { _pointer = [[SFYTPointer alloc] initWithDisplay:ffEnv[@"DISPLAY"]]; }
    pid_t ff = SFYTSpawn(FirefoxPath(), @[@"--no-remote", @"--profile", _profile, @"--width", @(kScreenW).stringValue,
                                           @"--height", @(kScreenH).stringValue, @"https://www.youtube.com/"],
                     ffEnv, -1, log, -1);
    @synchronized (self) { _firefox = ff; }
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

// RAM profile -> disk: every 30 min while Sofa is awake, every 4 h at most while it rests (only
// changed files; a resting engine changes little), and when the browser ends
- (void)scheduleSync {
    if (!_onRam || _syncTimer) return;
    _lastSync = [NSDate date].timeIntervalSince1970;
    _syncTimer = [NSTimer scheduledTimerWithTimeInterval:1800 target:self selector:@selector(syncTick) userInfo:nil repeats:YES];
    _syncTimer.tolerance = 120;
}
- (void)syncTick {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    // a RAM disk running full makes the browser's writes fail silently (SQLITE_FULL): said, and
    // below 16 MB the next start runs on the (then synced) disk profile
    long long free = [_ram freeBytes];
    BOOL tight = free >= 0 && free < 64LL * 1048576;
    if (tight) SFLog(@"yt-ram: RAM disk nearly full - %.0f MB free (%@)", free / 1048576.0, [_ram consumers]);
    if (tight && free < 16LL * 1048576 && !_ramFull) { _ramFull = YES; SFLog(@"yt-ram: the next browser start runs on the disk profile"); }
    if (!tight && [SFRest resting] && now - _lastSync < 4 * 3600) return;   // at rest every 4 h at most (each sync is a burst of writes)
    _lastSync = now;
    dispatch_async(_procQ, ^{ [self syncNow]; });
}
// on _procQ
- (void)syncNow {
    if (!_onRam) return;   // a browser on the disk profile (RAM disk full, none): nothing to bring back
    [_ram syncForBrowserOn:_profile];
    NSString *log = [self logFile], *disk = [self diskLogFile];   // the console log, for a look after a reboot
    struct stat a, b;
    if (stat(log.fileSystemRepresentation, &a) == 0 && (stat(disk.fileSystemRepresentation, &b) != 0 || a.st_mtime != b.st_mtime || a.st_size != b.st_size))
        copyfile(log.fileSystemRepresentation, disk.fileSystemRepresentation, NULL, COPYFILE_DATA | COPYFILE_STAT);
    if (![log isEqualToString:disk] && stat(log.fileSystemRepresentation, &a) == 0 && a.st_size > 1048576) truncate(log.fileSystemRepresentation, 0);   // copied; the browser appends (O_APPEND)
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
    [_syncTimer invalidate]; _syncTimer = nil;
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
        if (ff > 0) [self syncNow];   // the browser has closed its files: the RAM profile as it ended
    };
    if (!wait) { dispatch_async(_procQ, end); return; }
    // quitting: at most 12 s (macOS may end a slow app at logout/shutdown) - copies are durable per file
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_procQ, ^{ end(); dispatch_semaphore_signal(done); });
    NSDate *t0 = [NSDate date];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)))) SFLog(@"yt-browser: stop still running after 12 s - quitting anyway");
    else if (-[t0 timeIntervalSinceNow] > 1) SFLog(@"yt-browser: stopped and synced in %.1f s", -[t0 timeIntervalSinceNow]);
}
@end
