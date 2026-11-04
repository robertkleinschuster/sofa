// Home-Screen (App-Kacheln, Weiterschauen, Neue Folgen) und die Startseiten
// der Quellen-Apps.
#import "SFBrowseScreen.h"

@interface SFHome : NSObject
+ (SFScreen *)homeScreen;
+ (SFScreen *)appScreen:(NSString *)source;                  // youtube, zdf, ard, orf, ccc
+ (SFPageLoader)showLoader:(NSString *)showName source:(NSString *)source;   // lokale Sendung
+ (SFItem *)historyTile;                                       // öffnet den Verlauf
@end

// Downloads-Seite – SFHome+Downloads.m
@interface SFHome (Downloads)
+ (SFPageLoader)downloadsLoader:(NSString *)source;           // nil = alle Quellen
+ (SFItem *)downloadsTile:(NSString *)source;                  // öffnet die Downloads-Seite
@end

// Einstellungen und Handy – SFHome+Settings.m
@interface SFHome (Settings)
+ (SFItem *)settingsTile;                                      // Home-Kachel „Einstellungen“
+ (SFItem *)phoneTile;                                         // Handy-Status + Einstellungen (YouTube → Mehr)
+ (void)showSettingsOn:(SFNavigator *)nav;                     // Start & Fernbedienung
@end
