// ARD Mediathek (api.ardmediathek.de/page-gateway, ohne Auth): Startseite, Rubriken,
// Sendungen A–Z, Sendungsseiten, Live. Siehe docs/mediathek-apis.md §2.
#import "SFModel.h"

@interface SFProviderARD : NSObject
+ (void)registerResolver;
+ (SFPageLoader)homeLoader;
+ (SFPageLoader)searchLoader:(NSString *)q;
@end
