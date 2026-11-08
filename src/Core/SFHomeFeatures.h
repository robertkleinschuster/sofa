// Content apps feature on Sofa's home page, merged across apps into shared rows ("topics").
//
// An app contributes through SFApp homeFeatures: (items per topic, in the app's own order of
// importance). Sofa keeps each app's list (stored, so Home shows them at once after a launch;
// refreshed every 30 min while the screen is awake, on waking up, when the network comes back and
// when a live programme changes; nothing while the screen sleeps) and
// merges them when a row is shown: first what can't play here is left out, then the lists are
// interleaved in registry order so every app gets a fair place at the front. Rows of SFHome read
// itemsForTopic: synchronously.
//
// Topics are defined here, not by apps: a topic is a promise about what the row means.
#import "SFModel.h"

extern NSString *const SFHomeTopicLive;         // "Jetzt live": live TV channels and streams
extern NSString *const SFHomeTopicNews;         // "Nachrichten": the latest news (each app's news page), each app newest first
extern NSString *const SFHomeTopicHighlights;   // "Highlights": each app's editorial top picks (videos, shows)
extern NSString *const SFHomeFeaturesDidChangeNotification;

typedef void (^SFHomeFeaturesDone)(NSDictionary *itemsByTopic);   // topic -> NSArray of SFItem; any thread

// Topics read structurally from an app's start page: live = every item of kind SFItemLive;
// highlights = the playable videos and shows of the top shelf (`highlightShelf`, the editors' lead
// placement; NSNotFound = none) - navigation tiles (categories, A-Z) are left out.
NSDictionary *SFHomeFeaturesFromPage(SFPage *page, NSUInteger highlightShelf);
// The videos of a page's first shelf that has any (e.g. a news page's lead: the current editions).
NSArray *SFHomeFeaturesLeadVideos(SFPage *page);

@interface SFHomeFeatures : NSObject
+ (instancetype)shared;
- (void)start;                                   // restore the stored rows, refresh now + periodically
- (void)refresh;                                 // ask every app again (coalesced while running)
- (void)whenRestored:(dispatch_block_t)block;    // main thread: once the stored rows are in (at once after that)
- (NSArray *)itemsForTopic:(NSString *)topic;    // merged; main thread; copies, marked showsSourceMark; only
                                                 // what plays here (no drm, no geoRegion the device is outside of),
                                                 // nothing watched already
+ (NSArray *)topics;                             // all topics, in no particular order
@end
