// The on-screen keyboard's keys (SFKeyboardScreen): four rows of letters/digits in the chosen
// layout and a row of wide special keys, placed on a 10-column grid (col, span).
#import "SFLayers.h"

typedef NS_ENUM(NSInteger, SFKbKind) { SFKbChar, SFKbSpace, SFKbDelete, SFKbSubmit, SFKbLayout };

@interface SFKbKey : NSObject
@property (nonatomic) SFKbKind kind;
@property (nonatomic, copy) NSString *label;
@property (nonatomic) NSInteger col, span;
@property (nonatomic, strong) CALayer *bg;
@property (nonatomic, strong) SFLabel *text;
+ (NSArray *)rowsQwertz:(BOOL)qwertz submitTitle:(NSString *)submit;   // NSArray of SFKbKey per row
@end
