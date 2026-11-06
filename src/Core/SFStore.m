#import "SFStore+Private.h"
#import <sqlite3.h>

// The one SQLite connection (WAL, serial queue): progress, settings, generic statements, the response
// cache (own file). The schema and its steps: SFStore+Schema.m. Dev instances: their own data directory.

@implementation SFStore {
    sqlite3 *_db;
    NSUInteger _errors;   // failed statements so far (a migration step that adds one is rolled back)
    dispatch_queue_t _q;
    NSMutableDictionary *_progressCache;   // id -> @[pos, dur, watched]
}

+ (instancetype)shared {
    static SFStore *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFStore new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("sofa.store", DISPATCH_QUEUE_SERIAL);
        _progressCache = [NSMutableDictionary new];
        // dev instances: SFAppSupportDir is their own directory (SFSetDevInstance)
        NSString *p = [SFAppSupportDir() stringByAppendingPathComponent:@"sofa.db"];
        if (sqlite3_open(p.fileSystemRepresentation, &_db) != SQLITE_OK) {
            SFLog(@"store: open failed %s", sqlite3_errmsg(_db));
        }
        // WAL: readers never wait for the writer; NORMAL is durable against app crashes (a power loss
        // can lose the last commits, never corrupt). One connection, used only on _q.
        [self exec:@"PRAGMA journal_mode=WAL"];
        [self exec:@"PRAGMA synchronous=NORMAL"];
        [self exec:@"PRAGMA temp_store=MEMORY"];
        [self exec:@"PRAGMA journal_size_limit=8388608"];   // WAL file trimmed back to 8 MB after checkpoints
        [self attachCache];
        [self migrate];
        [self loadProgress];
        // response cache housekeeping: shortly after launch, then daily
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), _q, ^{ [self trimCache]; });
    }
    return self;
}

- (NSUInteger)errorCount { return _errors; }

#pragma mark Response cache

// The response cache is not user data: its own file in the caches folder (SFCacheDir: the real app
// ~/Library/Caches/Sofa, a dev instance its own), attached to the one connection as schema "cache".
// Losing it costs requests, nothing else; macOS may clear it. Its table is created here, not by a
// migration step - the cache has no history to migrate (schema step 10 moved the old one over).
- (void)attachCache {
    NSString *p = [SFCacheDir() stringByAppendingPathComponent:@"cache.db"];
    char *sql = sqlite3_mprintf("ATTACH DATABASE %Q AS cache", p.fileSystemRepresentation);
    [self exec:@(sql)];
    sqlite3_free(sql);
    [self exec:@"PRAGMA cache.auto_vacuum=INCREMENTAL"];   // takes effect on a new file (before the first table)
    [self exec:@"PRAGMA cache.journal_mode=WAL"];
    [self exec:@"CREATE TABLE IF NOT EXISTS cache.jcache (k TEXT PRIMARY KEY, t REAL, v BLOB)"];
    [self exec:@"CREATE INDEX IF NOT EXISTS cache.jcache_t ON jcache(t)"];
}

#pragma mark Response cache housekeeping
// SFNet keeps raw answers here (fresh for their cacheAge; older ones are the fallback when a source
// fails) and apps keep derived data under their own keys (YouTube's stored feeds, rewritten when
// they change). Kept for 14 days and 64 MB at most, oldest first. Without this the cache grew to 217 MB (2026-11-05).
static const NSTimeInterval kCacheKeep = 14 * 86400;
static const long long kCacheMaxBytes = 64LL * 1024 * 1024;

- (void)trimCacheNow {
    double now = [NSDate date].timeIntervalSince1970;
    [self runNow:@"DELETE FROM cache.jcache WHERE t < ?" args:@[@(now - kCacheKeep)]];
    // size cap in one pass: newest first, everything from the entry that crosses the cap on goes
    long long bytes = 0;
    for (NSDictionary *r in [self rowsNow:@"SELECT t, LENGTH(v) AS n FROM cache.jcache ORDER BY t DESC" args:nil]) {
        bytes += [r[@"n"] longLongValue];
        if (bytes > kCacheMaxBytes) { [self runNow:@"DELETE FROM cache.jcache WHERE t <= ?" args:@[r[@"t"]]]; break; }
    }
}

