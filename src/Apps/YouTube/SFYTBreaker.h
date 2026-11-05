// YouTube's bot check, seen from Sofa: one shared circuit breaker for both YouTube paths.
// YouTube answers player requests from a flagged IP with "Sign in to confirm you're not a bot";
// every further request while flagged prolongs the flag. Whoever sees a bot check (the sofa-yt
// sidecar or the yt-dlp fallback) writes the pause into one file (Caches/Sofa/yt-dlp/
// youtube-block.json: {until, backoff}, 5 min doubling to 1 h, reset by the first success), and
// everyone reads it: background work (preloads, downloads) waits, playback the user starts still
// tries once (the flag is often intermittent) and never falls back to the other path.
#import "SFCore.h"

@interface SFYTBreaker : NSObject
+ (instancetype)shared;
// > now: background requests are paused until then; 0 = no pause
@property (nonatomic, readonly) NSTimeInterval blockedUntil;
// a pause reported in an answer (sidecar error, resolver result): taken over until the file says more
- (void)noteBlockedUntil:(NSTimeInterval)until;
- (void)simulateBlockForTesting:(NSTimeInterval)secs;   // dev command ytblock: in memory only
+ (NSString *)filePath;
@end
