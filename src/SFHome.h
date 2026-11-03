// Home-Screen (App-Kacheln, Weiterschauen, Neue Folgen) und die Startseiten
// der Quellen-Apps.
#import "SFBrowseScreen.h"

@interface SFHome : NSObject
+ (SFScreen *)homeScreen;
+ (SFScreen *)appScreen:(NSString *)source;                  // youtube, zdf, ard, orf, ccc
+ (SFPageLoader)showLoader:(NSString *)showName;               // lokale Sendung
+ (SFPageLoader)showLoader:(NSString *)showName source:(NSString *)source;
+ (SFPageLoader)downloadsLoader:(NSString *)source;           // nil = alle Quellen
+ (SFItem *)downloadsTile:(NSString *)source;                  // öffnet die Downloads-Seite
@end
