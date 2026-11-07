#import "SFModel.h"
#import "SFYTBrowser.h"
#import "SFRuntime.h"
#include <spawn.h>
#include <signal.h>
#include <poll.h>
#include <libproc.h>
#include <sys/wait.h>

extern char **environ;

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
        // nobody looks at this browser: no first-run pages, prompts or crash-restore dialogs
        @"browser.shell.checkDefaultBrowser": @NO, @"browser.aboutwelcome.enabled": @NO,
        @"browser.startup.homepage_override.mstone": @"ignore", @"browser.sessionstore.resume_from_crash": @NO,
        @"browser.startup.page": @0,
        @"datareporting.policy.dataSubmissionEnabled": @NO, @"toolkit.telemetry.reportingpolicy.firstRun": @NO,
        @"app.update.enabled": @NO, @"toolkit.telemetry.enabled": @NO,
        // the TV's languages
        @"intl.accept_languages": @"de-AT, de, en-US, en",
        // the engine never plays anything itself; a page that does stays silent
        @"media.volume_scale": @"0.0",
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

// The environment of Sofa minus what must not reach the browser, plus `extra`.
static char **Environment(NSDictionary *extra) {
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    for (NSString *k in @[@"DYLD_INSERT_LIBRARIES", @"MOZ_HEADLESS", @"DISPLAY"]) [env removeObjectForKey:k];
    [env addEntriesFromDictionary:extra];
    char **e = calloc(env.count + 1, sizeof(char *));
    __block size_t i = 0;
    [env enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { e[i++] = strdup([NSString stringWithFormat:@"%@=%@", k, v].UTF8String); }];
    return e;
}

static void FreeStrings(char **a) { for (char **p = a; *p; p++) free(*p); free(a); }

// posix_spawn with only stdin (`in`, or /dev/null when < 0), stdout+stderr (`log`) and, if >= 0,
// `fd3` as fd 3.
static pid_t Spawn(NSString *path, NSArray *args, NSDictionary *env, int in, int log, int fd3) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (in >= 0) posix_spawn_file_actions_adddup2(&fa, in, 0);
    else posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, log, 1);
    posix_spawn_file_actions_adddup2(&fa, log, 2);
    if (fd3 >= 0) posix_spawn_file_actions_adddup2(&fa, fd3, 3);
    posix_spawnattr_t at;
    posix_spawnattr_init(&at);
    // nothing else inherited, an own process group, and signals as a fresh process has them: the
    // caller is a GCD thread with most signals blocked, and a child inheriting that mask ignored
    // SIGTERM (measured 2026-11-07: Firefox and Xvfb outlived every stop)
    posix_spawnattr_setflags(&at, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    posix_spawnattr_setpgroup(&at, 0);
    sigset_t none, all;
    sigemptyset(&none); sigfillset(&all);
    posix_spawnattr_setsigmask(&at, &none);
    posix_spawnattr_setsigdefault(&at, &all);
    char **argv = calloc(args.count + 2, sizeof(char *));
    argv[0] = strdup(path.UTF8String);
    for (NSUInteger i = 0; i < args.count; i++) argv[i + 1] = strdup([args[i] UTF8String]);
    char **envp = Environment(env);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path.UTF8String, &fa, &at, argv, envp);
    FreeStrings(argv); FreeStrings(envp);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&at);
    if (rc != 0) { SFLog(@"yt-browser: cannot start %@: %s", path.lastPathComponent, strerror(rc)); return 0; }
    return pid;
}

// Ends `pid` if it still is one of ours (its executable's name), TERM then KILL.
static void EndProcess(pid_t pid, NSString *name) {
    if (pid <= 0) return;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof path) <= 0) return;   // gone
    if (![[@(path) lastPathComponent] isEqualToString:name]) return;   // the pid was reused by another program
    kill(pid, SIGTERM);
    for (int i = 0; i < 50 && kill(pid, 0) == 0; i++) {
        if (waitpid(pid, NULL, WNOHANG) == pid) return;
        usleep(100000);
    }
    if (kill(pid, 0) == 0) { kill(pid, SIGKILL); waitpid(pid, NULL, WNOHANG); }
}

@implementation SFYTBrowser {
    NSString *_profile;
    pid_t _xvfb, _firefox, _watcher;
    int _lifeline;              // Sofa's end of the watcher's pipe; -1 without a watcher
    dispatch_source_t _xvfbWatch, _firefoxWatch;
    BOOL _stopping;
}

- (instancetype)initWithProfile:(NSString *)profileDir {
    if ((self = [super init])) { _profile = profileDir; _lifeline = -1; }
    return self;
}