- (void)trimCache {   // on _q - with the other housekeeping
    [self trimCacheNow];
    [self pruneItemsNow];
    [self exec:@"PRAGMA main.incremental_vacuum"];
    [self exec:@"PRAGMA cache.incremental_vacuum"];
    [self exec:@"PRAGMA wal_checkpoint(TRUNCATE)"];   // every attached database
    __weak SFStore *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(86400 * NSEC_PER_SEC)), _q, ^{ [ws trimCache]; });
}

- (void)exec:(NSString *)sql {
    char *err = NULL;
    if (sqlite3_exec(_db, sql.UTF8String, NULL, NULL, &err) != SQLITE_OK) {
        _errors++;
        SFLog(@"store: %@ -> %s", sql, err);
        sqlite3_free(err);
    }
}

- (void)loadProgress {
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(_db, @"SELECT id,pos,dur,watched FROM progress".UTF8String, -1, &st, NULL) != SQLITE_OK) return;
    while (sqlite3_step(st) == SQLITE_ROW) {
        NSString *i = @((const char *)sqlite3_column_text(st, 0));
        _progressCache[i] = @[@(sqlite3_column_double(st, 1)), @(sqlite3_column_double(st, 2)), @(sqlite3_column_int(st, 3))];
    }
    sqlite3_finalize(st);
}

static void bindText(sqlite3_stmt *st, int idx, NSString *s) {
    if (s) sqlite3_bind_text(st, idx, s.UTF8String, -1, SQLITE_TRANSIENT);
    else sqlite3_bind_null(st, idx);
}

- (NSTimeInterval)positionFor:(NSString *)i {
    if (!i) return 0;
    @synchronized (_progressCache) {
        NSArray *a = _progressCache[i];
        if (!a || [a[2] boolValue]) return 0;
        return [a[0] doubleValue];
    }
}
- (double)progressFor:(NSString *)i {
    if (!i) return 0;
    @synchronized (_progressCache) {
        NSArray *a = _progressCache[i];
        if (!a) return 0;
        if ([a[2] boolValue]) return 1;
        double d = [a[1] doubleValue];
        return d > 0 ? MIN(1, [a[0] doubleValue] / d) : 0;
    }
}
- (BOOL)watched:(NSString *)i {
    @synchronized (_progressCache) { return [_progressCache[i][2] boolValue]; }
}

- (void)write:(SFItem *)item pos:(double)pos dur:(double)dur watched:(BOOL)w {
    if (!item.identifier) return;
    @synchronized (_progressCache) { _progressCache[item.identifier] = @[@(pos), @(dur), @(w)]; }
    NSArray *iw = [self itemWrite:item];
    NSArray *args = @[item.identifier, @(pos), @(dur), @(w), @([NSDate date].timeIntervalSince1970), item.source ?: [NSNull null]];
    dispatch_async(_q, ^{
        if (iw) [self runNow:iw[0] args:iw[1]];
        [self runNow:@"INSERT OR REPLACE INTO progress (id,pos,dur,watched,updated,source) VALUES (?,?,?,?,?,?)" args:args];
    });
}

- (void)savePosition:(NSTimeInterval)pos duration:(NSTimeInterval)dur forItem:(SFItem *)item {
    if (item.kind == SFItemLive) return;
    BOOL w = dur > 0 && (pos >= dur * 0.94 || dur - pos < MIN(30, dur * 0.1));
    if (w == NO && [self watched:item.identifier] && pos < 30) return;   // rewatching: keep the status
    if (pos < 10 && !w) {   // barely watched: history only, without position
        pos = 0;
    }
    BOOL old = [self watched:item.identifier];
    [self write:item pos:w ? 0 : pos dur:dur watched:(w || old)];
}

