// YouTube via SABR: supervises the sofa-yt node sidecar (res/sofa-yt, docs/sofa-yt.md) and asks it
// to open videos. The sidecar looks like YouTube's own web player (one persistent session, WEB
// player request with a video-bound PO token, SABR streaming) and serves the chosen video/audio
// tracks as local Range-capable URLs for mpv; lives as a local HLS playlist (the web player
// response's manifest, deciphered and kept fresh by the sidecar). It is Sofa's one YouTube identity:
// it also mints the PO tokens for the yt-dlp fallback (SFYTResolver). Concept: docs/youtube.md.
#import "SFCore.h"

extern NSString *const SFYTSabrDidExitNotification;   // the sidecar process ended (its URLs are dead)

@interface SFYTSabr : NSObject
+ (instancetype)shared;
- (void)start;   // idempotent; the real app starts it early, dev instances on first use
// result: the dash dict of ytresolver.py (video, audio, height, fps, vcodec, acodec, alang,
// audios, subs) plus id, sid, title, duration; all URLs local. Lives and post-live DVR recordings
// instead carry `hls` (a local HLS playlist, muxed audio, no `video`/`audio`) and `live`.
// Error: userInfo[@"bot"] = @YES when YouTube answered with a bot check; @"live" for streams the
// sidecar can't play (scheduled: @"upcoming" + @"startTime" epoch or 0; offline: message "offline").
- (void)open:(NSString *)videoID background:(BOOL)bg done:(void (^)(NSDictionary *r, NSError *e))done;
// Download variant: the same choice as playback (mpv plays everything, so no format limit any more -
// the former 720p H.264 limit was only for Kodi; user 2026-11-05), original audio track. No
// prefetch; the session lives as long as ffmpeg keeps reading.
- (void)openForDownload:(NSString *)videoID done:(void (^)(NSDictionary *r, NSError *e))done;
// SABR playback of this video failed (e.g. mpv could not read the local streams): use yt-dlp for
// it until the app restarts
- (void)markFailed:(NSString *)videoID;
- (BOOL)failedFor:(NSString *)videoID;
// drop a sidecar session (a retry then opens a fresh one instead of reattaching to the broken state)
- (void)closeSession:(NSString *)sid;
// diagnostics of a session (/s/<sid>/status; for lives `ended` = the broadcast is over); nil when
// the sidecar does not answer within a few seconds or the session is gone. Main thread.
- (void)sessionStatus:(NSString *)sid done:(void (^)(NSDictionary *status))done;
@property (nonatomic, readonly) BOOL available;   // sidecar present in the bundle and node found
// SABR can play this video here: sidecar available, mpv present and not overridden, not marked failed
- (BOOL)usableFor:(NSString *)videoID;
// http://127.0.0.1:<port> while the sidecar runs (PO tokens for the yt-dlp fallback: /pot), else nil
@property (nonatomic, readonly) NSString *baseURL;
// Preload on focus: the player response into the sidecar's cache, within a request budget and never
// while the bot-check breaker is open. Returns NO if nothing was sent.
- (BOOL)preloadOnFocus:(NSString *)videoID;
@end
