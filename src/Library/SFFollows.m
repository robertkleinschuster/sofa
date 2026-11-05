#import "SFFollows.h"
#import "SFStore.h"
#import "SFDownloads.h"
#import "SFNet.h"

NSString *const SFFollowsDidChangeNotification = @"SFFollowsDidChange";

SFShowRefLookup SFShowRefLookupFor(NSString *source) {
    Class<SFApp> a = [SFAppRegistry appNamed:source];
    if (![a respondsToSelector:@selector(showRefForItem:done:)]) return nil;
    return ^(SFItem *item, void (^done)(NSString *)) { [a showRefForItem:item done:done]; };
}
// page of a show/channel ref ("zdfshow:…", "ytchannel:UC…") from its app
SFPageLoader SFShowPageLoader(NSString *ref, NSString *title) {
    if (![SFAppRegistry isShowRef:ref] || !SFRefID(ref).length) return nil;
    Class<SFApp> a = [SFAppRegistry appForRef:ref];
    return [a respondsToSelector:@selector(showPageLoader:title:)] ? [a showPageLoader:ref title:title] : nil;
}


static const NSInteger kPerShow = 12;              // keep this many newest episodes per show
static const NSTimeInterval kRefresh = 30 * 60;

@implementation SFFollows {
    NSMutableDictionary *_follows;   // id -> @{id, source, title, image, added}
    NSMutableDictionary *_items;     // id -> NSArray<SFItem> (newest first)
    BOOL _started, _refreshing;
    NSTimer *_timer;
}

+ (instancetype)shared {
    static SFFollows *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFFollows new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        SFStore *st = [SFStore shared];
        _follows = [NSMutableDictionary new];
        _items = [NSMutableDictionary new];
        for (NSDictionary *r in [st rows:@"SELECT * FROM follows" args:nil]) _follows[r[@"id"]] = [r mutableCopy];
        for (NSDictionary *r in [st rows:@"SELECT follow, item FROM follow_items ORDER BY follow, pos" args:nil]) {
            NSDictionary *d = SFJSONParse(r[@"item"]);
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSMutableArray *a = _items[r[@"follow"]] ?: [NSMutableArray new];
            [a addObject:[SFItem itemWithDictionary:d]];
            _items[r[@"follow"]] = a;
        }
        SFLog(@"follows: %lu shows/channels", (unsigned long)_follows.count);
    }
    return self;
}

- (void)changed {
    SFMain(^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SFFollowsDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SFLibraryDidChange" object:nil];   // reload Home/app pages (same observers)
    });
}

- (void)save:(NSDictionary *)f {
    [[SFStore shared] run:@"INSERT OR REPLACE INTO follows (id,source,title,image,added) VALUES (?,?,?,?,?)"
                     args:@[f[@"id"], f[@"source"] ?: @"", f[@"title"] ?: @"", f[@"image"] ?: [NSNull null], f[@"added"] ?: @([NSDate date].timeIntervalSince1970)]];
}

#pragma mark Start / Migration

- (void)start {
    if (_started) return;
    _started = YES;
    // One-time: all "Automatisch laden" subscriptions (128 from ytdl-sub) become follows – download stays on
    SFStore *st = [SFStore shared];
    if (![st setting:@"follows.migrated"]) {
        NSUInteger n = 0;
        for (NSDictionary *s in [[SFDownloads shared] subscriptions]) {
            if (_follows[s[@"id"]]) continue;
            NSMutableDictionary *f = [@{@"id": s[@"id"], @"source": s[@"source"] ?: @"", @"title": s[@"title"] ?: @"",
                                        @"added": @([NSDate date].timeIntervalSince1970)} mutableCopy];
            if ([s[@"image"] length]) f[@"image"] = s[@"image"];
            _follows[f[@"id"]] = f; [self save:f]; n++;
        }
        [st setSetting:[@(n) stringValue] forKey:@"follows.migrated"];
        SFLog(@"follows: adopted %lu subscriptions", (unsigned long)n);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refreshNow]; });
    _timer = [NSTimer scheduledTimerWithTimeInterval:kRefresh target:self selector:@selector(refreshNow) userInfo:nil repeats:YES];
}

