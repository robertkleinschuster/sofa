// "Mit Handy verbinden": shows the TV code for the YouTube app (Lounge), renews it
// every 4 min and lists connected phones. Menu = back.
#import "SFScreen.h"

@interface SFPairScreen : SFScreen
+ (void)showConnectionMenuOn:(SFNavigator *)nav;   // phone settings (pause, share, connect, disconnect)
@end
