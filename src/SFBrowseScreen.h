// Universeller Browse-Screen: Header (Schriftzug, Titel, Uhr), Hintergrund und
// beliebige Shelves (Reihen/Raster) aus einer SFPage, Fokus-Navigation mit
// virtualisierten Kacheln.
#import "SFScreen.h"
#import "SFModel.h"

@interface SFBrowseScreen : SFScreen
@property (nonatomic, strong, readonly) SFPage *page;
@property (nonatomic, copy) SFPageLoader loader;         // zum Laden/Neuladen
@property (nonatomic) BOOL showsHero;                     // großes Info-Feld zum fokussierten Item
@property (nonatomic, copy) NSString *reloadNotification;  // bei dieser Notification neu laden
- (instancetype)initWithLoader:(SFPageLoader)loader theme:(SFTheme *)theme;
- (instancetype)initWithPage:(SFPage *)page;
- (void)reload;
- (void)setPage:(SFPage *)page keepFocus:(BOOL)keep;
- (SFItem *)focusedItem;
// Unterklassen/Hooks
@property (nonatomic, copy) void (^onSelect)(SFItem *item, NSArray *shelfItems, NSUInteger index);
@end

// Standard-Aktion für ein Item (abspielen / öffnen / Aktion).
void SFOpenItem(SFNavigator *nav, SFItem *item, NSArray *queue, NSUInteger index);
