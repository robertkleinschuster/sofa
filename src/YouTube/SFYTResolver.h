// YouTube stream resolution via a long-lived yt-dlp process (res/ytresolver.py, yt-dlp as a
// signature-verified zipapp: bundle or ~/Library/Application Support/Sofa/yt-dlp). JSON lines over pipes,
// restart on crash, result cache until shortly before the URLs expire (6 h, IP-bound).
#import "SFCore.h"

extern NSString *const SFYTBlockDidChangeNotification;   // the bot-check pause began or ended

@interface SFYTResolver : NSObject
+ (instancetype)shared;
- (void)saveCache;             // before an update restart: save results for the new process
- (void)start;                 // idempotent; pre-warms the player JS cache
- (void)restart;
// r: url, alt (Array), height, live, duration, title
- (void)resolve:(NSString *)videoID live:(BOOL)live done:(void (^)(NSDictionary *r, NSError *e))done;
// background (preload on focus, downloads): own resolver pool, never blocks playback
- (void)prefetch:(NSString *)videoID done:(void (^)(NSDictionary *r, NSError *e))done;
- (void)forget:(NSString *)videoID;
// Preload on focus: like prefetch, but within a request budget and never while YouTube's bot check
// pauses background requests. Returns NO if nothing was sent.
- (BOOL)preloadOnFocus:(NSString *)videoID;
// > now: YouTube answered with a bot check, background requests are paused until then (the
// resolver's circuit breaker, persisted across restarts). 0 = no pause.
@property (nonatomic, readonly) NSTimeInterval blockedUntil;
- (void)simulateBlockForTesting:(NSTimeInterval)secs;
- (void)noteBlockedUntil:(NSTimeInterval)until;   // pause reported by the SABR sidecar (same breaker)   // dev command ytblock: in memory only   // drop the result (streams rejected) -> the next call resolves afresh
@end
