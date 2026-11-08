// SFQuickMenu - Sofa's one menu for everything around the content (user 2026-11-08): back to the
// Home screen, the sound output (speakers, headphones), power (screen off, sleep timer, sleep) and
// the settings. Opens with MENU on the Home screen and with MENU held anywhere - also over a
// running video, which keeps playing under it.
#import "SFScreen.h"

@interface SFQuickMenu : NSObject
+ (void)showOn:(SFNavigator *)nav;
@end
