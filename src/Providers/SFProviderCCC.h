// media.ccc.de (api.media.ccc.de/public): Neu, Beliebt, Konferenzen, Vorträge.
#import "SFModel.h"

@interface SFProviderCCC : NSObject
+ (void)registerResolver;
+ (SFPageLoader)homeLoader;
+ (SFPageLoader)searchLoader:(NSString *)q;
@end
