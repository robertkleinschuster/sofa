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
    // Eingebaute MacPorts-Pfade der Bibliotheken neutralisieren: sonst lüden die Bundle-Kopien von
    // glib/gdk-pixbuf/OpenSSL auf einem Mac MIT MacPorts dessen Module bzw. Konfiguration
    // (zwei glib-Kopien in einem Prozess).
    setenv("GIO_MODULE_DIR", [rt stringByAppendingPathComponent:@"lib/gio/modules"].UTF8String, 1);
    setenv("GDK_PIXBUF_MODULE_FILE", [rt stringByAppendingPathComponent:@"etc/gdk-pixbuf-loaders.cache"].UTF8String, 1);
    setenv("OPENSSL_CONF", [rt stringByAppendingPathComponent:@"etc/openssl.cnf"].UTF8String, 1);
}

// Version des Bundles im Agent: ändert sie sich (neue DMG über die alte gezogen), lädt Sofa den
// Helper neu -- sonst liefe der alte Helper samt altem PO-Token-Server bis zur nächsten Anmeldung.
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
    // gleiche Werte wie res/launchd/*.plist (Port)
    NSDictionary *want = @{
        @"Label": label,
        @"ProgramArguments": @[exe],
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

static void SFLaunchctl(NSArray *args) {
    NSTask *t = [NSTask new];
    t.launchPath = @"/bin/launchctl";
    t.arguments = args;
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
}

BOOL SFRuntimeMisplaced(void) {
    if (!SFRuntimeDir()) return NO;
    NSURL *u = [[NSBundle mainBundle] bundleURL];
    NSNumber *ro = nil;
    [u getResourceValue:&ro forKey:NSURLVolumeIsReadOnlyKey error:NULL];
    if (ro.boolValue) return YES;   // direkt aus der DMG gestartet
    NSString *p = u.path;
    if (![p hasSuffix:@".app"]) return YES;   // Sofa.app.staged/.prev: Zwischenstände eines Updates
    NSString *dir = [p stringByDeletingLastPathComponent];
    return !([dir isEqualToString:@"/Applications"] ||
             [dir isEqualToString:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]]);
}

void SFInstallAgents(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *labels = @[@"de.sofa.remote", @"de.sofa.app"];
    // MacPorts-Port installiert (gleiche Labels in /Library/LaunchAgents): der Port gewinnt, eigene
    // Benutzer-Agents weg -- sonst entschiede die Ladereihenfolge, welches Sofa läuft.
    if ([fm fileExistsAtPath:@"/Library/LaunchAgents/org.macports.sofa-remote.plist"]) {
        for (NSString *l in labels) {
            NSString *p = SFAgentPath(l);
            if (![fm fileExistsAtPath:p]) continue;
            SFLaunchctl(@[@"unload", p]);
            [fm removeItemAtPath:p error:nil];
            NSLog(@"Sofa: Benutzer-Agent %@ entfernt (MacPorts-Port aktiv)", l);
        }
        return;
    }
    if (!SFRuntimeDir() || SFRuntimeMisplaced()) return;
    NSString *app = [[NSBundle mainBundle] bundlePath];
    if (SFWriteAgent(@"de.sofa.remote", [app stringByAppendingPathComponent:@"Contents/MacOS/SofaRemote"], YES)) {
        NSString *p = SFAgentPath(@"de.sofa.remote");
        SFLaunchctl(@[@"unload", p]);   // alter Helper beendet sich samt PO-Token-Server (SIGTERM)
        SFLaunchctl(@[@"load", @"-w", p]);
        NSLog(@"Sofa: Fernbedienungs-Helper eingerichtet (%@, %@)", app, SFBuildID());
    }
    // Autostart: erst ab der nächsten Anmeldung aktiv (jetzt laden startete ein zweites Sofa)
    SFWriteAgent(@"de.sofa.app", [app stringByAppendingPathComponent:@"Contents/MacOS/Sofa"], NO);
}
