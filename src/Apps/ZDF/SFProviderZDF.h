// ZDF Mediathek (GraphQL api.zdf.de + PTMD, daily token): home page, shows,
// seasons, categories, live. See docs/mediathek-apis.md §1.
#import "SFModel.h"

@interface SFProviderZDF : NSObject
+ (void)registerResolver;
+ (SFPageLoader)homeLoader;
+ (SFPageLoader)searchLoader:(NSString *)q;
+ (SFPageLoader)categoryLoader:(NSString *)collectionId title:(NSString *)title;   // category/brand page (ID or canonical)
@end
