// Suche je App: Kachel „Suche“ auf der Startseite -> Bildschirmtastatur (Vorschläge,
// zuletzt gesucht) -> Ergebnisseite des Providers (+searchLoader:).
#import "SFModel.h"
#import "SFScreen.h"

// Startseiten-Loader um die Kachel „Suche“ ergänzen: vorne in „Mehr“ / „Entdecken“ /
// „Kategorien“, sonst als eigene kleine Reihe weit oben.
SFPageLoader SFWithSearchTile(SFPageLoader loader, NSString *source);
SFItem *SFSearchTile(NSString *source);
BOOL SFHasSearch(NSString *source);   // hat diese App eine Suche?
void SFOpenSearch(SFNavigator *nav, NSString *source, NSString *initialText);
// Zuletzt gesucht (SFStore-Einstellung "search.recent.<source>"), neueste zuerst.
NSArray *SFRecentSearches(NSString *source);
void SFAddRecentSearch(NSString *source, NSString *query);
