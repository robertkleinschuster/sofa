// Automatic updates from GitHub releases (release bundle only, see SFRuntime).
//
// Flow: ask the GitHub API -> newer version? -> download Sofa-<v>.dmg + .sha256, verify ->
// copy the bundle from the DMG to <App>.update and verify -> as soon as Sofa is idle (no playback,
// no key for 15 min) rename to <App>.staged. The helper (SofaRemote) does the swap as with
// every update: Sofa saves state, swap, relaunch, resume.
#import <Foundation/Foundation.h>

@class SFNavigator;

@interface SFUpdater : NSObject
+ (instancetype)shared;
// Automatic mode (5 min after launch, then every 6 h) when "Automatisch aktualisieren" is on:
// check, download, verify, install as soon as Sofa is idle.
- (void)startWithNavigator:(SFNavigator *)nav;
// Check only (settings): afterwards latestVersion/updateAvailable; message = result for display.
- (void)check:(void (^)(NSString *message))done;
// Download the found update, verify and install it right away (Sofa saves state, relaunches).
- (void)install:(void (^)(NSString *message))progress;
@property (nonatomic, readonly) BOOL available;          // updates possible (release bundle, folder writable)
@property (nonatomic, readonly) NSString *installedVersion;
@property (nonatomic, readonly) NSString *latestVersion; // nil = not checked yet
@property (nonatomic, readonly) BOOL updateAvailable;    // latestVersion > installedVersion
@property (nonatomic, readonly) NSDate *lastCheck;
@property (nonatomic, readonly) NSString *releaseNotes;   // text of the GitHub release (Markdown)
@property (nonatomic, readonly) BOOL busy;
@end
