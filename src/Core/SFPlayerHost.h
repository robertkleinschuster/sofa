// What the shell offers apps that act outside a page: a phone remote starting videos, dev
// commands opening screens. Implemented by the app delegate (src/Shell).
#import "SFScreen.h"
@class SFPlayerScreen;

@protocol SFPlayerHost <NSObject>
- (SFNavigator *)nav;
- (SFPlayerScreen *)topPlayer;                 // visible player (also below overlays), nil = none
- (void)presentPlayer:(SFPlayerScreen *)ps;    // replaces the visible player (and overlays above it) or pushes
- (void)wakeAndFront;                          // wake the display, bring Sofa to the front
@end
