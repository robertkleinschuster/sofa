#import "SFMediaStore.h"
#import "SFCore.h"
#import <sqlite3.h>
#include <fcntl.h>
#include <unistd.h>

static const long long kBlock = 4LL << 20;            // bytes per block file
static const long long kEvictEvery = 64LL << 20;      // an eviction pass after this many written bytes
static const NSTimeInterval kUsedPersistGap = 60;     // "used" goes to the database at most this often per track

// One track in memory (on the store's queue only)
@interface SFMediaTrack : NSObject
@property (nonatomic) long long rowid, total;
@property (nonatomic, copy) NSString *key, *item, *kind;
@property (nonatomic) NSTimeInterval used, usedSaved;
@property (nonatomic, strong) SFExtentSet *extents;
@end
@implementation SFMediaTrack
@end

@implementation SFMediaStore {
    dispatch_queue_t _q;
    sqlite3 *_db;
    NSString *_dir;
    NSMutableDictionary *_tracks;   // key -> SFMediaTrack
    long long _bytes, _sinceEvict;
}

- (instancetype)initWithDirectory:(NSString *)dir {
    if ((self = [super init])) {
        _dir = [dir copy];
        _q = dispatch_queue_create("sofa.media-store", DISPATCH_QUEUE_SERIAL);
        _tracks = [NSMutableDictionary new];
        NSString *d = _dir;
        self.freeSpace = ^long long {
            return [[[NSFileManager defaultManager] attributesOfFileSystemForPath:d error:nil][NSFileSystemFreeSize] longLongValue];
        };
        dispatch_sync(_q, ^{ [self open]; });
    }
    return self;
}

#pragma mark Database (on _q)

- (BOOL)run:(NSString *)sql args:(NSArray *)args {
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(_db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) { SFLog(@"media-store: %@ -> %s", sql, sqlite3_errmsg(_db)); return NO; }
    [self bind:st args:args];
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE && rc != SQLITE_ROW) { SFLog(@"media-store: %@ -> %s", sql, sqlite3_errmsg(_db)); return NO; }
    return YES;
}

- (void)bind:(sqlite3_stmt *)st args:(NSArray *)args {
    for (int i = 0; i < (int)args.count; i++) {
        id a = args[i];
        if ([a isKindOfClass:[NSString class]]) sqlite3_bind_text(st, i + 1, [a UTF8String], -1, SQLITE_TRANSIENT);
        else if (strcmp([a objCType], "d") == 0 || strcmp([a objCType], "f") == 0) sqlite3_bind_double(st, i + 1, [a doubleValue]);
        else sqlite3_bind_int64(st, i + 1, [a longLongValue]);
    }
}

- (long long)intOf:(NSString *)sql {
    sqlite3_stmt *st; long long v = 0;
    if (sqlite3_prepare_v2(_db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) v = sqlite3_column_int64(st, 0);
        sqlite3_finalize(st);
    }
    return v;
}

