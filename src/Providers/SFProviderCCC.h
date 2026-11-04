// media.ccc.de (api.media.ccc.de/public): new, popular, conferences, talks.
#import "SFModel.h"

@interface SFProviderCCC : NSObject
+ (void)registerResolver;
+ (SFPageLoader)homeLoader;
+ (SFPageLoader)searchLoader:(NSString *)q;
@end
