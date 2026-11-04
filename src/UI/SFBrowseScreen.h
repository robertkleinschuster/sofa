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
@property (nonatomic, copy) NSString *folderIdentifier;    // Kennung des geöffneten Ordners (z. B. „zdfshow:…“)
@property (nonatomic, copy) NSString *searchSource;        // Kopfzeile: Knopf „Suche“ (Hoch aus der ersten Reihe)
// Overlay mode (player info panel): not opaque (the screen below keeps running and stays visible,
// dimmed by a translucent dark background), no logo/title/search in the header (clock and key hint
// stay), no backdrop image, hero starts higher. Set before the screen is pushed.
@property (nonatomic) BOOL overlay;
@property (nonatomic) NSInteger heroPlotLines;             // max. description lines in the hero (default 3)
- (instancetype)initWithLoader:(SFPageLoader)loader theme:(SFTheme *)theme;
- (instancetype)initWithPage:(SFPage *)page;
- (void)reload;
- (void)setPage:(SFPage *)page keepFocus:(BOOL)keep;
- (SFItem *)focusedItem;
// Swap the items of one shelf of the current page in place (same count: only that row's tiles are
// rebuilt, focus stays; otherwise the page is rebuilt keeping the focus). Labels of action buttons
// update without the other rows flickering.
- (void)replaceItemsOfShelf:(SFShelf *)shelf with:(NSArray *)items;
// Unterklassen/Hooks
@property (nonatomic, copy) void (^onSelect)(SFItem *item, NSArray *shelfItems, NSUInteger index);
@end

// Standard-Aktion für ein Item (abspielen / öffnen / Aktion).
void SFOpenItem(SFNavigator *nav, SFItem *item, NSArray *queue, NSUInteger index);
// Screen for a folder item (show, channel, category) as SFOpenItem pushes it
SFBrowseScreen *SFBrowseScreenForFolder(SFItem *folder, SFTheme *fallback);

// Show/channel of an episode: "Zum Kanal „X“" / "Zur Sendung „X“" / "Zu „X“" (downloaded show).
// One rule set for the context menu and the player info panel.
@interface SFShowLink : NSObject
@property (nonatomic, copy, readonly) NSString *title;      // label for a menu entry or button
@property (nonatomic, strong, readonly) SFItem *folder;     // followable folder (showRef known), else nil
// nil when there is nothing to link to. here = identifier of the open folder page (no link to itself),
// pageTitle = title of the open page (no link to the downloaded show one is already looking at).
+ (instancetype)linkFor:(SFItem *)episode here:(NSString *)here pageTitle:(NSString *)pageTitle;
// Opens the page (looking the channel up first if needed). stillValid is asked after an async
// lookup: NO = the user has moved on, do nothing. present pushes the screen (default: push).
- (void)openOn:(SFNavigator *)nav stillValid:(BOOL (^)(void))stillValid present:(void (^)(SFScreen *screen))present;
@end
