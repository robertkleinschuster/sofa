// Predict startup buffers from already loaded suggestions and local usage; no provider requests.
#import "SFModel.h"
@interface SFPrebufferPlan : NSObject
// History entries: {item: SFItem, updated: epoch, watched: BOOL, pos: seconds}.
// Return at most three {item, position} candidates, deduplicated by source identity.
+ (NSArray *)candidates:(NSArray *)suggestions focused:(SFItem *)focused history:(NSArray *)history now:(NSTimeInterval)now;
@end
