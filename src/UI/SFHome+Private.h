// SFHome – private part: shared helpers for SFHome.m (Home, history, app start pages),
// SFHome+Downloads.m (downloads page) and SFHome+Settings.m (settings, phone tile).
#import "SFHome.h"
#import "SFLibrary.h"

@interface SFHome ()
+ (SFItem *)showTile:(SFShow *)sh;   // tile of a local show (opens showLoader:source:)
@end
