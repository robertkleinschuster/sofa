#import "SFFollows.h"
#import "SFRefreshPlan.h"
#import "SFStore.h"
#import "SFDownloads.h"
#import "SFNet.h"
#import "SFApp.h"

NSString *const SFFollowsDidChangeNotification = @"SFFollowsDidChange";
NSString *const SFFollowsNewItemsNotification = @"SFFollowsNewItems";

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

@implementation SFFollows {
    NSMutableDictionary *_follows;   // id -> @{id, source, title, image, added}
    NSMutableDictionary *_items;     // id -> NSArray<SFItem> (newest first)
    BOOL _started;
    NSTimer *_timer;                 // the next planned check (SFRefreshPlan)
    NSMutableDictionary *_jitter;    // id -> r of its current plan (drawn at each check)
    NSDate *_lastCheck;              // of any follow: the gap before the next one
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
        for (NSDictionary *r in [st rows:@"SELECT f.follow, i.json AS item FROM follow_items f JOIN items i ON i.id = f.id ORDER BY f.follow, f.pos" args:nil]) {
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
    [[SFStore shared] run:@"INSERT OR REPLACE INTO follows (id,source,title,image,added,checked) VALUES (?,?,?,?,?,?)"
                     args:@[f[@"id"], f[@"source"] ?: @"", f[@"title"] ?: @"", f[@"image"] ?: [NSNull null],
                            f[@"added"] ?: @([NSDate date].timeIntervalSince1970), f[@"checked"] ?: [NSNull null]]];
}

#pragma mark Start / Migration

- (void)start {
    if (_started) return;
    _started = YES;
    _jitter = [NSMutableDictionary new];
    _lastCheck = [NSDate date];   // the first check a gap after launch
    [self planNext];
}

#pragma mark Follows

- (BOOL)canFollow:(SFItem *)folder {
    return folder.kind == SFItemFolder && SFShowPageLoader(folder.identifier, nil) && SFHasFeed(folder.identifier);
}
- (NSArray *)itemsOf:(NSString *)identifier { return identifier ? [_items[identifier] copy] ?: @[] : @[]; }
- (BOOL)isFollowing:(NSString *)identifier { return identifier && _follows[identifier] != nil; }

- (void)addFollow:(SFItem *)folder {
    NSMutableDictionary *f = [@{@"id": folder.identifier, @"source": folder.source ?: @"", @"title": folder.title ?: @"",
                                @"added": @([NSDate date].timeIntervalSince1970)} mutableCopy];
    if (folder.image.length) f[@"image"] = folder.image;
    _follows[folder.identifier] = f;
    [self save:f];
}

- (NSDictionary *)recordOf:(NSString *)identifier { return identifier ? [_follows[identifier] copy] : nil; }

- (void)adopt:(NSDictionary *)record {
    if (![record[@"id"] length] || _follows[record[@"id"]]) return;
    NSMutableDictionary *f = [@{@"id": record[@"id"], @"source": record[@"source"] ?: @"", @"title": record[@"title"] ?: @"",
                                @"added": @([NSDate date].timeIntervalSince1970)} mutableCopy];
    if ([record[@"image"] length]) f[@"image"] = record[@"image"];
    _follows[f[@"id"]] = f;
    [self save:f];
    SFLog(@"follows: + %@ (adopted)", f[@"title"]);
    [self changed];
}

- (void)follow:(SFItem *)folder {
    if (![self canFollow:folder] || _follows[folder.identifier]) return;
    [self addFollow:folder];
    SFLog(@"follows: + %@", folder.title);
    [self changed];
    [self checkFollow:_follows[folder.identifier]];   // the viewer just chose it: its episodes now
}

- (void)unfollow:(NSString *)identifier {
    if (!_follows[identifier]) return;
    [_follows removeObjectForKey:identifier];
    [_items removeObjectForKey:identifier];
    // one transaction: the follow, its items and its auto-download (following is
    // a prerequisite of auto-download)
    NSArray *writes = @[@[@"DELETE FROM follows WHERE id=?", @[identifier]],
                        @[@"DELETE FROM follow_items WHERE follow=?", @[identifier]]];
    [[SFStore shared] runAll:[writes arrayByAddingObjectsFromArray:[[SFDownloads shared] unsubscribeWrites:identifier]]];
    SFLog(@"follows: - %@", identifier);
    [self changed];
}

// A follow's picture is usable when it is a URL or an existing file - the artwork of a download
// folder (poster.jpg, adopted from the old library) is gone once that folder was cleaned up.
static BOOL usable(NSString *img) {
    return img.length && (![img hasPrefix:@"/"] || [[NSFileManager defaultManager] fileExistsAtPath:img]);
}

- (BOOL)needsImage:(NSString *)identifier {
    NSDictionary *f = identifier ? _follows[identifier] : nil;
    return f && !usable(f[@"image"]);
}

// A missing or gone picture: the show's app finds the current one (SFApp showImage, on its own
// budget) - written only when it changed.
- (void)renewImage:(NSString *)identifier {
    if (![self needsImage:identifier]) return;
    Class<SFApp> app = [SFAppRegistry appForRef:identifier];
    if (![app respondsToSelector:@selector(showImage:done:)]) return;
    [app showImage:identifier done:^(NSString *url) {
        NSMutableDictionary *f = self->_follows[identifier];
        if (!f || !url.length || [f[@"image"] isEqualToString:url]) return;
        f[@"image"] = url;
        [self save:f];
        [self changed];
    }];
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
        i.image = usable(f[@"image"]) ? f[@"image"] : newest.image;
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
// Whether a fresh list (same items, same order) brings new values (a renamed episode, a new
// picture). Only its own fields count: the stored items can hold more than a list gives (a
// description from the details page, an exact date from a download) - that is no change. View
// counts change all the time and are no change either.
static BOOL bringsValues(NSArray *fresh, NSArray *stored) {
    for (NSUInteger n = 0; n < fresh.count; n++)
        for (NSString *k in fresh[n])
            if (![k isEqualToString:@"views"] && ![stored[n][k] isEqual:fresh[n][k]]) return YES;
    return NO;
}

static BOOL hasCounts(NSArray *dicts) {
    for (NSDictionary *d in dicts) if ([d[@"views"] longLongValue] > 0) return YES;
    return NO;
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
                NSArray *before = [self->_items[f[@"id"]] valueForKey:@"dictionaryRepresentation"];
                BOOL news = ![[dicts valueForKey:@"id"] isEqualToArray:[before valueForKey:@"id"]];   // new episodes/videos
                BOOL updated = !news && bringsValues(dicts, before);
                // counts first known (stored before the source had them): written once, so they
                // survive a restart; later count changes alone are not a change
                BOOL gainedCounts = !hasCounts(before) && hasCounts(dicts);
                self->_items[f[@"id"]] = keep;
                if (!news && !updated && !gainedCounts) { finish(); return; }   // most refreshes: nothing new, nothing to write
                NSMutableArray *writes = [NSMutableArray arrayWithObject:@[@"DELETE FROM follow_items WHERE follow=?", @[f[@"id"]]]];
                [keep enumerateObjectsUsingBlock:^(SFItem *c, NSUInteger n, BOOL *stop) {
                    NSArray *iw = [[SFStore shared] itemWrite:c];
                    if (!iw) return;
                    [writes addObject:iw];
                    [writes addObject:@[@"INSERT OR REPLACE INTO follow_items (follow,id,pos) VALUES (?,?,?)", @[f[@"id"], c.identifier, @(n)]]];
                }];
                [[SFStore shared] runAll:writes];   // one transaction: never a half-written list
                if (!news && !updated) { finish(); return; }   // only the counts were stored
                [self changed];
                if (news) {
                    SFLog(@"follows: %@ has news", f[@"title"]);
                    [[NSNotificationCenter defaultCenter] postNotificationName:SFFollowsNewItemsNotification object:f[@"id"]];
                } else SFLog(@"follows: %@ updated", f[@"title"]);
            }
            finish();
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), finish);   // time limit per feed
}

