// Sofa's YouTube client (docs/youtube-engine.md): the engine runs inside a real Firefox on a real
// youtube.com page (SFYTBrowser) - the one identity every request to YouTube comes from (playback,
// lives, downloads, InnerTube, suggestions). Sofa talks to it over the extension's channel
// (SFYTChannel) and serves its media to mpv/ffmpeg as local Range-capable URLs from the same
// loopback server (SFYTEngine+Media). Replaces the node sidecar (docs/sofa-yt.md).
// Main thread API.
#import "SFCore.h"

// The engine's page went away (browser exit, page reload): every session and its URLs are dead.
extern NSString *const SFYTEngineSessionsLostNotification;

@interface SFYTEngine : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL available;   // Firefox, Xvfb and the extension are installed
- (void)start;                                     // idempotent; the real app starts early, dev instances on first use
// The chosen tracks (video, audio, height, fps, vcodec, acodec, alang, audios, subs) plus id, sid,
// title, duration, published, endscreen; all URLs local. Lives and post-live DVR recordings carry
// `hls` (a local HLS playlist) and `live` instead of video/audio.
// Error userInfo: @"bot" = YouTube answered with a bot check; @"unanswered" = no answer at all;
// @"live" for streams that can't be played (@"upcoming" + @"startTime" epoch or 0; offline:
// message "offline").
- (void)open:(NSString *)videoID background:(BOOL)bg done:(void (^)(NSDictionary *r, NSError *e))done;
// Download: the same choice as playback, no prefetch; the session lives while ffmpeg reads.
- (void)openForDownload:(NSString *)videoID done:(void (^)(NSDictionary *r, NSError *e))done;
- (void)closeSession:(NSString *)sid;   // a retry then opens a fresh session
// Diagnostics of a session (lives: `ended`); nil when the engine does not answer in a few seconds.
- (void)sessionStatus:(NSString *)sid done:(void (^)(NSDictionary *status))done;
// Focus preload: the player response into the engine's cache, within a request budget and never
// during a bot-check pause. NO when nothing was sent.
- (BOOL)preloadOnFocus:(NSString *)videoID;
// InnerTube for the app (browse, next, search, navigation/resolve_url; never "player"): the raw JSON.
- (void)innertube:(NSString *)endpoint body:(NSDictionary *)body background:(BOOL)bg done:(void (^)(id json, NSError *e))done;
// What youtube.com's search box suggests for `prefix` (its raw answer).
- (void)suggest:(NSString *)prefix done:(void (^)(id json, NSError *e))done;
@end
