// The yt-dlp FALLBACK for YouTube (docs/youtube.md): asked only when the sofa-yt sidecar (SFYTSabr)
// could not serve a video. res/ytresolver.py with yt-dlp as a signature-verified zipapp (bundle or
// ~/Library/Application Support/Sofa/yt-dlp), JSON lines over pipes. The process starts with the
// first request and ends after 10 min without one. Result cache until shortly before the URLs
// expire (6 h, IP-bound). PO tokens come from the sidecar (Sofa's yt-dlp plugin).
#import "SFCore.h"

@interface SFYTResolver : NSObject
+ (instancetype)shared;
- (void)saveCache;             // before an update restart: save results for the new process
- (void)start;                 // app start: housekeeping + yt-dlp update schedule (no process yet)
// r: url, alt (Array), height, live, duration, title, dash
- (void)resolve:(NSString *)videoID live:(BOOL)live done:(void (^)(NSDictionary *r, NSError *e))done;
// background (downloads): own resolver pool, never blocks playback; nothing sent during a bot-check pause
- (void)prefetch:(NSString *)videoID done:(void (^)(NSDictionary *r, NSError *e))done;
- (void)forget:(NSString *)videoID;   // drop the result (streams rejected) -> the next call resolves afresh
@end
