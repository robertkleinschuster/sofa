// YouTube's bot check, seen from Sofa: one shared circuit breaker.
// YouTube answers player requests from a flagged IP with "Sign in to confirm you're not a bot";
// every further request while flagged prolongs the flag. The YouTube engine decides the pause
// ({until, backoff}, 1 h doubling to 8 h, reset by the first success) and reports each change;
// Sofa keeps it in one file (Caches/Sofa/youtube-block.json) that every instance reads: background work (follow checks, preloads, downloads)
// waits, playback the user starts still tries once (the flag is often intermittent).
#import "SFCore.h"

@interface SFYTBreaker : NSObject
+ (instancetype)shared;
// > now: background requests are paused until then; 0 = no pause
@property (nonatomic, readonly) NSTimeInterval blockedUntil;
// a pause reported in an answer (engine error): taken over until the file says more
- (void)noteBlockedUntil:(NSTimeInterval)until;
// the engine's breaker changed ({until, backoff}): written to the shared file
- (void)recordState:(NSDictionary *)state;
- (void)simulateBlockForTesting:(NSTimeInterval)secs;   // dev command ytblock: in memory only
+ (NSString *)filePath;
@end
