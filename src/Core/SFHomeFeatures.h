// Content apps feature on Sofa's home page, merged across apps into shared rows ("topics").
//
// An app contributes through SFApp homeFeatures: (items per topic, in the app's own order of
// importance). Sofa merges the contributions of all apps per topic - interleaved in registry
// order so every app gets a fair place at the front (live: Das Erste, ZDF, ORF 1, …) - and keeps
// the result (stored, so Home shows it at once after a launch; refreshed every 30 min and when
// the network comes back). Rows of SFHome read itemsForTopic: synchronously.
//
// Topics are defined here, not by apps: a topic is a promise about what the row means.
#import "SFModel.h"

extern NSString *const SFHomeTopicLive;         // "Jetzt live": live TV channels and streams
extern NSString *const SFHomeTopicHighlights;   // "Highlights": each app's editorial top picks (videos, shows)
extern NSString *const SFHomeFeaturesDidChangeNotification;

typedef void (^SFHomeFeaturesDone)(NSDictionary *itemsByTopic);   // topic -> NSArray of SFItem; any thread

// Topics read structurally from an app's start page: live = every item of kind SFItemLive;
// highlights = the playable videos and shows of the top shelf (`highlightShelf`, the editors' lead
// placement; NSNotFound = none) - navigation tiles (categories, A-Z) are left out.
NSDictionary *SFHomeFeaturesFromPage(SFPage *page, NSUInteger highlightShelf);

@interface SFHomeFeatures : NSObject
+ (instancetype)shared;
- (void)start;                                   // restore the stored rows, refresh now + periodically
- (void)refresh;                                 // ask every app again (coalesced while running)
- (NSArray *)itemsForTopic:(NSString *)topic;    // merged; main thread; copies, marked showsSourceMark; only
                                                 // what plays here (no drm, no geoRegion the device is outside of)
@end
