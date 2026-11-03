#import "SFStore.h"
#import <sqlite3.h>

// Dev-Instanzen haben eigenen Fortschritt (dev_progress) – Tests dürfen nie "Weiterschauen"/"gesehen" der echten App verändern
NSString *SFProgressTable(void) { return SFDevMode ? @"dev_progress" : @"progress"; }
static NSString *P(NSString *sql) { return SFDevMode ? [sql stringByReplacingOccurrencesOfString:@" progress" withString:@" dev_progress"] : sql; }

@implementation SFStore {
    sqlite3 *_db;
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
        NSString *p = [SFAppSupportDir() stringByAppendingPathComponent:@"sofa.db"];
        if (sqlite3_open(p.fileSystemRepresentation, &_db) != SQLITE_OK) {
            SFLog(@"store: open failed %s", sqlite3_errmsg(_db));
        }
        [self exec:@"PRAGMA journal_mode=WAL"];
        [self exec:@"PRAGMA synchronous=NORMAL"];
        [self exec:P(@"CREATE TABLE IF NOT EXISTS progress (id TEXT PRIMARY KEY, pos REAL, dur REAL, watched INTEGER DEFAULT 0, updated REAL, source TEXT, item TEXT)")];
        [self exec:P(@"CREATE INDEX IF NOT EXISTS progress_updated ON progress(updated)")];
        [self exec:@"CREATE TABLE IF NOT EXISTS settings (k TEXT PRIMARY KEY, v TEXT)"];
        [self exec:@"CREATE TABLE IF NOT EXISTS jcache (k TEXT PRIMARY KEY, t REAL, v BLOB)"];
        [self loadProgress];
    }
    return self;
}

- (void)exec:(NSString *)sql {
    char *err = NULL;
    if (sqlite3_exec(_db, sql.UTF8String, NULL, NULL, &err) != SQLITE_OK) {
        SFLog(@"store: %@ -> %s", sql, err);
        sqlite3_free(err);
    }
}

- (void)loadProgress {
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(_db, P(@"SELECT id,pos,dur,watched FROM progress").UTF8String, -1, &st, NULL) != SQLITE_OK) return;
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

- (NSString *)json:(SFItem *)item {
    NSData *d = [NSJSONSerialization dataWithJSONObject:[item dictionaryRepresentation] options:0 error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}

- (void)write:(SFItem *)item pos:(double)pos dur:(double)dur watched:(BOOL)w {
    if (!item.identifier) return;
    @synchronized (_progressCache) { _progressCache[item.identifier] = @[@(pos), @(dur), @(w)]; }
    NSString *js = [self json:item];
    NSString *ident = item.identifier, *src = item.source;
    double now = [NSDate date].timeIntervalSince1970;
    dispatch_async(_q, ^{
        sqlite3_stmt *st;
        const char *sql = P(@"INSERT OR REPLACE INTO progress (id,pos,dur,watched,updated,source,item) VALUES (?,?,?,?,?,?,?)").UTF8String;
        if (sqlite3_prepare_v2(self->_db, sql, -1, &st, NULL) != SQLITE_OK) return;
        bindText(st, 1, ident);
        sqlite3_bind_double(st, 2, pos);
        sqlite3_bind_double(st, 3, dur);
        sqlite3_bind_int(st, 4, w);
        sqlite3_bind_double(st, 5, now);
        bindText(st, 6, src);
        bindText(st, 7, js);
        sqlite3_step(st);
        sqlite3_finalize(st);
    });
}

- (void)savePosition:(NSTimeInterval)pos duration:(NSTimeInterval)dur forItem:(SFItem *)item {
    if (item.kind == SFItemLive) return;
    BOOL w = dur > 0 && (pos >= dur * 0.94 || dur - pos < MIN(30, dur * 0.1));
    if (w == NO && [self watched:item.identifier] && pos < 30) return;   // Wiederansehen: Status behalten
    if (pos < 10 && !w) {   // kaum angesehen: nur Verlauf ohne Position
        pos = 0;
    }
    BOOL old = [self watched:item.identifier];
    [self write:item pos:w ? 0 : pos dur:dur watched:(w || old)];
}

- (void)flush { dispatch_sync(_q, ^{}); }

- (void)setWatched:(BOOL)w forItem:(SFItem *)item {
    [self write:item pos:0 dur:item.duration watched:w];
}

- (NSArray *)query:(NSString *)where limit:(NSInteger)limit source:(NSString *)source {
    __block NSMutableArray *out = [NSMutableArray new];
    dispatch_sync(_q, ^{
        NSString *sql = [NSString stringWithFormat:P(@"SELECT item,pos,dur FROM progress WHERE %@ %@ ORDER BY updated DESC LIMIT %ld"),
                         where, source ? @"AND source=?" : @"", (long)limit];
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) return;
        if (source) bindText(st, 1, source);
        while (sqlite3_step(st) == SQLITE_ROW) {
            const char *t = (const char *)sqlite3_column_text(st, 0);
            if (!t) continue;
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:t length:strlen(t)] options:0 error:nil];
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            SFItem *i = [SFItem itemWithDictionary:d];
            if (i.localPath && ![[NSFileManager defaultManager] fileExistsAtPath:i.localPath] && !i.resolverRef) continue;
            [out addObject:i];
        }
        sqlite3_finalize(st);
    });
    return out;
}

