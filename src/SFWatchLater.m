#import "SFWatchLater.h"
#import "SFStore.h"
#import "SFLibrary.h"

// Dev-Instanzen: eigene Tabelle (nie die echte Liste anfassen)
static NSString *T(NSString *sql) {
    return SFDevMode ? [sql stringByReplacingOccurrencesOfString:@" watch_later" withString:@" dev_watch_later"] : sql;
}

@implementation SFWatchLater {
    NSMutableArray *_entries;   // @{id, source, item(SFItem), added}, neueste zuerst
}

+ (instancetype)shared {
    static SFWatchLater *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFWatchLater new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        SFStore *st = [SFStore shared];
        [st run:T(@"CREATE TABLE IF NOT EXISTS watch_later (id TEXT PRIMARY KEY, source TEXT, item TEXT, added REAL)") args:nil];
        _entries = [NSMutableArray new];
        for (NSDictionary *r in [st rows:T(@"SELECT * FROM watch_later ORDER BY added DESC") args:nil]) {
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[r[@"item"] ?: @"{}" dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            SFItem *it = [d isKindOfClass:[NSDictionary class]] ? [SFItem itemWithDictionary:d] : nil;
            if (!it.identifier.length) continue;
            [_entries addObject:@{@"id": it.identifier, @"source": r[@"source"] ?: @"", @"item": it, @"added": r[@"added"] ?: @0}];
        }
    }
    return self;
}

- (void)changed {
    [[NSNotificationCenter defaultCenter] postNotificationName:SFLibraryDidChangeNotification object:nil];   // Regale neu laden
}

- (BOOL)contains:(NSString *)identifier {
    if (!identifier) return NO;
    for (NSDictionary *e in _entries) if ([e[@"id"] isEqualToString:identifier]) return YES;
    return NO;
}

- (BOOL)insert:(SFItem *)item at:(NSTimeInterval)added {
    if (!item.identifier.length || [self contains:item.identifier]) return NO;
    SFItem *c = [item copy];
    c.style = SFTileStyleLandscape;   // einheitlich im Regal, egal woher gemerkt
    NSData *j = [NSJSONSerialization dataWithJSONObject:[c dictionaryRepresentation] options:0 error:nil];
    NSString *js = j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : nil;
    if (!js) return NO;
    NSString *src = c.source ?: @"";
    [[SFStore shared] run:T(@"INSERT OR REPLACE INTO watch_later (id, source, item, added) VALUES (?, ?, ?, ?)") args:@[c.identifier, src, js, @(added)]];
    NSDictionary *e = @{@"id": c.identifier, @"source": src, @"item": c, @"added": @(added)};
    NSUInteger at = 0;
    while (at < _entries.count && [_entries[at][@"added"] doubleValue] > added) at++;
    [_entries insertObject:e atIndex:at];
    return YES;
}

- (void)add:(SFItem *)item {
    if ([self insert:item at:[NSDate date].timeIntervalSince1970]) {
        SFLog(@"später ansehen: + %@", item.identifier);
        [self changed];
    }
}

- (void)remove:(NSString *)identifier {
    if (!identifier) return;
    NSUInteger n = _entries.count;
    [_entries filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *e, NSDictionary *b) { return ![e[@"id"] isEqualToString:identifier]; }]];
    if (_entries.count == n) return;
    [[SFStore shared] run:T(@"DELETE FROM watch_later WHERE id = ?") args:@[identifier]];
    SFLog(@"später ansehen: − %@", identifier);
    [self changed];
}

- (NSArray *)items:(NSString *)source {
    NSMutableArray *out = [NSMutableArray new], *seen = [NSMutableArray new];
    SFStore *st = [SFStore shared];
    for (NSDictionary *e in _entries) {
        if ([st progressFor:e[@"id"]] >= 1) { [seen addObject:e[@"id"]]; continue; }   // gesehen: fällt heraus
        if (source && ![e[@"source"] isEqualToString:source]) continue;
        [out addObject:[e[@"item"] copy]];
    }
    for (NSString *i in seen) {   // still aufräumen (ohne Neuladen auszulösen)
        [_entries filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *e, NSDictionary *b) { return ![e[@"id"] isEqualToString:i]; }]];
        [st run:T(@"DELETE FROM watch_later WHERE id = ?") args:@[i]];
    }
    return out;
}

- (void)importItems:(NSArray *)items once:(NSString *)key {
    if (!items.count || [[SFStore shared] setting:key].length) return;
    // Reihenfolge der Quelle beibehalten (oberstes = neuestes), zeitlich vor allem bereits Gemerkten
    NSTimeInterval base = _entries.count ? [[_entries.lastObject objectForKey:@"added"] doubleValue] - 1 : [NSDate date].timeIntervalSince1970;
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < items.count; i++) {
        SFItem *it = items[i];
        if (it.kind != SFItemVideo) continue;
        if ([self insert:it at:base - i]) n++;
    }
    [[SFStore shared] setSetting:@"1" forKey:key];
    SFLog(@"später ansehen: %lu aus %@ übernommen", (unsigned long)n, key);
    if (n) [self changed];
}
@end

SFPageLoader SFWithWatchLater(SFPageLoader loader, NSString *source) {
    return ^(SFPageDone done) {
        loader(^(SFPage *page, NSError *err) {
            NSArray *later = [[SFWatchLater shared] items:source];
            if (!later.count) { done(page, err); return; }
            SFPage *p = page ?: [SFPage page:nil theme:source shelves:@[]];
            NSMutableArray *sh = [p.shelves mutableCopy] ?: [NSMutableArray new];
            NSUInteger at = sh.count ? 1 : 0;   // die App öffnet auf ihren eigenen Inhalten
            for (NSUInteger k = 0; k < sh.count; k++) if ([[sh[k] title] isEqualToString:@"Weiterschauen"]) at = k + 1;
            [sh insertObject:[SFShelf shelf:@"Später ansehen" style:SFTileStyleLandscape items:later] atIndex:MIN(at, sh.count)];
            p.shelves = sh;
            done(p, page ? err : nil);
        });
    };
}
