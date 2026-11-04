#import "SFFollows.h"
#import "SFStore.h"
#import "SFDownloads.h"
#import "SFNet.h"

NSString *const SFFollowsDidChangeNotification = @"SFFollowsDidChange";

static NSMutableDictionary *gPages;
void SFRegisterShowPage(NSString *prefix, SFShowPageFactory f) { if (!gPages) gPages = [NSMutableDictionary new]; gPages[prefix] = [f copy]; }
static NSMutableDictionary *gLookups;
void SFRegisterShowRefLookup(NSString *source, SFShowRefLookup f) { if (!gLookups) gLookups = [NSMutableDictionary new]; gLookups[source] = [f copy]; }
SFShowRefLookup SFShowRefLookupFor(NSString *source) { return source ? gLookups[source] : nil; }
SFPageLoader SFShowPageLoader(NSString *ref, NSString *title) {
    NSRange r = [ref rangeOfString:@":"];
    if (r.location == NSNotFound || NSMaxRange(r) >= ref.length) return nil;
    SFShowPageFactory f = gPages[[ref substringToIndex:r.location]];
    return f ? f([ref substringFromIndex:NSMaxRange(r)], title) : nil;
}
static NSString *prefixOf(NSString *s) { NSRange r = [s rangeOfString:@":"]; return r.location == NSNotFound ? nil : [s substringToIndex:r.location]; }
static NSString *restOf(NSString *s) { NSRange r = [s rangeOfString:@":"]; return r.location == NSNotFound ? s : [s substringFromIndex:NSMaxRange(r)]; }


static const NSInteger kPerShow = 12;              // so viele neueste Folgen je Sendung merken
static const NSTimeInterval kRefresh = 30 * 60;

@implementation SFFollows {
    NSMutableDictionary *_follows;   // id -> @{id, source, title, image, added}
    NSMutableDictionary *_items;     // id -> NSArray<SFItem> (neueste zuerst)
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
        [st run:@"CREATE TABLE IF NOT EXISTS follows (id TEXT PRIMARY KEY, source TEXT, title TEXT, image TEXT, added REAL)" args:nil];
        [st run:@"CREATE TABLE IF NOT EXISTS follow_items (follow TEXT, id TEXT, item TEXT, date REAL, PRIMARY KEY(follow, id))" args:nil];
        _follows = [NSMutableDictionary new];
        _items = [NSMutableDictionary new];
        for (NSDictionary *r in [st rows:@"SELECT * FROM follows" args:nil]) _follows[r[@"id"]] = [r mutableCopy];
        for (NSDictionary *r in [st rows:@"SELECT follow, item FROM follow_items ORDER BY date DESC" args:nil]) {
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[r[@"item"] ?: @"{}" dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSMutableArray *a = _items[r[@"follow"]] ?: [NSMutableArray new];
            [a addObject:[SFItem itemWithDictionary:d]];
            _items[r[@"follow"]] = a;
        }
        SFLog(@"follows: %lu Sendungen/Kanäle", (unsigned long)_follows.count);
    }
    return self;
}

- (void)changed {
    SFMain(^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SFFollowsDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SFLibraryDidChange" object:nil];   // Home/App-Seiten neu (gleiche Beobachter)
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
    // Einmalig: alle „Automatisch laden“-Abos (128 aus ytdl-sub) werden gefolgt – Download bleibt an
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
        SFLog(@"follows: %lu Abos übernommen", (unsigned long)n);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refreshNow]; });
    _timer = [NSTimer scheduledTimerWithTimeInterval:kRefresh target:self selector:@selector(refreshNow) userInfo:nil repeats:YES];
}

- (void)importFollows:(NSArray *)folders key:(NSString *)onceKey {
    SFStore *st = [SFStore shared];
    if (!folders.count || [st setting:onceKey]) return;
    NSUInteger n = 0;
    for (SFItem *f in folders) if ([self canFollow:f] && !_follows[f.identifier]) { [self addFollow:f]; n++; }
    [st setSetting:[@(n) stringValue] forKey:onceKey];
    SFLog(@"follows: %lu aus %@ übernommen", (unsigned long)n, onceKey);
    if (n) { [self changed]; [self refreshNow]; }
}

#pragma mark Folgen

- (BOOL)canFollow:(SFItem *)folder {
    NSString *p = prefixOf(folder.identifier);
    return folder.kind == SFItemFolder && p && gPages[p] && SFFeedFor(folder.identifier);
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
    [[SFStore shared] run:@"DELETE FROM follows WHERE id=?" args:@[identifier]];
    [[SFStore shared] run:@"DELETE FROM follow_items WHERE follow=?" args:@[identifier]];
    if ([[SFDownloads shared] isSubscribed:identifier]) [[SFDownloads shared] unsubscribe:identifier];   // Folgen ist Voraussetzung
    SFLog(@"follows: - %@", identifier);
    [self changed];
}

- (NSArray *)follows:(NSString *)source {
    NSMutableArray *out = [NSMutableArray new];
    for (NSDictionary *f in _follows.allValues) {
        if (source && ![f[@"source"] isEqualToString:source]) continue;
        SFShowPageFactory page = gPages[prefixOf(f[@"id"])];
        if (!page) continue;
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
        i.pageLoader = page(restOf(f[@"id"]), f[@"title"]);
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
        c.subtitle = [NSString stringWithFormat:@"%@ · %@", c.channel ?: @"", SFFormatDateShort(c.date)];
        [out addObject:c];
    }
    return out;
}

#pragma mark Aktualisieren (Hintergrund, nacheinander)

- (void)refreshOne:(NSDictionary *)f done:(dispatch_block_t)done {
    SFFeedFetcher feed = SFFeedFor(f[@"id"]);
    if (!feed) { if (done) done(); return; }
    __block BOOL finished = NO;
    dispatch_block_t finish = ^{ if (finished) return; finished = YES; if (done) done(); };
    feed(restOf(f[@"id"]), ^(NSArray *items, NSError *e) {
        SFMain(^{
            if (items && self->_follows[f[@"id"]]) {
                NSMutableArray *keep = [NSMutableArray new];
                for (SFItem *i in items) {
                    if (i.kind != SFItemVideo || !i.identifier) continue;
                    SFItem *c = [i copy];
                    c.channel = f[@"title"];   // einheitlich: Name, unter dem gefolgt wird
                    c.style = SFTileStyleLandscape;
                    [keep addObject:c];
                    if ((NSInteger)keep.count >= kPerShow) break;
                }
                self->_items[f[@"id"]] = keep;
                SFStore *st = [SFStore shared];
                [st run:@"DELETE FROM follow_items WHERE follow=?" args:@[f[@"id"]]];
                for (SFItem *c in keep) {
                    NSData *j = [NSJSONSerialization dataWithJSONObject:[c dictionaryRepresentation] options:0 error:nil];
                    [st run:@"INSERT OR REPLACE INTO follow_items (follow,id,item,date) VALUES (?,?,?,?)"
                       args:@[f[@"id"], c.identifier, j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}", @(c.date.timeIntervalSince1970)]];
                }
            }
            finish();
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), finish);   // Zeitlimit je Feed
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
            SFLog(@"follows: %lu aktualisiert in %.0fs", (unsigned long)all.count, -[t0 timeIntervalSinceNow]);
            [me changed];
            void (^n2)(void) = next; next = nil; (void)n2;
            return;
        }
        NSDictionary *f = all[i++];
        [me refreshOne:f done:^{
            if (i % 20 == 0) [me changed];   // Zwischenstand sichtbar machen
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (next) next(); });
        }];
    };
    next();
}
@end