- (void)flush { dispatch_sync(_q, ^{}); }

- (void)setWatched:(BOOL)w forItem:(SFItem *)item {
    [self write:item pos:0 dur:item.duration watched:w];
}

// A stored progress item, or nil when it can't be played any more (local file gone, no online way)
static SFItem *playableItem(id json) {
    NSDictionary *d = SFJSONParse(json);
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    SFItem *i = [SFItem itemWithDictionary:d];
    if (i.localPath && ![[NSFileManager defaultManager] fileExistsAtPath:i.localPath] && !i.resolverRef) return nil;
    return i;
}

// rows read on the queue, decoded here (JSON, file checks) - not while holding the database
- (NSArray *)query:(NSString *)where limit:(NSInteger)limit source:(NSString *)source {
    NSString *sql = [NSString stringWithFormat:@"SELECT i.json AS item FROM progress p JOIN items i ON i.id = p.id WHERE %@ %@ ORDER BY updated DESC LIMIT %ld",
                     where, source ? @"AND source=?" : @"", (long)limit];
    NSMutableArray *out = [NSMutableArray new];
    for (NSDictionary *r in [self rows:sql args:source ? @[source] : nil]) { SFItem *i = playableItem(r[@"item"]); if (i) [out addObject:i]; }
    return out;
}

// Subtitle for every "Weiterschauen" shelf (home, apps): "Kanal · noch 12:34" - parts that are
// unknown (no channel, no duration) are left out instead of leaving "· noch".
- (NSArray *)continueWatching:(NSInteger)limit source:(NSString *)source {
    NSArray *items = [self query:@"watched=0 AND pos>0" limit:limit source:source];
    for (SFItem *e in items) {
        NSTimeInterval left = e.duration > 0 ? MAX(0, e.duration - [self positionFor:e.identifier]) : 0;
        e.subtitle = SFDotJoin(e.channel, left >= 1 ? [@"noch " stringByAppendingString:SFFormatDuration(left)] : nil);
    }
    return items;
}
// History: recently played content with timestamp (@{item, updated, watched, pos})
- (NSArray *)history:(NSInteger)limit {
    NSMutableArray *out = [NSMutableArray new];
    NSString *sql = [NSString stringWithFormat:@"SELECT i.json AS item,updated,watched,pos FROM progress p JOIN items i ON i.id = p.id ORDER BY updated DESC LIMIT %ld", (long)limit];
    for (NSDictionary *r in [self rows:sql args:nil]) {
        SFItem *i = playableItem(r[@"item"]);
        if (i) [out addObject:@{@"item": i, @"updated": r[@"updated"] ?: @0, @"watched": r[@"watched"] ?: @0, @"pos": r[@"pos"] ?: @0}];
    }
    return out;
}

- (void)removeFromContinue:(NSString *)identifier {
    @synchronized (_progressCache) {
        NSArray *a = _progressCache[identifier];
        if (a) _progressCache[identifier] = @[@0, a[1], a[2]];
    }
    dispatch_async(_q, ^{
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, @"UPDATE progress SET pos=0 WHERE id=?".UTF8String, -1, &st, NULL) != SQLITE_OK) return;
        bindText(st, 1, identifier);
        sqlite3_step(st); sqlite3_finalize(st);
    });
}


