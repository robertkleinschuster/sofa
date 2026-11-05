// YouTube: browsing 100 % native via InnerTube (WEB client), without sign-in; playback via
// SFYTResolver (yt-dlp, HLS 1080p). Following channels = Sofa's own list (SFFollows).
// Reference: docs/youtube.md. Local downloads (~/TV Shows, genre YouTube) are played
// in preference when the same video is already there.
#import "SFModel.h"

@interface SFYouTube : NSObject
+ (void)setup;                       // register the resolver, pre-warm yt-dlp
+ (SFPageLoader)homeLoader;
+ (SFPageLoader)channelLoader:(NSString *)channelID title:(NSString *)title;
+ (SFPageLoader)playlistLoader:(NSString *)playlistID title:(NSString *)title;
+ (SFPageLoader)searchLoader:(NSString *)query;
// Autocomplete (suggestqueries-clients6.youtube.com, plain GET); done on main, never nil
+ (void)suggestions:(NSString *)prefix done:(void (^)(NSArray *list))done;
+ (SFItem *)itemForVideoID:(NSString *)vid;                     // placeholder (local copy, if present)
// Video known by title/thumbnail only (end screen tile); the local copy, if present, is preferred
+ (SFItem *)itemForVideoID:(NSString *)vid title:(NSString *)title thumb:(NSString *)thumb;
+ (void)upNextFor:(NSString *)videoID done:(void (^)(SFItem *next))done;   // "up next" (recommendation, without Shorts/live/watched)
// Related videos of the watch page (no Shorts < 90 s, not the video itself); done on main, never nil
+ (void)relatedFor:(NSString *)videoID done:(void (^)(NSArray *items))done;
// Watch page in one request (the same cached InnerTube "next" call as related/up next):
// related = as relatedFor; details = description, channel, channelID (UC…), avatar, date (NSDate) –
// keys only present when found. done on main; related empty + details nil = request failed.
+ (void)watchPageFor:(NSString *)videoID done:(void (^)(NSArray *related, NSDictionary *details))done;
+ (void)resolveChannelURL:(NSString *)url done:(void (^)(NSString *channelID))done;   // @handle-URL -> UC…
+ (void)fillDetails:(SFItem *)item done:(dispatch_block_t)done; // title/channel/duration via InnerTube "player"
@end
