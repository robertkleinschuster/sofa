// ORF ON (api-tvthek.orf.at/api/v4.3, static app key; approved by the user for
// home use 2026-11-03): home page (lanes), categories, A-Z, live.
// See docs/mediathek-apis.md §3. DRM content (ORF 1/2 live) can't be played on 10.9
// and is marked.
#import "SFModel.h"

@interface SFProviderORF : NSObject
+ (void)registerResolver;
+ (SFPageLoader)homeLoader;
+ (SFPageLoader)searchLoader:(NSString *)q;
@end
