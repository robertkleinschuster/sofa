// Persistence (SQLite): playback positions, watched status, history and app state
// (-setting:/-setSetting:). User settings belong in SFSettings – see the rule in SFSettings.h.
#import "SFModel.h"


@interface SFStore : NSObject
+ (instancetype)shared;
- (NSTimeInterval)positionFor:(NSString *)identifier;
- (double)progressFor:(NSString *)identifier;        // 0..1, 1 = watched
- (BOOL)watched:(NSString *)identifier;
- (void)savePosition:(NSTimeInterval)pos duration:(NSTimeInterval)dur forItem:(SFItem *)item;
- (void)setWatched:(BOOL)w forItem:(SFItem *)item;
- (void)flush;   // complete pending writes (quit)
- (NSArray *)continueWatching:(NSInteger)limit source:(NSString *)source;  // SFItem
- (NSArray *)history:(NSInteger)limit;   // history: @{item, updated, watched, pos}, newest first
- (void)removeFromContinue:(NSString *)identifier;
- (NSString *)setting:(NSString *)key;
- (void)setSetting:(NSString *)value forKey:(NSString *)key;   // nil removes the key
// Simple JSON cache for providers (e.g. Mediathek responses), with age.
- (id)cachedJSON:(NSString *)key maxAge:(NSTimeInterval)age;
- (void)cacheJSON:(id)obj forKey:(NSString *)key;
// Generic access for other modules (downloads). Values: NSString/NSNumber/NSData/NSNull.
- (void)run:(NSString *)sql args:(NSArray *)args;                // asynchronous (writes)
// several writes as one transaction (asynchronous): @[@[sql, args], ...] - all or nothing visible
- (void)runAll:(NSArray *)statements;
- (NSArray *)rows:(NSString *)sql args:(NSArray *)args;          // synchronous, array of dictionaries
// Items: one row of metadata per item (title, picture, date, ...), shared by progress, downloads,
// Watch Later and follows - they keep only their own facts and reference it by id. A write merges
// field by field (newer values win, fields this snapshot lacks stay); where an item lies on this
// disk (a download's file or thumbnail) belongs to that download and is left out.
- (NSArray *)itemWrite:(SFItem *)item;    // the statement, for runAll: (nil without id)
- (NSString *)saveItem:(SFItem *)item;    // asynchronous; returns the JSON written
// Original titles: what a video's uploader wrote, where the source's lists show another title
// (YouTube localizes list titles to the interface language; the watch page carries the original).
// A known one wins in every item write (and in the stored item at once); apps put it on the items
// their lists show. Loaded at launch.
- (NSString *)originalTitleFor:(NSString *)identifier;
- (void)setOriginalTitle:(NSString *)title forID:(NSString *)identifier;
// Re-key progress/history to a new ID (migration local:… -> yt:…); only if the target is free
- (BOOL)moveProgress:(NSString *)from toItem:(SFItem *)item;   // migration: replace id + item
@end
