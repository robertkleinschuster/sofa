// Home screen (app tiles, continue watching, new episodes) and the start pages
// of the source apps.
#import "SFBrowseScreen.h"

@interface SFHome : NSObject
+ (SFScreen *)homeScreen;
+ (SFScreen *)appScreen:(NSString *)source;                  // youtube, zdf, ard, orf, ccc
@end

// Settings – SFHome+Settings.m
@interface SFHome (Settings)
+ (SFItem *)settingsTile;                                      // Home tile "Einstellungen"
+ (void)showSettingsOn:(SFNavigator *)nav;                     // "Start & Fernbedienung"
@end
