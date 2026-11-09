// Predictive readers use the same persistent store-backed URLs as playback and downloads.
#import "SFModel.h"
@interface SFPrebuffer : NSObject
+ (instancetype)shared;
- (void)offer:(NSArray *)suggestions focused:(SFItem *)focused owner:(id)owner;
- (void)suspendForPlayer:(id)player;
- (void)leave:(id)owner;
@end
