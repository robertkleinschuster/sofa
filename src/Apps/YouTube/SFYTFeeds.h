// Followed channels in the background (SFFollows, every 30 min for every channel): their newest
// videos and their picture - cheap and polite, a flagged IP must not get flagged again.
#import "SFModel.h"

@interface SFYTFeeds : NSObject
// The channel's long videos, newest first, as online items; done on main
+ (void)feed:(NSString *)channelID done:(void (^)(NSArray *items, NSError *e))done;
// Its avatar (TV-sized); done on main, nil = none (or not now: budget, bot-check pause)
+ (void)avatar:(NSString *)channelID done:(void (^)(NSString *url))done;
+ (NSArray *)videosInUploads:(id)browse;    // the uploads playlist's answer -> its videos (parser, tools/test-parse)
+ (void)devFeed:(NSString *)channelID;      // dev command ytfeed: the feed with each date's origin, logged
@end
