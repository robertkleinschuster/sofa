// ZDF Mediathek (GraphQL api.zdf.de + PTMD, daily token): home page, shows,
// seasons, categories, live. See docs/mediathek-apis.md §1.
#import "SFApp.h"

@interface SFZDFApp : NSObject <SFApp>
+ (SFPageLoader)categoryLoader:(NSString *)collectionId title:(NSString *)title;   // category/brand page (ID or canonical)
@end
