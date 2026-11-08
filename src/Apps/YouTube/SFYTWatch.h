// One video beyond the lists: its watch page (related videos, description, channel), its player
// details, its channel. All done blocks on main.
#import "SFModel.h"

@interface SFYTWatch : NSObject
// Watch page in one cached request (info panel and autoplay share it): related videos (no Shorts,
// not the video itself, local copies preferred) and details (title - the uploader's, remembered as
// the original title -, description, channel, channelID, avatar, date) - keys only when found;
// related empty + details nil = request failed
+ (void)watchPageFor:(NSString *)videoID done:(void (^)(NSArray *related, NSDictionary *details))done;
+ (void)upNextFor:(NSString *)videoID done:(void (^)(SFItem *next))done;   // first related video not watched yet
+ (void)fillDetails:(SFItem *)item done:(dispatch_block_t)done;          // title, channel, duration, live from InnerTube "player"
+ (void)channelOf:(NSString *)videoID done:(void (^)(NSString *channelID))done;   // UC… of a video
+ (void)resolveChannelURL:(NSString *)url done:(void (^)(NSString *channelID))done;   // @handle URL -> UC…
@end
