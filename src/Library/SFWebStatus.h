// SFWebStatus - what is going on at Sofa, for Sofa im Browser (docs/pwa.md §6): what the TV plays
// (SFWebTV state) and the downloads on their way (queued and running, as items with their chip and
// progress), one answer {gen, tv, downloads} the browser long-polls with the generation it has
// (`GET /api/status?since=`). It answers at once when that is not the current one, else as soon as
// something changes - the TV's player (SFPlayerStateNotification) or a download
// (SFDownloadsDidChangeNotification), coalesced - and at the latest after 25 s (3 s while a download
// runs: its progress). A generation is unique per launch, so a restarted Sofa always answers at once.
#import "SFLocalHTTP.h"

@interface SFWebStatus : NSObject
+ (instancetype)shared;
// Main thread; answers on the exchange's queue.
- (void)answer:(SFHTTPExchange *)x since:(NSString *)since;
- (NSDictionary *)current;   // the answer as it is now
@end
