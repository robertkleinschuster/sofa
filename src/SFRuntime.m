#import "SFRuntime.h"

static NSString *const kPrefix = @"/opt/local";   // Port: reinplace auf ${prefix}

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

NSString *SFTool(NSString *name) {
    NSString *rt = SFRuntimeDir();
    return [(rt ?: kPrefix) stringByAppendingPathComponent:[@"bin" stringByAppendingPathComponent:name]];
}

NSString *SFPythonPath(void) {
    NSString *rt = SFRuntimeDir();
    return rt ? [rt stringByAppendingPathComponent:@"Python.framework/Versions/3.14/bin/python3.14"]
              : [kPrefix stringByAppendingPathComponent:@"bin/python3.14"];
}

NSString *SFCABundle(void) {
    NSString *rt = SFRuntimeDir();
    return rt ? [rt stringByAppendingPathComponent:@"etc/cert.pem"] : nil;
}

void SFRuntimeSetup(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");   // Entwicklungs-Shell-Shim nie an Werkzeuge vererben
    NSString *rt = SFRuntimeDir();
    NSString *bin = [(rt ?: kPrefix) stringByAppendingPathComponent:@"bin"];
    setenv("PATH", [bin stringByAppendingString:@":/usr/bin:/bin:/usr/sbin:/sbin"].UTF8String, 1);
    setenv("SOFA_NODE", SFTool(@"node").UTF8String, 1);
    if (!rt) return;
    // Python-ssl/pip/yt-dlp, node (bgutil) und ffmpeg: CA-Liste aus dem Bundle
    setenv("SSL_CERT_FILE", SFCABundle().UTF8String, 1);
    setenv("NODE_EXTRA_CA_CERTS", SFCABundle().UTF8String, 1);
    // fontconfig (librsvg/pango, canvas im PO-Token-Server): Systemschriften, Cache im Benutzer-Cache
    setenv("FONTCONFIG_FILE", [rt stringByAppendingPathComponent:@"etc/fonts/fonts.conf"].UTF8String, 1);
    setenv("FONTCONFIG_PATH", [rt stringByAppendingPathComponent:@"etc/fonts"].UTF8String, 1);
}

static BOOL SFWriteAgent(NSString *label, NSString *exe, BOOL keepAlive) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"];
    NSString *path = [dir stringByAppendingPathComponent:[label stringByAppendingPathExtension:@"plist"]];
    // gleiche Werte wie res/launchd/*.plist (Port)
    NSDictionary *want = @{
        @"Label": label,
        @"ProgramArguments": @[exe],
        @"RunAtLoad": @YES,
        @"KeepAlive": keepAlive ? (id)@YES : (id)@{@"SuccessfulExit": @NO},
        @"ThrottleInterval": @5,
        @"LimitLoadToSessionType": @"Aqua",
        @"ProcessType": @"Interactive",
    };
    if ([[NSDictionary dictionaryWithContentsOfFile:path] isEqualToDictionary:want]) return NO;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [want writeToFile:path atomically:YES];
}

static void SFLaunchctl(NSArray *args) {
    NSTask *t = [NSTask launchedTaskWithLaunchPath:@"/bin/launchctl" arguments:args];
    [t waitUntilExit];
}

void SFInstallAgents(void) {
    if (!SFRuntimeDir()) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:@"/Library/LaunchAgents/org.macports.sofa-remote.plist"]) return;
    NSString *app = [[NSBundle mainBundle] bundlePath];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"];
    if (SFWriteAgent(@"de.sofa.remote", [app stringByAppendingPathComponent:@"Contents/MacOS/SofaRemote"], YES)) {
        NSString *p = [dir stringByAppendingPathComponent:@"de.sofa.remote.plist"];
        SFLaunchctl(@[@"unload", p]);
        SFLaunchctl(@[@"load", @"-w", p]);
        NSLog(@"Sofa: Fernbedienungs-Helper eingerichtet (%@)", app);
    }
    // Autostart: erst ab der nächsten Anmeldung aktiv (jetzt laden startete ein zweites Sofa)
    SFWriteAgent(@"de.sofa.app", [app stringByAppendingPathComponent:@"Contents/MacOS/Sofa"], NO);
}
