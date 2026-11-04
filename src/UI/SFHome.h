// Home screen (app tiles, continue watching, new episodes) and the start pages
// of the source apps.
#import "SFBrowseScreen.h"

@interface SFHome : NSObject
+ (SFScreen *)homeScreen;
+ (SFScreen *)appScreen:(NSString *)source;                  // youtube, zdf, ard, orf, ccc
+ (SFPageLoader)showLoader:(NSString *)showName source:(NSString *)source;   // local show
+ (SFItem *)historyTile;                                       // opens the history
@end

// Downloads page – SFHome+Downloads.m
@interface SFHome (Downloads)
+ (SFPageLoader)downloadsLoader:(NSString *)source;           // nil = all sources
+ (SFItem *)downloadsTile:(NSString *)source;                  // opens the downloads page
@end

// Settings and phone – SFHome+Settings.m
@interface SFHome (Settings)
+ (SFItem *)settingsTile;                                      // Home tile "Einstellungen"
+ (SFItem *)phoneTile;                                         // phone status + settings (YouTube → Mehr)
+ (void)showSettingsOn:(SFNavigator *)nav;                     // "Start & Fernbedienung"
@end
