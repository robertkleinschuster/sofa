// SFMediaStore - media bytes on disk, by track: buffer and download are one thing
// (docs/media-store.md). A track is one byte stream with a stable identity (`key`, e.g.
// "yt:<video>:<itag>:<length>"), owned by an item; its bytes live in 4 MiB block files (HFS+ has no
// sparse files: one file per track would fill everything before a seek target with zeros), its
// present ranges in an SFExtentSet. The index is in memory (reads decide from it, never wait on the
// database) and persisted in the store's own database (store.db) next to the bytes - its own
// connection and queue: the user database (SFStore) never waits on media writes.
// Thread-safe; everything runs on the store's queue.
#import <Foundation/Foundation.h>
#import "SFExtentSet.h"

@interface SFMediaStore : NSObject
// The app's store is SFDownloads' (mediaStore): it owns storage and retention and configures it.
- (instancetype)initWithDirectory:(NSString *)dir;

// The bytes [start, start + length) of a track if all are present (the track counts as used), else nil
- (NSData *)read:(NSString *)key start:(long long)start length:(NSUInteger)length;
// The bytes present from `start` on without a gap, at most `max` (the track counts as used); nil: none
- (NSData *)readAvailable:(NSString *)key start:(long long)start max:(NSUInteger)max;
// Keep bytes of a track at `start` (the track is created on its first write). `total`: the track's
// length when known (0: unknown). Asynchronous; reads see the bytes once written.
- (void)write:(NSData *)data key:(NSString *)key item:(NSString *)item kind:(NSString *)kind total:(long long)total at:(long long)start;
- (SFExtentSet *)extentsOf:(NSString *)key;    // a copy (empty for an unknown track)
- (long long)bytesOfItem:(NSString *)item;     // stored bytes of all its tracks
- (void)removeItem:(NSString *)item;           // its tracks, bytes, index and manifest
// An item's manifest: what playing it needs without its source (source-specific JSON object; the
// YouTube app's: tracks, subtitles, duration, end screen). Kept while the item has bytes.
- (void)setManifest:(NSDictionary *)manifest forItem:(NSString *)item;
- (NSDictionary *)manifestOf:(NSString *)item;
// every one of these tracks is known with its length and present from 0 to it (playable offline)
- (BOOL)hasComplete:(NSArray *)keys;
@property (nonatomic, readonly) long long bytes;   // all stored bytes

// Eviction: while the volume has less free space than `reserve`, whole items go (tracks and manifest),
// least recently used first - never an item `isPinned` says yes to (downloads). Runs after writes by itself.
@property (atomic, copy) BOOL (^isPinned)(NSString *item);
@property (atomic) long long reserve;                    // bytes that stay free (default 0)
// The volume's free bytes (default); tests replace it. Called on the store's queue: must not call the store.
@property (atomic, copy) long long (^freeSpace)(void);
- (void)evictNow;                                        // one pass (tests; normally after writes)
- (void)sync;                                            // wait for pending writes (tests, quit)
@end
