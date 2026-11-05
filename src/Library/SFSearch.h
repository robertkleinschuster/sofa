// Search per app: tile "Suche" on the start page -> on-screen keyboard (suggestions,
// recent searches) -> the provider's result page (+searchLoader:).
#import "SFModel.h"
#import "SFScreen.h"

// Add the tile "Suche" to a start page loader: in front of "Mehr" / "Entdecken" /
// "Kategorien", otherwise as its own small row near the top.
SFPageLoader SFWithSearchTile(SFPageLoader loader, NSString *source);
SFItem *SFSearchTile(NSString *source);
BOOL SFHasSearch(NSString *source);   // does this app have a search?
void SFOpenSearch(SFNavigator *nav, NSString *source, NSString *initialText);
// Recent searches (table recent_searches), newest first.
NSArray *SFRecentSearches(NSString *source);
void SFAddRecentSearch(NSString *source, NSString *query);
