// Followed channels in the background: their newest videos and their picture. When a channel is
// looked at is SFFollows' refresh plan (SFRefreshPlan: its upload rhythm, spread, rarer at night);
// here only what one look costs: one background InnerTube browse through the sidecar's session
// (SFYTCallBackground - refused during a bot-check pause, the follow then keeps its list).
#import "SFModel.h"

@interface SFYTFeeds : NSObject
// The channel's long videos, newest first, as online items; done on main; nil = not now
+ (void)feed:(NSString *)channelID done:(void (^)(NSArray *items, NSError *e))done;
// Its avatar (TV-sized); done on main, nil = none (or not now: budget, bot-check pause)
+ (void)avatar:(NSString *)channelID done:(void (^)(NSString *url))done;
+ (NSArray *)videosInUploads:(id)browse;    // the uploads playlist's answer -> its videos (parser, tools/test-parse)
+ (void)devFeed:(NSString *)channelID;      // dev command ytfeed: the feed, logged
@end
