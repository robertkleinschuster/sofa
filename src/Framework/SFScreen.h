// Screen base class and navigator (stack, transitions, input dispatch).
#import "SFCore.h"
#import "SFTheme.h"

@class SFNavigator;

@interface SFScreen : NSObject
@property (nonatomic, strong, readonly) CALayer *layer;   // root (screen size)
@property (nonatomic, weak) SFNavigator *navigator;
@property (nonatomic, strong) SFTheme *theme;
@property (nonatomic, readonly) CGSize size;
@property (nonatomic, copy) NSString *restoreKey;     // e.g. "app:zdf" (restore after an update)
- (instancetype)initWithTheme:(SFTheme *)theme;
- (void)layoutForSize:(CGSize)size;   // once before appearing + on size changes
- (void)willAppear;
- (void)didAppear;
- (void)willDisappear;
- (BOOL)handleKey:(SFKey)key;         // NO = navigator takes over (Menu = back)
- (BOOL)wantsCursorHidden;
- (BOOL)isOpaque;                     // NO = the screen below stays visible (dialogs)
- (CGFloat)toastCenterFromBottom;     // position of the toast (player: above the timeline/OSD)
// Entrance and exit (navigator push/pop): the start state, set without animation, then the end
// state, set inside the navigator's animation. Default: a fade with a slight zoom; a side panel
// slides in instead (SFMenuScreen).
- (void)prepareEntrance;
- (void)enter;
- (void)exit;
@end

@interface SFNavigator : NSView
+ (SFNavigator *)main;   // the window's navigator (the first one created) - for actions without a screen at hand
@property (nonatomic, readonly) NSArray *stack;
@property (nonatomic, readonly) SFScreen *top;
- (void)push:(SFScreen *)s;
- (void)pop;
- (void)popToRoot;
- (void)replaceTop:(SFScreen *)s;
// Remove a screen from anywhere in the stack for good, without animation (it gets willDisappear,
// also when it was covered). Used for overlays whose base went away (player info panel after the
// player closed) and for a player left behind under a covered overlay.
- (void)removeScreen:(SFScreen *)s;
// Remove every screen above s (overlays such as menus or the player info panel), s becomes top.
- (void)popAbove:(SFScreen *)s;
- (void)sendKey:(SFKey)key;
@property (nonatomic, readonly) NSTimeInterval lastInput;   // time of the last key press (updater: swap only when idle)
// Short toast at the bottom (hints, errors)
- (void)toast:(NSString *)text;
// Change the volume (dir ±1) and show the indicator
- (void)volumeStep:(int)dir;
// MENU on the bottom screen (Home): power menu instead of nothing
@property (nonatomic, copy) dispatch_block_t rootMenuHandler;
@end

NSCursor *SFBlankCursor(void);   // transparent mouse cursor (TV UI)