static NSString *BuiltExtension(void) { return [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"youtube-engine"]; }
- (NSString *)extensionCopy { return [_profile stringByAppendingString:@"-extension"]; }
- (NSString *)pidFile { return [_profile stringByAppendingString:@"-processes.json"]; }
- (NSString *)logFile { return [_profile stringByAppendingString:@"-firefox.log"]; }

- (BOOL)available {
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm isExecutableFileAtPath:SFTool(@"firefox")] && [fm isExecutableFileAtPath:SFTool(@"Xvfb")]
        && [fm fileExistsAtPath:[BuiltExtension() stringByAppendingPathComponent:@"manifest.json"]];
}

- (BOOL)running { return _firefox > 0; }

#pragma mark Profile

// The profile as the engine needs it: prefs, and the extension installed unpacked (a copy with
// config.json, referenced by a proxy file) with its host permissions granted - MV3 leaves them to
// the user, and a sideloaded extension starts without them (its content scripts never run).
- (BOOL)prepareProfileForPort:(uint16_t)port token:(NSString *)token {
    NSFileManager *fm = [NSFileManager defaultManager];
    // one tab, the one Sofa opens: no session restore after a hard end (it brought the previous
    // tab back next to the new one - two engine pages, the second replacing the first mid-start,
    // measured 2026-11-07). Cookies and storage are elsewhere and stay.
    for (NSString *f in @[@"sessionstore.jsonlz4", @"sessionstore-backups"]) [fm removeItemAtPath:[_profile stringByAppendingPathComponent:f] error:nil];
    NSString *ext = [self extensionCopy], *exts = [_profile stringByAppendingPathComponent:@"extensions"];
    [fm createDirectoryAtPath:exts withIntermediateDirectories:YES attributes:nil error:nil];
    // The installed copy changes only when its content does (a new build, another port or token):
    // Firefox takes a changed unpacked extension for an update and injects its content scripts
    // into the already loaded tab - a second engine in the same document (measured 2026-11-07).
    NSData *cfg = [NSJSONSerialization dataWithJSONObject:@{@"port": @(port), @"token": token} options:0 error:nil];
    NSString *stamp = [NSString stringWithContentsOfFile:[BuiltExtension() stringByAppendingPathComponent:@"STAMP"] encoding:NSUTF8StringEncoding error:nil];
    BOOL same = stamp && [stamp isEqualToString:[NSString stringWithContentsOfFile:[ext stringByAppendingPathComponent:@"STAMP"] encoding:NSUTF8StringEncoding error:nil]]
        && [cfg isEqualToData:[NSData dataWithContentsOfFile:[ext stringByAppendingPathComponent:@"config.json"]]];
    NSError *e = nil;
    if (!same) {
        [fm removeItemAtPath:ext error:nil];
        if (![fm copyItemAtPath:BuiltExtension() toPath:ext error:&e]) { SFLog(@"yt-browser: extension copy failed: %@", e.localizedDescription); return NO; }
        if (![cfg writeToFile:[ext stringByAppendingPathComponent:@"config.json"] atomically:YES]) return NO;
    }
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[ext stringByAppendingPathComponent:@"manifest.json"]] ?: [NSData data] options:0 error:nil];
    NSArray *origins = [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"host_permissions"] : nil;
    if (![origins isKindOfClass:[NSArray class]]) { SFLog(@"yt-browser: extension manifest without host_permissions"); return NO; }
    NSString *grantsFile = [_profile stringByAppendingPathComponent:@"extension-preferences.json"];
    NSMutableDictionary *grants = [[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:grantsFile] ?: [NSData data]
                                                                    options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    if (![grants isKindOfClass:[NSMutableDictionary class]]) grants = [NSMutableDictionary new];
    grants[kExtensionID] = @{@"permissions": @[], @"origins": origins};
    NSString *proxy = [exts stringByAppendingPathComponent:kExtensionID];   // unchanged unless it must (as above)
    BOOL proxyOK = [[NSString stringWithContentsOfFile:proxy encoding:NSUTF8StringEncoding error:nil] isEqualToString:ext]
        || [ext writeToFile:proxy atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return proxyOK
        && [[NSJSONSerialization dataWithJSONObject:grants options:0 error:nil] writeToFile:grantsFile atomically:YES]
        && [UserJS(EnginePrefs()) writeToFile:[_profile stringByAppendingPathComponent:@"user.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark Processes

- (void)launchWithChannelPort:(uint16_t)port token:(NSString *)token done:(void (^)(BOOL))done {
    _stopping = NO;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self endLeftovers];
        BOOL ok = [self prepareProfileForPort:port token:token] && [self startDisplayAndBrowser];
        SFMain(^{
            if (ok) [self watchProcesses];
            else [self stop];
            done(ok);
        });
    });
}

// What a crashed Sofa left running on this profile (Firefox would refuse a locked profile).
- (void)endLeftovers {
    NSDictionary *old = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[self pidFile]] ?: [NSData data] options:0 error:nil];
    if (![old isKindOfClass:[NSDictionary class]]) return;
    EndProcess([old[@"firefox"] intValue], @"firefox");
    EndProcess([old[@"xvfb"] intValue], @"Xvfb");
    [[NSFileManager defaultManager] removeItemAtPath:[self pidFile] error:nil];
}