#pragma mark Follows

- (BOOL)canFollow:(SFItem *)folder {
    return folder.kind == SFItemFolder && SFShowPageLoader(folder.identifier, nil) && SFHasFeed(folder.identifier);
}
- (BOOL)isFollowing:(NSString *)identifier { return identifier && _follows[identifier] != nil; }

- (void)addFollow:(SFItem *)folder {
    NSMutableDictionary *f = [@{@"id": folder.identifier, @"source": folder.source ?: @"", @"title": folder.title ?: @"",
                                @"added": @([NSDate date].timeIntervalSince1970)} mutableCopy];
    if (folder.image.length) f[@"image"] = folder.image;
    _follows[folder.identifier] = f;
    [self save:f];
}

- (void)follow:(SFItem *)folder {
    if (![self canFollow:folder] || _follows[folder.identifier]) return;
    [self addFollow:folder];
    SFLog(@"follows: + %@", folder.title);
    [self changed];
    [self refreshOne:_follows[folder.identifier] done:^{ [self changed]; }];
}

- (void)unfollow:(NSString *)identifier {
    if (!_follows[identifier]) return;
    [_follows removeObjectForKey:identifier];
    [_items removeObjectForKey:identifier];
    // one transaction: the follow, its items, its stored feed and its auto-download (following is
    // a prerequisite of auto-download)
    NSArray *writes = @[@[@"DELETE FROM follows WHERE id=?", @[identifier]],
                        @[@"DELETE FROM follow_items WHERE follow=?", @[identifier]],
                        @[@"DELETE FROM feed_cache WHERE id=?", @[identifier]]];
    [[SFStore shared] runAll:[writes arrayByAddingObjectsFromArray:[[SFDownloads shared] unsubscribeWrites:identifier]]];
    SFLog(@"follows: - %@", identifier);
    [self changed];
}

- (NSArray *)follows:(NSString *)source {
    NSMutableArray *out = [NSMutableArray new];
    for (NSDictionary *f in _follows.allValues) {
        if (source && ![f[@"source"] isEqualToString:source]) continue;
        SFPageLoader page = SFShowPageLoader(f[@"id"], f[@"title"]);
        if (!page) continue;   // app gone/unknown namespace
        SFItem *i = [SFItem new];
        i.kind = SFItemFolder;
        i.identifier = f[@"id"];
        i.title = f[@"title"];
        i.source = f[@"source"]; i.themeName = f[@"source"];
        NSArray *latest = _items[f[@"id"]];
        SFItem *newest = latest.firstObject;
        i.image = [f[@"image"] length] ? f[@"image"] : newest.image;
        i.backdrop = newest.backdrop ?: newest.image ?: i.image;
        i.date = newest.date;
        i.subtitle = newest ? [NSString stringWithFormat:@"Neueste Folge: %@", SFFormatDateShort(newest.date)] : nil;
        i.plot = newest.title ? [@"Neueste Folge: " stringByAppendingString:newest.title] : nil;
        i.pageLoader = page;
        [out addObject:i];
    }
    [out sortUsingComparator:^NSComparisonResult(SFItem *a, SFItem *b) { return [a.title localizedCaseInsensitiveCompare:b.title]; }];
    return out;
}

- (NSArray *)latest:(NSInteger)n source:(NSString *)source {
    NSMutableArray *all = [NSMutableArray new];
    for (NSString *fid in _items) {
        NSDictionary *f = _follows[fid];
        if (!f || (source && ![f[@"source"] isEqualToString:source])) continue;
        [all addObjectsFromArray:_items[fid]];
    }
    [all sortUsingComparator:^NSComparisonResult(SFItem *a, SFItem *b) {
        return [(b.date ?: [NSDate distantPast]) compare:(a.date ?: [NSDate distantPast])];
    }];
    NSMutableArray *out = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    for (SFItem *i in all) {
        if ((NSInteger)out.count >= n) break;
        if (!i.identifier || [seen containsObject:i.identifier]) continue;
        [seen addObject:i.identifier];
        SFItem *c = [i copy];
        c.subtitle = SFDotJoin(c.channel, SFFormatDateShort(c.date));
        [out addObject:c];
    }
    return out;
}