// One follow at a time, each at its own time (SFRefreshPlan: its upload rhythm, variation, night),
// with a gap between any two - spread over the day instead of all follows every 30 min in a burst
// (until 2026-11-06: 135 requests within a minute, part of what made YouTube suspect a bot).
- (NSDate *)dueOf:(NSDictionary *)f {
    double checked = [f[@"checked"] doubleValue];
    if (checked <= 0) return [NSDate distantPast];   // never checked: first in line
    if (!_jitter[f[@"id"]]) _jitter[f[@"id"]] = @(arc4random_uniform(1000) / 1000.0);
    NSArray *dates = [_items[f[@"id"]] valueForKey:@"date"];
    return SFRefreshNextDue([dates filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self != nil"]],
                            [NSDate dateWithTimeIntervalSince1970:checked], [_jitter[f[@"id"]] doubleValue], nil);
}

- (void)planNext {
    [_timer invalidate]; _timer = nil;
    NSDictionary *next = nil; NSDate *due = nil;
    for (NSDictionary *f in _follows.allValues) {
        if (!SFHasFeed(f[@"id"])) continue;
        NSDate *d = [self dueOf:f];
        if (!due || [d compare:due] == NSOrderedAscending) { due = d; next = f; }
    }
    if (!next) return;
    static NSTimeInterval gapScale;   // tests shorten the gap (SOFA_FOLLOW_GAP: seconds instead of 20-40)
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gapScale = SFDevSeconds(@"SOFA_FOLLOW_GAP", SFRefreshGapMin) / SFRefreshGapMin; });
    NSDate *earliest = [_lastCheck dateByAddingTimeInterval:gapScale * SFRefreshGap(arc4random_uniform(1000) / 1000.0)];
    NSDate *when = [due laterDate:earliest];
    NSString *fid = next[@"id"];
    _timer = [NSTimer scheduledTimerWithTimeInterval:MAX(1, when.timeIntervalSinceNow) target:self selector:@selector(checkDue:) userInfo:fid repeats:NO];
}