- (BOOL)startDisplayAndBrowser {
    int log = open([self logFile].fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (log < 0) return NO;
    int p[2];
    if (pipe(p) != 0) { close(log); return NO; }
    // -displayfd: Xvfb picks a free display and writes its number once it accepts clients;
    // -terminate: it ends with its last client (the browser) - no display outlives a crashed Sofa
    _xvfb = Spawn(SFTool(@"Xvfb"), @[@"-displayfd", @"3", @"-terminate", @"-screen", @"0", [NSString stringWithFormat:@"%dx%dx24", kScreenW, kScreenH], @"-nolisten", @"tcp"], @{}, -1, log, p[1]);
    close(p[1]);
    char buf[16] = {0};
    ssize_t n = 0;
    struct pollfd pf = {p[0], POLLIN, 0};
    if (_xvfb > 0 && poll(&pf, 1, kDisplayWaitMS) == 1) n = read(p[0], buf, sizeof buf - 1);
    close(p[0]);
    int display = n > 0 ? atoi(buf) : -1;
    if (display < 0 || !(n > 0 && buf[0] >= '0' && buf[0] <= '9')) { SFLog(@"yt-browser: no display from Xvfb"); close(log); return NO; }
    _firefox = Spawn(SFTool(@"firefox"), @[@"--no-remote", @"--profile", _profile, @"--width", @(kScreenW).stringValue,
                                           @"--height", @(kScreenH).stringValue, @"https://www.youtube.com/"],
                     @{@"DISPLAY": [NSString stringWithFormat:@":%d", display]}, -1, log, -1);
    if (_firefox > 0) [self startWatcher:log];
    close(log);
    NSData *pids = [NSJSONSerialization dataWithJSONObject:@{@"xvfb": @(_xvfb), @"firefox": @(_firefox)} options:0 error:nil];
    [pids writeToFile:[self pidFile] atomically:YES];
    if (_firefox <= 0) return NO;
    SFLog(@"yt-browser: Firefox %d on display :%d (Xvfb %d)", _firefox, display, _xvfb);
    return YES;
}

// Watcher: a shell that reads a pipe only Sofa writes to. However Sofa ends - quit, crash, kill -9 -
// the kernel closes its end, the read returns and the shell ends browser and display. (Sofa's end
// is close-on-exec: no other child keeps it open.) Firefox could not do this itself reliably: an
// MV3 background is an event page and may sleep between polls.
- (void)startWatcher:(int)log {
    int p[2];
    if (pipe(p) != 0) return;
    fcntl(p[1], F_SETFD, FD_CLOEXEC);
    _watcher = Spawn(@"/bin/sh", @[@"-c", @"read _; kill $0 $1 2>/dev/null", @(_firefox).stringValue, @(_xvfb).stringValue], @{}, p[0], log, -1);
    close(p[0]);
    if (_watcher > 0) _lifeline = p[1]; else close(p[1]);
}

- (void)endWatcher {
    if (_lifeline >= 0) close(_lifeline);   // the watcher's read returns; what it kills is ending anyway
    _lifeline = -1;
    pid_t w = _watcher;
    _watcher = 0;
    if (w > 0) dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{ waitpid(w, NULL, 0); });
}

- (dispatch_source_t)watch:(pid_t)pid name:(NSString *)name {
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    __weak SFYTBrowser *ws = self;
    dispatch_source_set_event_handler(s, ^{
        int st = 0;
        waitpid(pid, &st, WNOHANG);
        [ws exited:pid why:[NSString stringWithFormat:@"%@ exited (%d)", name, WIFEXITED(st) ? WEXITSTATUS(st) : -WTERMSIG(st)]];
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

- (void)stop {
    _stopping = YES;
    for (dispatch_source_t s in @[_xvfbWatch ?: [NSNull null], _firefoxWatch ?: [NSNull null]]) if ((id)s != [NSNull null]) dispatch_source_cancel(s);
    _xvfbWatch = _firefoxWatch = nil;
    EndProcess(_firefox, @"firefox");
    EndProcess(_xvfb, @"Xvfb");
    _firefox = _xvfb = 0;
    [self endWatcher];
    [[NSFileManager defaultManager] removeItemAtPath:[self pidFile] error:nil];
}
@end
