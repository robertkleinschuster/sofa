// SFWebItems - Sofa's pages as JSON for Sofa im Browser (docs/pwa.md): items with what a tile shows
// (title, subtitle, picture, progress, the download chip, Später ansehen, followed) and their stored
// dictionary (`d`, echoed back by the browser to play or mark an item); shelves and pages as the TV
// lays them out. A folder's page loader and a shelf's further items are blocks: they get handles
// (random, bounded LRU) the browser asks for later. Main thread.
#import "SFModel.h"

@interface SFWebItems : NSObject
+ (NSDictionary *)page:(SFPage *)page;
+ (NSArray *)items:(NSArray *)items;
+ (NSDictionary *)item:(SFItem *)item;
// An item the browser sent back (its `d`): never with a local path or a non-web URL it names itself
// (where a video lies on this disk is the downloads' to say). nil when unusable.
+ (SFItem *)itemFromBrowser:(NSDictionary *)d;
+ (SFPageLoader)pageLoaderForHandle:(NSString *)handle;
+ (void (^)(void (^)(NSArray *, BOOL)))moreLoaderForHandle:(NSString *)handle;
// a handle for a page loader the server built (show pages, search)
+ (NSString *)handleForPageLoader:(SFPageLoader)loader;
@end
