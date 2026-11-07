// Locate runtime tools and data (ffmpeg, rsvg-convert, the YouTube engine's Firefox and Xvfb).
//
// Release bundle (tools/make-release): everything lives in Sofa.app/Contents/Runtime
// (bin/, etc/; libraries in Contents/Frameworks), the libraries are relinked
// @loader_path-relative -> Sofa needs no MacPorts. Development/port build without a Runtime folder:
// tools from the MacPorts prefix.
#import <Foundation/Foundation.h>

NSString *SFRuntimeDir(void);              // .../Contents/Runtime or nil (port/dev)
NSString *SFTool(NSString *name);          // Runtime/bin/<name> or /opt/local/bin/<name>
NSString *SFRuntimePath(NSString *rel);    // Runtime/<rel> or /opt/local/<rel> (lib/firefox, share/X11/xkb, ...)
NSString *SFCABundle(void);                // CA certificates for libcurl (nil = libcurl default)
// Release bundle: set up ~/Library/LaunchAgents/de.sofa.{remote,app}.plist for this bundle
// (load the remote helper right away, autostart from the next login).
// Not if the MacPorts port installed its agents. Only call from the real app.
void SFInstallAgents(void);
// Release bundle not running from /Applications or ~/Applications (e.g. straight from the DMG):
// then don't set up agents, but ask the user to drag Sofa into /Applications.
BOOL SFRuntimeMisplaced(void);
// Once, early in main(): PATH, SSL_CERT_FILE, FONTCONFIG_* for child processes.
void SFRuntimeSetup(void);

// Run a tool synchronously and return its exit status (-1 = could not launch, -2 = timed out and
// killed). Never use -[NSTask waitUntilExit] instead: on 10.9 it spins a run loop and can hang
// forever on a GCD thread although the child has exited (2026-11-04). Waits via terminationHandler +
// semaphore; after `timeout` seconds SIGTERM, 2 s later SIGKILL. DYLD_INSERT_LIBRARIES is removed
// from the child environment. *output (optional) = stdout (+ stderr when mergeStderr).
int SFRunProcess(NSString *path, NSArray *args, NSTimeInterval timeout, BOOL mergeStderr, NSData **output);
