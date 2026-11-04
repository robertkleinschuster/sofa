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
- (NSArray *)recentlyPlayed:(NSInteger)limit source:(NSString *)source;
- (NSArray *)history:(NSInteger)limit;   // history: @{item, updated, watched, pos}, newest first
- (void)removeFromContinue:(NSString *)identifier;
- (NSString *)setting:(NSString *)key;
- (void)setSetting:(NSString *)value forKey:(NSString *)key;
// Simple JSON cache for providers (e.g. Mediathek responses), with age.
- (id)cachedJSON:(NSString *)key maxAge:(NSTimeInterval)age;
- (void)cacheJSON:(id)obj forKey:(NSString *)key;
// Generic access for other modules (downloads). Values: NSString/NSNumber/NSData/NSNull.
- (void)run:(NSString *)sql args:(NSArray *)args;                // asynchronous (writes)
- (NSArray *)rows:(NSString *)sql args:(NSArray *)args;          // synchronous, array of dictionaries
// Re-key progress/history to a new ID (migration local:… -> yt:…); only if the target is free
- (BOOL)moveProgress:(NSString *)from toItem:(SFItem *)item;   // migration: replace id + item
@end