- (NSString *)setting:(NSString *)key {
    __block NSString *v = nil;
    dispatch_sync(_q, ^{
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, "SELECT v FROM settings WHERE k=?", -1, &st, NULL) != SQLITE_OK) return;
        bindText(st, 1, key);
        if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_text(st, 0)) v = @((const char *)sqlite3_column_text(st, 0));
        sqlite3_finalize(st);
    });
    return v;
}
- (void)setSetting:(NSString *)value forKey:(NSString *)key {
    if (!value) { [self run:@"DELETE FROM settings WHERE k=?" args:@[key]]; return; }   // nil = unset, no empty row
    dispatch_async(_q, ^{
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, "INSERT OR REPLACE INTO settings (k,v) VALUES (?,?)", -1, &st, NULL) != SQLITE_OK) return;
        bindText(st, 1, key); bindText(st, 2, value);
        sqlite3_step(st); sqlite3_finalize(st);
    });
}

- (id)cachedJSON:(NSString *)key maxAge:(NSTimeInterval)age {
    __block NSData *data = nil;
    dispatch_sync(_q, ^{   // only the read under the queue; parsing (up to ~1 MB) happens outside
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, "SELECT t,v FROM cache.jcache WHERE k=?", -1, &st, NULL) != SQLITE_OK) return;
        bindText(st, 1, key);
        if (sqlite3_step(st) == SQLITE_ROW && [NSDate date].timeIntervalSince1970 - sqlite3_column_double(st, 0) <= age) {
            const void *b = sqlite3_column_blob(st, 1);
            int n = sqlite3_column_bytes(st, 1);
            if (b && n) data = [NSData dataWithBytes:b length:n];
        }
        sqlite3_finalize(st);
    });
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}
- (void)cacheJSON:(id)obj forKey:(NSString *)key {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!d) return;
    double now = [NSDate date].timeIntervalSince1970;
    dispatch_async(_q, ^{
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, "INSERT OR REPLACE INTO cache.jcache (k,t,v) VALUES (?,?,?)", -1, &st, NULL) != SQLITE_OK) return;
        bindText(st, 1, key);
        sqlite3_bind_double(st, 2, now);
        sqlite3_bind_blob(st, 3, d.bytes, (int)d.length, SQLITE_TRANSIENT);
        sqlite3_step(st); sqlite3_finalize(st);
    });
}

#pragma mark Generic

static void bindAny(sqlite3_stmt *st, int idx, id v) {
    if ([v isKindOfClass:[NSString class]]) sqlite3_bind_text(st, idx, [v UTF8String], -1, SQLITE_TRANSIENT);
    else if ([v isKindOfClass:[NSNumber class]]) {
        const char *t = [v objCType];
        if (strcmp(t, @encode(double)) == 0 || strcmp(t, @encode(float)) == 0) sqlite3_bind_double(st, idx, [v doubleValue]);
        else sqlite3_bind_int64(st, idx, [v longLongValue]);
    }
    else if ([v isKindOfClass:[NSData class]]) sqlite3_bind_blob(st, idx, [v bytes], (int)[v length], SQLITE_TRANSIENT);
    else sqlite3_bind_null(st, idx);
}

- (void)runNow:(NSString *)sql args:(NSArray *)args {
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(_db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) { _errors++; SFLog(@"store: %@ -> %s", sql, sqlite3_errmsg(_db)); return; }
    for (NSUInteger i = 0; i < args.count; i++) bindAny(st, (int)i + 1, args[i]);
    if (sqlite3_step(st) != SQLITE_DONE) { _errors++; SFLog(@"store: %@ -> %s", sql, sqlite3_errmsg(_db)); }
    sqlite3_finalize(st);
}

- (void)run:(NSString *)sql args:(NSArray *)args {
    dispatch_async(_q, ^{ [self runNow:sql args:args]; });
}

- (void)runAll:(NSArray *)statements {
    if (!statements.count) return;
    dispatch_async(_q, ^{
        NSUInteger before = self->_errors;
        [self exec:@"BEGIN IMMEDIATE"];
        if (self->_errors != before) return;   // no transaction: write nothing rather than half
        for (NSArray *s in statements) {
            [self runNow:s[0] args:s.count > 1 ? s[1] : nil];
            if (self->_errors != before) break;
        }
        if (self->_errors != before) { [self exec:@"ROLLBACK"]; SFLog(@"store: %lu writes rolled back", (unsigned long)statements.count); }
        else [self exec:@"COMMIT"];
    });
}

