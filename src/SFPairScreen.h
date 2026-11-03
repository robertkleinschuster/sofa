// "Mit Handy verbinden": zeigt den TV-Code für die YouTube-App (Lounge), erneuert ihn
// alle 4 min und listet verbundene Handys. Menu = zurück.
#import "SFScreen.h"

@interface SFPairScreen : SFScreen
+ (void)showConnectionMenuOn:(SFNavigator *)nav;   // Handy-Einstellungen (pausieren, teilen, verbinden, trennen)
@end