- (void)open {
    [[NSFileManager defaultManager] createDirectoryAtPath:_dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *p = [_dir stringByAppendingPathComponent:@"store.db"];
    if (sqlite3_open(p.fileSystemRepresentation, &_db) != SQLITE_OK) { SFLog(@"media-store: open failed %s", sqlite3_errmsg(_db)); return; }
    // Schema by version (PRAGMA user_version), one step per version. v1: tracks and their ranges (a
    // track's ranges go with it; a range is never empty). v2: an item's manifest - what playing it
    // needs without its source (docs/media-store.md); it goes with the item's last track.
    for (NSString *s in @[@"PRAGMA journal_mode=WAL", @"PRAGMA synchronous=NORMAL", @"PRAGMA foreign_keys=ON"]) [self run:s args:nil];
    int version = (int)[self intOf:@"PRAGMA user_version"];
    if (version < 1) {
        [self run:@"CREATE TABLE IF NOT EXISTS tracks (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, item TEXT NOT NULL, "
                   "kind TEXT NOT NULL, total INTEGER NOT NULL DEFAULT 0 CHECK (total >= 0), used REAL NOT NULL)" args:nil];
        [self run:@"CREATE INDEX IF NOT EXISTS tracks_item ON tracks(item)" args:nil];
        [self run:@"CREATE TABLE IF NOT EXISTS extents (track INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE, "
                   "start INTEGER NOT NULL CHECK (start >= 0), end INTEGER NOT NULL, CHECK (end > start), "
                   "PRIMARY KEY (track, start)) WITHOUT ROWID" args:nil];
    }
    if (version < 2) [self run:@"CREATE TABLE IF NOT EXISTS manifests (item TEXT PRIMARY KEY, json TEXT NOT NULL)" args:nil];
    if (version < 2) [self run:@"PRAGMA user_version=2" args:nil];
    // a manifest whose item has no bytes (opened, nothing played): written again by the next open
    [self run:@"DELETE FROM manifests WHERE item NOT IN (SELECT item FROM tracks)" args:nil];
    // the index into memory: tracks, then their ranges
    NSMutableDictionary *byRow = [NSMutableDictionary new];
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(_db, "SELECT id, key, item, kind, total, used FROM tracks", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            SFMediaTrack *t = [SFMediaTrack new];
            t.rowid = sqlite3_column_int64(st, 0);
            t.key = @((const char *)sqlite3_column_text(st, 1));
            t.item = @((const char *)sqlite3_column_text(st, 2));
            t.kind = @((const char *)sqlite3_column_text(st, 3));
            t.total = sqlite3_column_int64(st, 4);
            t.used = t.usedSaved = sqlite3_column_double(st, 5);
            t.extents = [SFExtentSet new];
            _tracks[t.key] = t;
            byRow[@(t.rowid)] = t;
        }
        sqlite3_finalize(st);
    }
    if (sqlite3_prepare_v2(_db, "SELECT track, start, end FROM extents", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            SFMediaTrack *t = byRow[@(sqlite3_column_int64(st, 0))];
            [t.extents addStart:sqlite3_column_int64(st, 1) end:sqlite3_column_int64(st, 2)];
        }
        sqlite3_finalize(st);
    }
    for (SFMediaTrack *t in _tracks.allValues) _bytes += t.extents.bytes;
    if (_tracks.count) SFLog(@"media-store: %lu tracks, %.0f MB", (unsigned long)_tracks.count, _bytes / 1048576.0);
}

- (void)saveExtents:(SFMediaTrack *)t {
    [self run:@"BEGIN" args:nil];
    [self run:@"DELETE FROM extents WHERE track = ?" args:@[@(t.rowid)]];
    for (NSArray *r in t.extents.ranges) [self run:@"INSERT INTO extents (track, start, end) VALUES (?, ?, ?)" args:@[@(t.rowid), r[0], r[1]]];
    [self run:@"UPDATE tracks SET total = ?, used = ? WHERE id = ?" args:@[@(t.total), @(t.used), @(t.rowid)]];
    [self run:@"COMMIT" args:nil];
    t.usedSaved = t.used;
}

#pragma mark Files (on _q)

- (NSString *)blockPath:(SFMediaTrack *)t block:(long long)b {
    return [_dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld/%lld", t.rowid, b]];
}

// the bytes [start, end) of a track across its block files; nil if a file comes up short
- (NSData *)readTrack:(SFMediaTrack *)t start:(long long)start end:(long long)end {
    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)(end - start)];
    for (long long off = start; off < end;) {
        long long b = off / kBlock, in = off % kBlock, n = MIN(end - off, kBlock - in);
        int fd = open([self blockPath:t block:b].fileSystemRepresentation, O_RDONLY);
        ssize_t r = fd >= 0 ? pread(fd, (uint8_t *)out.mutableBytes + (off - start), (size_t)n, in) : -1;
        if (fd >= 0) close(fd);
        if (r != n) return nil;
        off += n;
    }
    return out;
}

