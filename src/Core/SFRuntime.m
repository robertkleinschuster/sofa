#import "SFRuntime.h"
#import <signal.h>

static NSString *const kPrefix = @"/opt/local";   // port: reinplace to ${prefix}

NSString *SFRuntimeDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *d = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Contents/Runtime"];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:[d stringByAppendingPathComponent:@"bin"] isDirectory:&isDir] && isDir)
            dir = d;
    });
    return dir;
}

NSString *SFRuntimePath(NSString *rel) {
    return [(SFRuntimeDir() ?: kPrefix) stringByAppendingPathComponent:rel];
}

NSString *SFTool(NSString *name) { return SFRuntimePath([@"bin" stringByAppendingPathComponent:name]); }

NSString *SFCABundle(void) {
    NSString *rt = SFRuntimeDir();
    return rt ? [rt stringByAppendingPathComponent:@"etc/cert.pem"] : nil;
}

void SFRuntimeSetup(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");   // never pass the development shell shim on to tools
    NSString *rt = SFRuntimeDir();
    NSString *bin = [(rt ?: kPrefix) stringByAppendingPathComponent:@"bin"];
    setenv("PATH", [bin stringByAppendingString:@":/usr/bin:/bin:/usr/sbin:/sbin"].UTF8String, 1);
    if (!rt) return;
    // CA list from the bundle for anything that does verify (OpenSSL/curl)
    setenv("SSL_CERT_FILE", SFCABundle().UTF8String, 1);
    // fontconfig (librsvg/pango): system fonts, cache in the user cache
    setenv("FONTCONFIG_FILE", [rt stringByAppendingPathComponent:@"etc/fonts/fonts.conf"].UTF8String, 1);
    setenv("FONTCONFIG_PATH", [rt stringByAppendingPathComponent:@"etc/fonts"].UTF8String, 1);
    // Neutralise the libraries' built-in MacPorts paths: otherwise the bundle copies of
    // glib/gdk-pixbuf/OpenSSL on a Mac WITH MacPorts would load its modules or configuration
    // (two glib copies in one process).
    setenv("GIO_MODULE_DIR", [rt stringByAppendingPathComponent:@"lib/gio/modules"].UTF8String, 1);
    setenv("GDK_PIXBUF_MODULE_FILE", [rt stringByAppendingPathComponent:@"etc/gdk-pixbuf-loaders.cache"].UTF8String, 1);
    setenv("OPENSSL_CONF", [rt stringByAppendingPathComponent:@"etc/openssl.cnf"].UTF8String, 1);
}

// Bundle version in the agent: when it changes (new DMG dragged over the old one), Sofa reloads the
// helper -- otherwise the old helper would run until the next login.
static NSString *SFBuildID(void) {
    NSDictionary *i = [[NSBundle mainBundle] infoDictionary];
    return [NSString stringWithFormat:@"%@ (%@)", i[@"CFBundleShortVersionString"], i[@"CFBundleVersion"]];
}

static NSString *SFAgentPath(NSString *label) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Library/LaunchAgents/%@.plist", label]];
}

static BOOL SFWriteAgent(NSString *label, NSString *exe, BOOL keepAlive) {
    NSString *path = SFAgentPath(label);
    // same values as res/launchd/*.plist (port)
    NSDictionary *want = @{
        @"Label": label,
        @"ProgramArguments": keepAlive ? @[exe] : @[exe, @"--autostart"],
        @"RunAtLoad": @YES,
        @"KeepAlive": keepAlive ? (id)@YES : (id)@{@"SuccessfulExit": @NO},
        @"ThrottleInterval": @5,
        @"LimitLoadToSessionType": @"Aqua",
        @"ProcessType": @"Interactive",
        @"EnvironmentVariables": @{@"SOFA_BUILD": SFBuildID()},
    };
    if ([[NSDictionary dictionaryWithContentsOfFile:path] isEqualToDictionary:want]) return NO;
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [want writeToFile:path atomically:YES];
}

