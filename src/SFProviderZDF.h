// ZDF Mediathek (GraphQL api.zdf.de + PTMD, Token täglich): Startseite, Sendungen,
// Staffeln, Kategorien, Live. Siehe docs/mediathek-apis.md §1.
#import "SFModel.h"

@interface SFProviderZDF : NSObject
+ (void)registerResolver;
+ (SFPageLoader)homeLoader;
@end
