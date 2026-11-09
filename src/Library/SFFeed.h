// SFFeed - the newest episodes of a show/channel (newest first), from its owning app (SFApp feed:).
// What a follow's list is refreshed from (SFFollows).
#import "SFModel.h"
#import "SFApp.h"

typedef void (^SFFeedDone)(NSArray *items, NSError *e);
BOOL SFHasFeed(NSString *ref);                  // "prefix:id" is a show ref whose app has a feed
void SFFetchFeed(NSString *ref, SFFeedDone done);
// a feed from a page loader (show page): all videos of the page, newest first - for apps whose show
// page already lists the episodes
void SFFeedFromPage(SFPageLoader loader, SFFeedDone done);
