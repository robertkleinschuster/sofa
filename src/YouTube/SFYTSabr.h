// YouTube via SABR: supervises the sofa-yt node sidecar (res/sofa-yt, docs/sofa-yt.md) and asks it
// to open videos. The sidecar looks like YouTube's own web player (one persistent session, WEB
// player request with a video-bound PO token, SABR streaming) and serves the chosen video/audio
// tracks as local Range-capable URLs for mpv. yt-dlp (SFYTResolver) stays the fallback and handles
// lives and downloads.
#import "SFCore.h"

extern NSString *const SFYTSabrDidExitNotification;   // the sidecar process ended (its URLs are dead)

@interface SFYTSabr : NSObject
+ (instancetype)shared;
- (void)start;   // idempotent; the real app starts it early, dev instances on first use
// result: the dash dict of ytresolver.py (video, audio, height, fps, vcodec, acodec, alang,
// audios, subs) plus id, sid, title, duration; all URLs local. Error: userInfo[@"bot"] = @YES
// when YouTube answered with a bot check, @"live" for lives (not handled by SABR).
- (void)open:(NSString *)videoID background:(BOOL)bg done:(void (^)(NSDictionary *r, NSError *e))done;
// Download variant: the same choice as playback (mpv plays everything, so no format limit any more -
// the former 720p H.264 limit was only for Kodi; user 2026-11-05), original audio track. No
// prefetch; the session lives as long as ffmpeg keeps reading.
- (void)openForDownload:(NSString *)videoID done:(void (^)(NSDictionary *r, NSError *e))done;
// SABR playback of this video failed (e.g. mpv could not read the local streams): use yt-dlp for
// it until the app restarts
- (void)markFailed:(NSString *)videoID;
- (BOOL)failedFor:(NSString *)videoID;
@property (nonatomic, readonly) BOOL available;   // sidecar present in the bundle and node found
@end