- (BOOL)writeTrack:(SFMediaTrack *)t data:(NSData *)data at:(long long)start {
    [[NSFileManager defaultManager] createDirectoryAtPath:[[self blockPath:t block:0] stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    for (long long off = start, end = start + (long long)data.length; off < end;) {
        long long b = off / kBlock, in = off % kBlock, n = MIN(end - off, kBlock - in);
        int fd = open([self blockPath:t block:b].fileSystemRepresentation, O_WRONLY | O_CREAT, 0644);
        ssize_t w = fd >= 0 ? pwrite(fd, (const uint8_t *)data.bytes + (off - start), (size_t)n, in) : -1;
        if (fd >= 0) close(fd);
        if (w != n) { SFLog(@"media-store: write failed (%s) - %@", strerror(errno), t.key); return NO; }
        off += n;
    }
    return YES;
}

- (void)removeTrack:(SFMediaTrack *)t {
    [[NSFileManager defaultManager] removeItemAtPath:[[self blockPath:t block:0] stringByDeletingLastPathComponent] error:nil];
    [self run:@"DELETE FROM tracks WHERE id = ?" args:@[@(t.rowid)]];   // (its extents cascade)
    _bytes -= t.extents.bytes;
    [_tracks removeObjectForKey:t.key];
}

#pragma mark API

- (NSData *)read:(NSString *)key start:(long long)start length:(NSUInteger)length {
    __block NSData *d = nil;
    dispatch_sync(_q, ^{
        SFMediaTrack *t = self->_tracks[key];
        long long end = start + (long long)length;
        if (!t || ![t.extents coversStart:start end:end]) return;
        d = [self readTrack:t start:start end:end];
        if (!d) {   // the index promised bytes a file does not have (deleted from outside): forget them
            SFLog(@"media-store: %@ [%lld, %lld) missing on disk - dropped from the index", key, start, end);
            long long before = t.extents.bytes;
            [t.extents removeStart:start end:end];
            self->_bytes -= before - t.extents.bytes;
            [self saveExtents:t];
            return;
        }
        t.used = [NSDate date].timeIntervalSince1970;
        if (t.used - t.usedSaved > kUsedPersistGap) [self saveExtents:t];
    });
    return d;
}

- (NSData *)readAvailable:(NSString *)key start:(long long)start max:(NSUInteger)max {
    __block long long n = 0;
    dispatch_sync(_q, ^{ n = MIN((long long)max, [((SFMediaTrack *)self->_tracks[key]).extents contiguousFrom:start]); });
    return n > 0 ? [self read:key start:start length:(NSUInteger)n] : nil;
}

- (void)write:(NSData *)data key:(NSString *)key item:(NSString *)item kind:(NSString *)kind total:(long long)total at:(long long)start {
    if (!data.length || !key.length || !item.length) return;
    data = [data copy];
    dispatch_async(_q, ^{
        SFMediaTrack *t = self->_tracks[key];
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (!t) {
            if (![self run:@"INSERT INTO tracks (key, item, kind, total, used) VALUES (?, ?, ?, ?, ?)" args:@[key, item, kind ?: @"", @(total), @(now)]]) return;
            t = [SFMediaTrack new];
            t.rowid = sqlite3_last_insert_rowid(self->_db);
            t.key = key; t.item = item; t.kind = kind ?: @""; t.used = now;
            t.extents = [SFExtentSet new];
            self->_tracks[key] = t;
        }
        if (total > 0) t.total = total;
        if (![self writeTrack:t data:data at:start]) return;
        long long before = t.extents.bytes;
        [t.extents addStart:start end:start + (long long)data.length];
        self->_bytes += t.extents.bytes - before;
        t.used = now;
        [self saveExtents:t];
        self->_sinceEvict += (long long)data.length;
        if (self->_sinceEvict >= kEvictEvery) { self->_sinceEvict = 0; [self evict]; }
    });
}

- (SFExtentSet *)extentsOf:(NSString *)key {
    __block SFExtentSet *e = nil;
    dispatch_sync(_q, ^{ e = [((SFMediaTrack *)self->_tracks[key]).extents copy]; });
    return e ?: [SFExtentSet new];
}

- (long long)bytesOfItem:(NSString *)item {
    __block long long n = 0;
    dispatch_sync(_q, ^{ for (SFMediaTrack *t in self->_tracks.allValues) if ([t.item isEqualToString:item]) n += t.extents.bytes; });
    return n;
}

- (void)removeItem:(NSString *)item {
    dispatch_sync(_q, ^{ [self dropItem:item]; });
}

// on _q: an item's tracks, bytes and manifest
- (void)dropItem:(NSString *)item {
    for (SFMediaTrack *t in [_tracks.allValues copy]) if ([t.item isEqualToString:item]) [self removeTrack:t];
    [self run:@"DELETE FROM manifests WHERE item = ?" args:@[item]];
}

- (void)setManifest:(NSDictionary *)manifest forItem:(NSString *)item {
    NSData *json = manifest ? [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil] : nil;
    if (!json || !item.length) return;
    NSString *s = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    dispatch_async(_q, ^{ [self run:@"INSERT OR REPLACE INTO manifests (item, json) VALUES (?, ?)" args:@[item, s]]; });
}

- (NSDictionary *)manifestOf:(NSString *)item {
    __block NSDictionary *m = nil;
    dispatch_sync(_q, ^{
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, "SELECT json FROM manifests WHERE item = ?", -1, &st, NULL) != SQLITE_OK) return;
        [self bind:st args:@[item ?: @""]];
        if (sqlite3_step(st) == SQLITE_ROW) {
            NSData *d = [NSData dataWithBytes:sqlite3_column_blob(st, 0) length:(NSUInteger)sqlite3_column_bytes(st, 0)];
            id v = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            m = [v isKindOfClass:[NSDictionary class]] ? v : nil;
        }
        sqlite3_finalize(st);
    });
    return m;
}