#pragma mark Refresh (background, one after another)

// A follow's items without what changes on every refresh (view counts): "nothing new" must not
// mean a rewrite. Stored counts update with the next real change; memory always has fresh ones.
static NSArray *stable(NSArray *dicts) {
    NSMutableArray *a = [NSMutableArray new];
    for (NSDictionary *d in dicts) { NSMutableDictionary *m = [d mutableCopy]; [m removeObjectForKey:@"views"]; [a addObject:m]; }
    return a;
}

- (void)refreshOne:(NSDictionary *)f done:(dispatch_block_t)done {
    if (!SFHasFeed(f[@"id"])) { if (done) done(); return; }
    __block BOOL finished = NO;
    dispatch_block_t finish = ^{ if (finished) return; finished = YES; if (done) done(); };
    SFFetchFeed(f[@"id"], ^(NSArray *items, NSError *e) {
        SFMain(^{
            if (items && self->_follows[f[@"id"]]) {
                NSMutableArray *keep = [NSMutableArray new];
                NSMutableSet *seen = [NSMutableSet new];
                for (SFItem *i in items) {
                    if (i.kind != SFItemVideo || !i.identifier || [seen containsObject:i.identifier]) continue;
                    [seen addObject:i.identifier];
                    SFItem *c = [i copy];
                    c.channel = f[@"title"];   // uniform: the name it is followed under
                    c.style = SFTileStyleLandscape;
                    [keep addObject:c];
                    if ((NSInteger)keep.count >= kPerShow) break;
                }
                NSArray *dicts = [keep valueForKey:@"dictionaryRepresentation"];
                BOOL same = [stable(dicts) isEqualToArray:stable([self->_items[f[@"id"]] valueForKey:@"dictionaryRepresentation"])];
                self->_items[f[@"id"]] = keep;
                if (same) { finish(); return; }   // most refreshes: nothing new, nothing to write
                NSMutableArray *writes = [NSMutableArray arrayWithObject:@[@"DELETE FROM follow_items WHERE follow=?", @[f[@"id"]]]];
                [keep enumerateObjectsUsingBlock:^(SFItem *c, NSUInteger n, BOOL *stop) {
                    [writes addObject:@[@"INSERT OR REPLACE INTO follow_items (follow,id,pos,item) VALUES (?,?,?,?)",
                                        @[f[@"id"], c.identifier, @(n), SFJSONString(dicts[n]) ?: @"{}"]]];
                }];
                [[SFStore shared] runAll:writes];   // one transaction: never a half-written list
            }
            finish();
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), finish);   // time limit per feed
}

- (void)refreshNow {
    if (_refreshing || ![SFNet isOnline] || !_follows.count) return;
    _refreshing = YES;
    NSArray *all = [_follows.allValues copy];
    NSDate *t0 = [NSDate date];
    __block NSUInteger i = 0;
    __block void (^next)(void);
    __weak SFFollows *ws = self;
    next = ^{
        SFFollows *me = ws;
        if (!me) return;
        if (i >= all.count) {
            me->_refreshing = NO;
            SFLog(@"follows: %lu refreshed in %.0fs", (unsigned long)all.count, -[t0 timeIntervalSinceNow]);
            [me changed];
            void (^n2)(void) = next; next = nil; (void)n2;
            return;
        }
        NSDictionary *f = all[i++];
        [me refreshOne:f done:^{
            if (i % 20 == 0) [me changed];   // make intermediate state visible
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (next) next(); });
        }];
    };
    next();
}
@end
