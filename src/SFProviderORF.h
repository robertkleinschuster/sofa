// ORF ON (api-tvthek.orf.at/api/v4.3, statischer App-Schlüssel; vom User für
// Home-Use freigegeben 2026-11-03): Startseite (Lanes), Kategorien, A–Z, Live.
// Siehe docs/mediathek-apis.md §3. DRM-Inhalte (ORF 1/2 live) sind auf 10.9 nicht
// abspielbar und werden gekennzeichnet.
#import "SFModel.h"

@interface SFProviderORF : NSObject
+ (void)registerResolver;
+ (SFPageLoader)homeLoader;
+ (SFPageLoader)searchLoader:(NSString *)q;
@end
