#import "SFWatchLater.h"
#import "SFStore.h"
#import "SFLibrary.h"


@implementation SFWatchLater {
    NSMutableArray *_entries;   // @{id, source, item(SFItem), added}, newest first
}

+ (instancetype)shared {
    static SFWatchLater *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFWatchLater new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        SFStore *st = [SFStore shared];
        _entries = [NSMutableArray new];
        for (NSDictionary *r in [st rows:@"SELECT w.source, w.added, i.json AS item FROM watch_later w JOIN items i ON i.id = w.id ORDER BY added DESC" args:nil]) {
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[r[@"item"] ?: @"{}" dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            SFItem *it = [d isKindOfClass:[NSDictionary class]] ? [SFItem itemWithDictionary:d] : nil;
            if (!it.identifier.length) continue;
            [_entries addObject:@{@"id": it.identifier, @"source": r[@"source"] ?: @"", @"item": it, @"added": r[@"added"] ?: @0}];
        }
    }
    return self;
}

- (void)changed {
    [[NSNotificationCenter defaultCenter] postNotificationName:SFLibraryDidChangeNotification object:nil];   // reload shelves
}

- (BOOL)contains:(NSString *)identifier {
    if (!identifier) return NO;
    for (NSDictionary *e in _entries) if ([e[@"id"] isEqualToString:identifier]) return YES;
    return NO;
}

- (BOOL)insert:(SFItem *)item at:(NSTimeInterval)added {
    if (!item.identifier.length || [self contains:item.identifier]) return NO;
    SFItem *c = [item copy];
    c.style = SFTileStyleLandscape;   // uniform in the shelf, wherever it was saved from
    NSArray *iw = [[SFStore shared] itemWrite:c];
    if (!iw) return NO;
    NSString *src = c.source ?: @"";
    [[SFStore shared] runAll:@[iw, @[@"INSERT OR REPLACE INTO watch_later (id, source, added) VALUES (?, ?, ?)", @[c.identifier, src, @(added)]]]];
    NSDictionary *e = @{@"id": c.identifier, @"source": src, @"item": c, @"added": @(added)};
    NSUInteger at = 0;
    while (at < _entries.count && [_entries[at][@"added"] doubleValue] > added) at++;
    [_entries insertObject:e atIndex:at];
    return YES;
}

- (void)add:(SFItem *)item {
    if ([self insert:item at:[NSDate date].timeIntervalSince1970]) {
        SFLog(@"watch later: + %@", item.identifier);
        [self changed];
    }
}

- (void)remove:(NSString *)identifier {
    if (!identifier) return;
    NSUInteger n = _entries.count;
    [_entries filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *e, NSDictionary *b) { return ![e[@"id"] isEqualToString:identifier]; }]];
    if (_entries.count == n) return;
    [[SFStore shared] run:@"DELETE FROM watch_later WHERE id = ?" args:@[identifier]];
    SFLog(@"watch later: − %@", identifier);
    [self changed];
}

- (NSArray *)items:(NSString *)source {
    NSMutableArray *out = [NSMutableArray new], *drop = [NSMutableArray new];
    NSMutableIndexSet *watched = [NSMutableIndexSet new];
    SFStore *st = [SFStore shared];
    [_entries enumerateObjectsUsingBlock:^(NSDictionary *e, NSUInteger i, BOOL *stop) {
        if ([st progressFor:e[@"id"]] >= 1) {   // watched: drops out
            [watched addIndex:i];
            [drop addObject:@[@"DELETE FROM watch_later WHERE id = ?", @[e[@"id"]]]];
            return;
        }
        if (source && ![e[@"source"] isEqualToString:source]) return;
        [out addObject:[e[@"item"] copy]];
    }];
    [_entries removeObjectsAtIndexes:watched];   // cleaned up silently (without triggering a reload)
    [st runAll:drop];
    return out;
}

@end

SFPageLoader SFWithWatchLater(SFPageLoader loader, NSString *source) {
    return ^(SFPageDone done) {
        loader(^(SFPage *page, NSError *err) {
            NSArray *later = [[SFWatchLater shared] items:source];
            if (!later.count) { done(page, err); return; }
            SFPage *p = page ?: [SFPage page:nil theme:source shelves:@[]];
            NSMutableArray *sh = [p.shelves mutableCopy] ?: [NSMutableArray new];
            NSUInteger at = sh.count ? 1 : 0;   // the app opens on its own content
            for (NSUInteger k = 0; k < sh.count; k++) if ([[sh[k] title] isEqualToString:@"Weiterschauen"]) at = k + 1;
            [sh insertObject:[SFShelf shelf:@"Später ansehen" style:SFTileStyleLandscape items:later] atIndex:MIN(at, sh.count)];
            p.shelves = sh;
            done(p, page ? err : nil);
        });
    };
}
