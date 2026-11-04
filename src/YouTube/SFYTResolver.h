// YouTube stream resolution via a long-lived yt-dlp process (res/ytresolver.py, yt-dlp as a
// signature-verified zipapp: bundle or ~/Library/Application Support/Sofa/yt-dlp). JSON lines over pipes,
// restart on crash, result cache until shortly before the URLs expire (6 h, IP-bound).
#import "SFCore.h"

@interface SFYTResolver : NSObject
+ (instancetype)shared;
- (void)saveCache;             // before an update restart: save results for the new process
- (void)start;                 // idempotent; pre-warms the player JS cache
- (void)restart;
// r: url, alt (Array), height, live, duration, title
- (void)resolve:(NSString *)videoID live:(BOOL)live done:(void (^)(NSDictionary *r, NSError *e))done;
// background (preload on focus, downloads): own resolver pool, never blocks playback
- (void)prefetch:(NSString *)videoID done:(void (^)(NSDictionary *r, NSError *e))done;
- (void)forget:(NSString *)videoID;   // drop the result (streams rejected) -> the next call resolves afresh
@end
