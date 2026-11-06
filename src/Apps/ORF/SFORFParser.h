// ORF ON answers -> Sofa items. Pure: no requests, no library state; tested against recorded
// answers (tests/fixtures/orf, tools/test-parse). The app (SFORFApp) loads and composes pages.
#import "SFModel.h"

@interface SFORFParser : NSObject
// a list answer (_items / _embedded.items / bare array) of episodes, segments or highlights
+ (NSArray *)episodeItems:(id)json;
+ (SFItem *)episodeItem:(NSDictionary *)e;
+ (NSString *)image:(NSDictionary *)it big:(BOOL)big;
// /livestreams: one item per channel, the broadcast on air at `now` plus the channel's programme;
// nil = not a livestreams answer
+ (NSArray *)liveItemsIn:(id)json at:(NSDate *)now;
+ (NSDictionary *)broadcastAt:(NSDate *)now in:(NSArray *)broadcasts;
// an episode/segment/livestream: @{url, subs} of the adaptive HLS stream, or @{drm: @YES} / @{}
+ (NSDictionary *)streamIn:(NSDictionary *)obj;
@end
