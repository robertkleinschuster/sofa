// Sofa's YouTube client (docs/youtube-engine.md): the engine runs inside a real Firefox on a real
// youtube.com page (SFYTBrowser) - the one identity every request to YouTube comes from (playback,
// lives, downloads, InnerTube, suggestions). Sofa talks to it over the extension's channel
// (SFYTChannel) and serves its media to mpv/ffmpeg as local Range-capable URLs from the same
// loopback server (SFYTEngine+Media). Replaced the node sidecar (docs/sofa-yt.md, retired 2026-11-07).
// Main thread API.
#import "SFCore.h"

// The engine's page went away (browser exit, page reload): every session and its URLs are dead.
extern NSString *const SFYTEngineSessionsLostNotification;

@interface SFYTEngine : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL available;   // Firefox, Xvfb and the extension are installed
- (void)start;                                     // idempotent; the real app starts early, dev instances on first use
- (void)stop;                                      // Sofa quits: browser and display end (blocking, a few seconds at most)
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
// Playback of session `sid` starts at `seconds` (the player's start point): the engine fetches from
// there at once, as youtube.com's player does, instead of after mpv's probe and seek. Fire and forget.
- (void)session:(NSString *)sid startsAt:(NSTimeInterval)seconds;
// The player's state on session `sid` ({state: playing|paused|buffering|ended|closed, position,
// lactMs}): the view's stats pings follow from it in the page (docs/youtube-engine.md "Playback
// reporting"). Fire and forget; nothing when the engine is not ready.
- (void)report:(NSString *)sid state:(NSDictionary *)state;
// Diagnostics of a session (lives: `ended`); nil when the engine does not answer in a few seconds.
- (void)sessionStatus:(NSString *)sid done:(void (^)(NSDictionary *status))done;
// Focus preload: the player response into the engine's cache, within a request budget and never
// during a bot-check pause. NO when nothing was sent.
- (BOOL)preloadOnFocus:(NSString *)videoID;
// InnerTube for the app (browse, next, search, navigation/resolve_url; never "player"): the raw JSON.
- (void)innertube:(NSString *)endpoint body:(NSDictionary *)body background:(BOOL)bg done:(void (^)(id json, NSError *e))done;
// What youtube.com's search box suggests for `prefix` (its raw answer).
- (void)suggest:(NSString *)prefix done:(void (^)(id json, NSError *e))done;
// Still online? The video's oEmbed answer, asked by the page (no player request): 1 online (public or
// unlisted), 0 gone (deleted, bad id), -1 unknown (401/403 also covers private videos; no answer).
- (void)availability:(NSString *)videoID done:(void (^)(NSInteger online))done;
// A YouTube picture (i.ytimg.com, yt3.ggpht.com, yt3.googleusercontent.com) loaded by the page as
// youtube.com loads it. status: the host's (404 = no such picture), 0 without an answer. Any queue.
- (void)image:(NSURL *)url done:(void (^)(NSData *data, NSInteger status))done;
@end

@interface SFYTEngine (MediaStore)   // SFYTEngine+Store.m
// A video complete in the media store opens without the engine (`stored` in the answer): canOpen
// says whether open can succeed at all (engine installed, or the video stored). Main queue.
- (BOOL)canOpen:(NSString *)videoID;
@end

@interface SFYTEngine (Lounge)
// The lounge's transport (SFLounge): its requests to www.youtube.com/api/lounge made by the
// engine page - same origin, the profile's cookies, as youtube.com/tv makes them. Any queue;
// status 0 = no answer.
- (void)loungeRequest:(NSString *)method url:(NSString *)url body:(NSString *)body done:(void (^)(NSData *data, NSInteger status))done;
// The bind channel's long poll: its bytes in order, then done once - the status of a poll that
// ended normally, 0 when it was cut off or not answered. Any queue.
- (void)loungePoll:(NSString *)url data:(void (^)(NSData *chunk))onData done:(void (^)(NSInteger status))done;
@end