- (void)checkDue:(NSTimer *)t {
    NSMutableDictionary *f = _follows[t.userInfo];
    _timer = nil;
    if (!f) { [self planNext]; return; }
    if (![SFNet isOnline]) {   // offline: look again in a while (the plan stays)
        _timer = [NSTimer scheduledTimerWithTimeInterval:300 target:self selector:@selector(checkDue:) userInfo:t.userInfo repeats:NO];
        return;
    }
    // its source paused background requests (YouTube bot check): wait it out - a check now would
    // send nothing yet use up the follow's turn
    // (one timer: only this follow waits; planNext spaces the ones after it)
    NSTimeInterval paused = SFBackgroundPausedUntil(f[@"id"]) - [NSDate date].timeIntervalSince1970;
    if (paused > 0) {
        SFLog(@"follows: %@ waits %.0f s for its source's pause", f[@"title"], paused);
        _timer = [NSTimer scheduledTimerWithTimeInterval:paused + 1 target:self selector:@selector(checkDue:) userInfo:t.userInfo repeats:NO];
        return;
    }
    [self checkFollow:f];
}

- (void)checkFollow:(NSMutableDictionary *)f {
    _lastCheck = [NSDate date];
    f[@"checked"] = @(_lastCheck.timeIntervalSince1970);
    [_jitter removeObjectForKey:f[@"id"]];   // a new variation for the next one
    [[SFStore shared] run:@"UPDATE follows SET checked=? WHERE id=?" args:@[f[@"checked"], f[@"id"]]];
    __weak SFFollows *ws = self;
    [self refreshOne:f done:^{
        SFFollows *me = ws;
        [me renewImage:f[@"id"]];
        [me planNext];
    }];
}
@end