- (NSArray *)rows:(NSString *)sql args:(NSArray *)args {
    __block NSArray *out;
    dispatch_sync(_q, ^{ out = [self rowsNow:sql args:args]; });
    return out;
}

- (NSArray *)rowsNow:(NSString *)sql args:(NSArray *)args {   // on _q (or during init)
    NSMutableArray *out = [NSMutableArray new];
    {
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) { SFLog(@"store: %@ -> %s", sql, sqlite3_errmsg(self->_db)); return out; }
        for (NSUInteger i = 0; i < args.count; i++) bindAny(st, (int)i + 1, args[i]);
        int n = sqlite3_column_count(st);
        while (sqlite3_step(st) == SQLITE_ROW) {
            NSMutableDictionary *r = [NSMutableDictionary new];
            for (int c = 0; c < n; c++) {
                NSString *k = @(sqlite3_column_name(st, c));
                switch (sqlite3_column_type(st, c)) {
                    case SQLITE_INTEGER: r[k] = @(sqlite3_column_int64(st, c)); break;
                    case SQLITE_FLOAT: r[k] = @(sqlite3_column_double(st, c)); break;
                    case SQLITE_TEXT: r[k] = @((const char *)sqlite3_column_text(st, c)); break;
                    case SQLITE_BLOB: r[k] = [NSData dataWithBytes:sqlite3_column_blob(st, c) length:sqlite3_column_bytes(st, c)]; break;
                    default: break;
                }
            }
            [out addObject:r];
        }
        sqlite3_finalize(st);
    }
    return out;
}

// Migration: put progress under a new identity (incl. the stored item, "updated" stays)
#pragma mark Items

// What the items table keeps of an item: its metadata as the source gives it
static NSString *sharedJSON(SFItem *item) {
    NSMutableDictionary *d = [[item dictionaryRepresentation] mutableCopy];
    [d removeObjectForKey:@"localPath"];
    for (NSString *k in @[@"url", @"image", @"backdrop"])
        if ([d[k] hasPrefix:@"/"] || [d[k] hasPrefix:@"file:"]) [d removeObjectForKey:k];
    return SFJSONString(d);
}

- (NSArray *)itemWrite:(SFItem *)item {
    NSString *js = item.identifier ? sharedJSON(item) : nil;
    if (!js) return nil;
    return @[@"INSERT INTO items (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = json_patch(json, excluded.json)", @[item.identifier, js]];
}

- (NSString *)saveItem:(SFItem *)item {
    NSArray *w = [self itemWrite:item];
    if (w) [self run:w[0] args:w[1]];
    return w[1][1];
}

// items nothing references any more (left a follow's list, removed from the history, ...)
- (void)pruneItemsNow {
    [self runNow:@"DELETE FROM items WHERE id NOT IN (SELECT id FROM progress UNION ALL SELECT id FROM downloads "
                  "UNION ALL SELECT id FROM watch_later UNION ALL SELECT id FROM follow_items)" args:nil];
}

- (BOOL)moveProgress:(NSString *)from toItem:(SFItem *)item {
    NSString *to = item.identifier;
    if (!from || !to || [from isEqualToString:to]) return NO;
    @synchronized (_progressCache) {
        NSArray *a = _progressCache[from];
        if (!a || _progressCache[to]) return NO;
        _progressCache[to] = a;
        [_progressCache removeObjectForKey:from];
    }
    NSArray *iw = [self itemWrite:item];
    NSString *src = item.source ?: @"";
    dispatch_async(_q, ^{
        if (iw) [self runNow:iw[0] args:iw[1]];
        [self runNow:@"UPDATE OR IGNORE progress SET id=?, source=? WHERE id=?" args:@[to, src, from]];
    });
    return YES;
}
@end
