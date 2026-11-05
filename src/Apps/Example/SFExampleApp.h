// Example app: the smallest complete SFApp, the executable reference for docs/new-app.md.
// Registered in dev instances only (src/Shell/SFApps.m). Offline: its videos are mpv test
// patterns (lavfi), its catalogue is static.
#import "SFApp.h"

@interface SFExampleApp : NSObject <SFApp>
@end