- (NSArray *)continueWatching:(NSInteger)limit source:(NSString *)source {
    return [self query:@"watched=0 AND pos>0" limit:limit source:source];
}
- (NSArray *)recentlyPlayed:(NSInteger)limit source:(NSString *)source {
    return [self query:@"1=1" limit:limit source:source];
}
// Verlauf: zuletzt abgespielte Inhalte mit Zeitpunkt (@{item, updated, watched, pos})
- (NSArray *)history:(NSInteger)limit {
    NSMutableArray *out = [NSMutableArray new];
    dispatch_sync(_q, ^{
        sqlite3_stmt *st;
        NSString *sql = [NSString stringWithFormat:P(@"SELECT item,updated,watched,pos FROM progress ORDER BY updated DESC LIMIT %ld"), (long)limit];
        if (sqlite3_prepare_v2(self->_db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) return;
        while (sqlite3_step(st) == SQLITE_ROW) {
            const char *t = (const char *)sqlite3_column_text(st, 0);
            if (!t) continue;
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:t length:strlen(t)] options:0 error:nil];
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            SFItem *i = [SFItem itemWithDictionary:d];
            if (i.localPath && ![[NSFileManager defaultManager] fileExistsAtPath:i.localPath] && !i.resolverRef) continue;
            [out addObject:@{@"item": i, @"updated": @(sqlite3_column_double(st, 1)), @"watched": @(sqlite3_column_int(st, 2)), @"pos": @(sqlite3_column_double(st, 3))}];
        }
        sqlite3_finalize(st);
    });
    return out;
}

- (void)removeFromContinue:(NSString *)identifier {
    @synchronized (_progressCache) {
        NSArray *a = _progressCache[identifier];
        if (a) _progressCache[identifier] = @[@0, a[1], a[2]];
    }
    dispatch_async(_q, ^{
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, P(@"UPDATE progress SET pos=0 WHERE id=?").UTF8String, -1, &st, NULL) != SQLITE_OK) return;
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
    dispatch_async(_q, ^{
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, "INSERT OR REPLACE INTO settings (k,v) VALUES (?,?)", -1, &st, NULL) != SQLITE_OK) return;
        bindText(st, 1, key); bindText(st, 2, value);
        sqlite3_step(st); sqlite3_finalize(st);
    });
}

- (id)cachedJSON:(NSString *)key maxAge:(NSTimeInterval)age {
    __block id obj = nil;
    dispatch_sync(_q, ^{
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, "SELECT t,v FROM jcache WHERE k=?", -1, &st, NULL) != SQLITE_OK) return;
        bindText(st, 1, key);
        if (sqlite3_step(st) == SQLITE_ROW) {
            double t = sqlite3_column_double(st, 0);
            if ([NSDate date].timeIntervalSince1970 - t <= age) {
                const void *b = sqlite3_column_blob(st, 1);
                int n = sqlite3_column_bytes(st, 1);
                if (b && n) obj = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:b length:n] options:0 error:nil];
            }
        }
        sqlite3_finalize(st);
    });
    return obj;
}
- (void)cacheJSON:(id)obj forKey:(NSString *)key {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!d) return;
    double now = [NSDate date].timeIntervalSince1970;
    dispatch_async(_q, ^{
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, "INSERT OR REPLACE INTO jcache (k,t,v) VALUES (?,?,?)", -1, &st, NULL) != SQLITE_OK) return;
        bindText(st, 1, key);
        sqlite3_bind_double(st, 2, now);
        sqlite3_bind_blob(st, 3, d.bytes, (int)d.length, SQLITE_TRANSIENT);
        sqlite3_step(st); sqlite3_finalize(st);
    });
}

#pragma mark Generisch

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
    if (sqlite3_prepare_v2(_db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) { SFLog(@"store: %@ -> %s", sql, sqlite3_errmsg(_db)); return; }
    for (NSUInteger i = 0; i < args.count; i++) bindAny(st, (int)i + 1, args[i]);
    if (sqlite3_step(st) != SQLITE_DONE) SFLog(@"store: %@ -> %s", sql, sqlite3_errmsg(_db));
    sqlite3_finalize(st);
}

- (void)run:(NSString *)sql args:(NSArray *)args {
    dispatch_async(_q, ^{ [self runNow:sql args:args]; });
}

- (NSArray *)rows:(NSString *)sql args:(NSArray *)args {
    NSMutableArray *out = [NSMutableArray new];
    dispatch_sync(_q, ^{
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(self->_db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) { SFLog(@"store: %@ -> %s", sql, sqlite3_errmsg(self->_db)); return; }
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
    });
    return out;
}

// Migration: Fortschritt unter neue Identität stellen (inkl. gespeichertem Item, "updated" bleibt)
- (BOOL)moveProgress:(NSString *)from toItem:(SFItem *)item {
    NSString *to = item.identifier;
    if (!from || !to || [from isEqualToString:to]) return NO;
    @synchronized (_progressCache) {
        NSArray *a = _progressCache[from];
        if (!a || _progressCache[to]) return NO;
        _progressCache[to] = a;
        [_progressCache removeObjectForKey:from];
    }
    NSString *js = [self json:item];
    NSString *src = item.source ?: @"";
    dispatch_async(_q, ^{ [self runNow:P(@"UPDATE OR IGNORE progress SET id=?, item=?, source=? WHERE id=?") args:@[to, js ?: @"{}", src, from]]; });
    return YES;
}
@end
