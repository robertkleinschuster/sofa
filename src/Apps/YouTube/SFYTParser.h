// What InnerTube JSON means for Sofa (docs/youtube.md §3.0): items, channel headers, watch pages.
// Pure: no request, no library state - videos are online items, folders (playlists, channels)
// come without a page loader. SFYTPages makes them what Sofa shows (local copies, pages).
// Tested against recorded answers: tools/test-parse.
#import "SFModel.h"

NSString *SFYTBackdrop(NSString *videoID);   // TV-sized picture of a video (falls back to the tile picture where missing, SFImageLayer)
// "313.544 Aufrufe" / "1,4 Mio. Aufrufe" (hl=de) -> count; -1 = not a view count
long long SFYTViewCount(NSString *s);

@interface SFYTParser : NSObject
// Every video/playlist (in order, without duplicates) and channel in an answer, and its continuation token
+ (NSArray *)itemsIn:(id)json continuation:(NSString **)cont channels:(NSMutableArray *)channels;
+ (SFItem *)videoItem:(NSString *)videoID title:(NSString *)title channel:(NSString *)channel channelID:(NSString *)channelID
                 meta:(NSString *)meta thumb:(NSString *)thumb duration:(NSTimeInterval)duration live:(BOOL)live;
+ (SFItem *)channelItem:(NSString *)channelID title:(NSString *)title avatar:(NSString *)avatar meta:(NSString *)meta;
// Channel header (browse of the channel ID): banner (TV-sized), avatar (TV-sized), meta (handle,
// subscribers, videos), description - keys only when found
+ (NSDictionary *)channelHeaderIn:(id)json;
// A channel tab's answer is that tab - YouTube answers a missing tab (e.g. no "Live") with "Home"
+ (BOOL)isTab:(NSString *)urlSuffix in:(id)json;
+ (NSString *)popularTokenIn:(id)videosTab;  // the videos tab's sort chip "Beliebt": continuation token
+ (NSString *)searchTypeFilter:(NSString *)label in:(id)search;   // first search answer: "Typ" filter (e.g. "Playlists") -> params
// Watch page ("next"): related videos (no Shorts, not the video itself) and details (description,
// channel, channelID, avatar, date) - keys only when found
+ (NSArray *)relatedIn:(id)next video:(NSString *)videoID;
+ (NSDictionary *)watchDetailsIn:(id)next;   // title, description, channel, channelID, avatar, date, live (only what the page has)
@end
