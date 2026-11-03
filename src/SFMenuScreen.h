// Seitliches Overlay-Menü (Kontextmenü, Auswahl-Dialoge). Nicht deckend.
#import "SFScreen.h"

@interface SFMenuOption : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;     // rechts, gedimmt (z.B. aktueller Wert)
@property (nonatomic, copy) dispatch_block_t action;
@property (nonatomic) BOOL keepOpen;              // Menü nach Auswahl nicht schließen
+ (instancetype)option:(NSString *)title action:(dispatch_block_t)action;
@end

@interface SFMenuScreen : SFScreen
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle
                      options:(NSArray *)options theme:(SFTheme *)theme;
@end
