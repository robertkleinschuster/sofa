// Per-reader byte limit shared by all loopback connections (audio/video, HLS, retries).
#import <Foundation/Foundation.h>
@interface SFHTTPBudget : NSObject
+ (NSString *)open:(NSUInteger)bytes;
+ (BOOL)take:(NSUInteger)bytes token:(NSString *)token; // nil = ordinary playback, no limit
// Separate upstream budget (twice the response cap); cached reads do not spend it.
+ (BOOL)takeSource:(NSUInteger)bytes token:(NSString *)token;
+ (NSUInteger)remaining:(NSString *)token;
+ (void)close:(NSString *)token; // revoked/unknown tokens reject further reads
@end
