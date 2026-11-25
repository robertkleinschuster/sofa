// Home screen (app tiles, continue watching, new episodes) and the start pages
// of the source apps.
#import "SFBrowseScreen.h"

@interface SFHome : NSObject
+ (SFScreen *)homeScreen;
+ (SFScreen *)appScreen:(NSString *)source;                  // youtube, zdf, ard, orf, ccc
// The pages behind them, shared with Sofa im Browser (docs/pwa.md): the same composition everywhere
+ (SFPageLoader)homeLoader;
+ (SFPageLoader)appLoader:(NSString *)source;                // nil for an unknown app
@end

// Settings – SFHome+Settings.m
@interface SFHome (Settings)
+ (SFItem *)settingsTile;                                      // Home tile "Einstellungen"
+ (void)showSettingsOn:(SFNavigator *)nav;                     // "Start & Fernbedienung"
@end