- (BOOL)hasComplete:(NSArray *)keys {
    __block BOOL ok = keys.count > 0;
    dispatch_sync(_q, ^{
        for (NSString *k in keys) {
            SFMediaTrack *t = self->_tracks[k];
            if (!t || t.total <= 0 || ![t.extents coversStart:0 end:t.total]) { ok = NO; return; }
        }
    });
    return ok;
}

- (long long)bytes {
    __block long long n = 0;
    dispatch_sync(_q, ^{ n = self->_bytes; });
    return n;
}

#pragma mark Eviction

// on _q: while free space is below the reserve, the least recently used unpinned item goes - whole
// (its tracks and manifest: half an item plays nothing and frees little)
- (void)evict {
    BOOL (^pinned)(NSString *) = self.isPinned;
    long long (^free)(void) = self.freeSpace;
    long long reserve = self.reserve;
    if (!free || free() >= reserve) return;
    NSMutableDictionary *lastUse = [NSMutableDictionary new], *size = [NSMutableDictionary new];   // item -> latest use, bytes
    for (SFMediaTrack *t in _tracks.allValues) {
        if (pinned && pinned(t.item)) continue;
        lastUse[t.item] = @(MAX([lastUse[t.item] doubleValue], t.used));
        size[t.item] = @([size[t.item] longLongValue] + t.extents.bytes);
    }
    NSArray *byAge = [lastUse keysSortedByValueUsingSelector:@selector(compare:)];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    for (NSString *item in byAge) {
        if (free() >= reserve) break;
        SFLog(@"media-store: evict %@ (%.0f MB, unused for %.0f h)", item, [size[item] longLongValue] / 1048576.0, (now - [lastUse[item] doubleValue]) / 3600);
        [self dropItem:item];
    }
}

- (void)evictNow { dispatch_sync(_q, ^{ [self evict]; }); }
- (void)sync { dispatch_sync(_q, ^{}); }
@end