static void SFLaunchctl(NSArray *args) { SFRunProcess(@"/bin/launchctl", args, 20, NO, NULL); }

BOOL SFRuntimeMisplaced(void) {
    if (!SFRuntimeDir()) return NO;
    NSURL *u = [[NSBundle mainBundle] bundleURL];
    NSNumber *ro = nil;
    [u getResourceValue:&ro forKey:NSURLVolumeIsReadOnlyKey error:NULL];
    if (ro.boolValue) return YES;   // launched straight from the DMG
    NSString *p = u.path;
    if (![p hasSuffix:@".app"]) return YES;   // Sofa.app.staged/.prev: intermediate states of an update
    NSString *dir = [p stringByDeletingLastPathComponent];
    return !([dir isEqualToString:@"/Applications"] ||
             [dir isEqualToString:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]]);
}

void SFInstallAgents(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *labels = @[@"de.sofa.remote", @"de.sofa.app"];
    // MacPorts port installed (same labels in /Library/LaunchAgents): the port wins, our own
    // user agents go -- otherwise the load order would decide which Sofa runs.
    if ([fm fileExistsAtPath:@"/Library/LaunchAgents/org.macports.sofa-remote.plist"]) {
        for (NSString *l in labels) {
            NSString *p = SFAgentPath(l);
            if (![fm fileExistsAtPath:p]) continue;
            SFLaunchctl(@[@"unload", p]);
            [fm removeItemAtPath:p error:nil];
            NSLog(@"Sofa: user agent %@ removed (MacPorts port active)", l);
        }
        return;
    }
    if (!SFRuntimeDir() || SFRuntimeMisplaced()) return;
    NSString *app = [[NSBundle mainBundle] bundlePath];
    if (SFWriteAgent(@"de.sofa.remote", [app stringByAppendingPathComponent:@"Contents/MacOS/SofaRemote"], YES)) {
        NSString *p = SFAgentPath(@"de.sofa.remote");
        SFLaunchctl(@[@"unload", p]);   // the old helper exits (SIGTERM)
        SFLaunchctl(@[@"load", @"-w", p]);
        NSLog(@"Sofa: remote helper set up (%@, %@)", app, SFBuildID());
    }
    // autostart: only active from the next login (loading it now would start a second Sofa)
    SFWriteAgent(@"de.sofa.app", [app stringByAppendingPathComponent:@"Contents/MacOS/Sofa"], NO);
}

int SFRunProcess(NSString *path, NSArray *args, NSTimeInterval timeout, BOOL mergeStderr, NSData **output) {
    NSTask *t = [NSTask new];
    t.launchPath = path; t.arguments = args ?: @[];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    t.environment = env;
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError = mergeStderr ? p : [NSFileHandle fileHandleWithNullDevice];
    t.standardInput = [NSFileHandle fileHandleWithNullDevice];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    t.terminationHandler = ^(NSTask *x) { dispatch_semaphore_signal(done); };
    @try { [t launch]; } @catch (NSException *e) { return -1; }
    pid_t pid = t.processIdentifier;
    __block BOOL timedOut = NO;
    // watchdog: the pipe read below only returns once the child (and anything holding the pipe) exits
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW) == 0) { dispatch_semaphore_signal(done); return; }
        timedOut = YES;
        // (no SFLog here: SFRuntime is also linked into SofaRemote; callers log the -2 result)
        kill(pid, SIGTERM);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW) == 0) { dispatch_semaphore_signal(done); return; }
            kill(pid, SIGKILL);
        });
    });
    NSData *d = [p.fileHandleForReading readDataToEndOfFile];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 5) * NSEC_PER_SEC)));
    dispatch_semaphore_signal(done);   // keep it signalled for the watchdog checks
    if (output) *output = d;
    if (timedOut) return -2;
    return t.isRunning ? -2 : t.terminationStatus;
}
