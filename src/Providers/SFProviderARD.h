// ARD Mediathek (api.ardmediathek.de/page-gateway, no auth): home page, categories,
// shows A-Z, show pages, live. See docs/mediathek-apis.md §2.
#import "SFModel.h"

@interface SFProviderARD : NSObject
+ (void)registerResolver;
+ (SFPageLoader)homeLoader;
+ (SFPageLoader)searchLoader:(NSString *)q;
@end
