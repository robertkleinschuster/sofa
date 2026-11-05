// Side overlay menu (context menu, choice dialogs). Not opaque.
#import "SFScreen.h"

@interface SFMenuOption : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;     // on the right, dimmed (e.g. current value)
@property (nonatomic, copy) dispatch_block_t action;
@property (nonatomic) BOOL keepOpen;              // do not close the menu after a choice
+ (instancetype)option:(NSString *)title action:(dispatch_block_t)action;
@end

@interface SFMenuScreen : SFScreen
@property (nonatomic) NSInteger initialSelection;   // row selected on open (rebuild at the same position)
@property (nonatomic, readonly) NSInteger selectedIndex;
@property (nonatomic) NSInteger subtitleLines;   // default 2 (e.g. welcome with key overview: more)
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle
                      options:(NSArray *)options theme:(SFTheme *)theme;
@end
