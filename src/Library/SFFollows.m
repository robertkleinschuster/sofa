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
    NSMutableDictionary *_follows;   // id -> SFFollow
    NSMutableDictionary *_items;     // id -> NSArray<SFItem> (newest first)
    BOOL _started;
    NSTimer *_timer;                 // the next planned check (SFRefreshPlan)
    NSMutableDictionary *_jitter;    // id -> r of its current plan (drawn at each check)
    NSDate *_lastCheck;              // of any follow: the gap before the next one
    // readiness: the follows and their items read (1581 items parsed on a cold disk took ~100 ms of
    // the launching main thread, 2026-11-08) - on a queue at init; every public method waits for it
    // once (at once afterwards), start plans after it; all other access stays on the main thread
    dispatch_group_t _loaded;
}

+ (instancetype)shared {
    static SFFollows *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFFollows new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _loaded = dispatch_group_create();
        dispatch_group_async(_loaded, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            SFStore *st = [SFStore shared];
            NSMutableDictionary *follows = [NSMutableDictionary new], *items = [NSMutableDictionary new];
            for (NSDictionary *row in [st rows:@"SELECT * FROM follows" args:nil]) {
                SFFollow *f = [SFFollow followWithRow:row];
                if (f.identifier) follows[f.identifier] = f;
            }
            for (NSDictionary *r in [st rows:@"SELECT f.follow, i.json AS item FROM follow_items f JOIN items i ON i.id = f.id ORDER BY f.follow, f.pos" args:nil]) {
                NSDictionary *d = SFJSONParse(r[@"item"]);
                if (![d isKindOfClass:[NSDictionary class]]) continue;
                NSMutableArray *a = items[r[@"follow"]] ?: [NSMutableArray new];
                [a addObject:[SFItem itemWithDictionary:d]];
                items[r[@"follow"]] = a;
            }
            self->_follows = follows; self->_items = items;   // (the group's end publishes them)
            SFLog(@"follows: %lu shows/channels", (unsigned long)follows.count);
        });
    }
    return self;
}

- (void)changed {
    SFMain(^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SFFollowsDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SFLibraryDidChange" object:nil];   // reload Home/app pages (same observers)
    });
}

- (void)save:(SFFollow *)f {
    NSArray *w = f.writeStatement;
    [[SFStore shared] run:w[0] args:w[1]];
}

#pragma mark Start / Migration

- (void)ready { dispatch_group_wait(_loaded, DISPATCH_TIME_FOREVER); }

- (void)whenReady:(dispatch_block_t)block { dispatch_group_notify(_loaded, dispatch_get_main_queue(), block); }

- (void)start {
    dispatch_group_notify(_loaded, dispatch_get_main_queue(), ^{ [self startPlan]; });
}

- (void)startPlan {
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
- (NSArray *)itemsOf:(NSString *)identifier { [self ready]; return identifier ? [_items[identifier] copy] ?: @[] : @[]; }
- (BOOL)isFollowing:(NSString *)identifier { [self ready]; return identifier && _follows[identifier] != nil; }

- (void)addFollow:(SFItem *)folder {
    SFFollow *f = [SFFollow followOf:folder];
    _follows[f.identifier] = f;
    [self save:f];
}

- (SFFollow *)recordOf:(NSString *)identifier { [self ready]; return identifier ? [_follows[identifier] copy] : nil; }

- (void)adopt:(SFFollow *)record {
    [self ready];
    if (!record.identifier.length || _follows[record.identifier]) return;
    SFFollow *f = [record copy];
    f.checked = 0;   // its turn in the refresh plan comes first
    if (f.added <= 0) f.added = [NSDate date].timeIntervalSince1970;
    _follows[f.identifier] = f;
    [self save:f];
    SFLog(@"follows: + %@ (adopted)", f.title);
    [self changed];
}

- (void)follow:(SFItem *)folder {
    [self ready];
    if (![self canFollow:folder] || _follows[folder.identifier]) return;
    [self addFollow:folder];
    SFLog(@"follows: + %@", folder.title);
    [self changed];
    [self checkFollow:_follows[folder.identifier]];   // the viewer just chose it: its episodes now
}

- (void)unfollow:(NSString *)identifier {
    [self ready];
    if (!_follows[identifier]) return;
    [_follows removeObjectForKey:identifier];
    [_items removeObjectForKey:identifier];
    // one transaction: the follow and its items
    [[SFStore shared] runAll:@[@[@"DELETE FROM follows WHERE id=?", @[identifier]],
                               @[@"DELETE FROM follow_items WHERE follow=?", @[identifier]]]];
    SFLog(@"follows: - %@", identifier);
    [self changed];
}

// A follow's picture is usable when it is a URL or an existing file - the artwork of a download
// folder (poster.jpg, adopted from the old library) is gone once that folder was cleaned up.
static BOOL usable(NSString *img) {
    return img.length && (![img hasPrefix:@"/"] || [[NSFileManager defaultManager] fileExistsAtPath:img]);
}

- (BOOL)needsImage:(NSString *)identifier {
    [self ready];
    SFFollow *f = identifier ? _follows[identifier] : nil;
    return f && !usable(f.image);
}

// stored items of a source's follows without a channel picture get their follow's (http) one;
// a follow's local picture is a file of this Mac, not the channel's
static NSString *const kLendPictures = @"UPDATE items SET json = json_set(json, '$.channelImage', "
    "(SELECT image FROM follows WHERE id = json_extract(items.json, '$.showRef'))) "
    "WHERE json_extract(json, '$.channelImage') IS NULL "
    "AND json_extract(json, '$.showRef') IN (SELECT id FROM follows WHERE source = ? AND image LIKE 'http%')";

- (void)lendPicturesToItemsOf:(NSString *)source {
    if (!source.length) return;
    [self whenReady:^{ [[SFStore shared] run:kLendPictures args:@[source]]; }];
}

// A missing or gone picture: the show's app finds the current one (SFApp showImage, on its own
// budget) - written only when it changed.
- (void)renewImage:(NSString *)identifier {
    [self ready];
    if (![self needsImage:identifier]) return;
    Class<SFApp> app = [SFAppRegistry appForRef:identifier];
    if (![app respondsToSelector:@selector(showImage:done:)]) return;
    [app showImage:identifier done:^(NSString *url) {
        SFFollow *f = self->_follows[identifier];
        if (!f || !url.length || [f.image isEqualToString:url]) return;
        f.image = url;
        [self save:f];
        [self changed];
    }];
}

- (NSArray *)follows:(NSString *)source {
    [self ready];
    NSMutableArray *out = [NSMutableArray new];
    for (SFFollow *f in _follows.allValues) {
        if (source && ![f.source isEqualToString:source]) continue;
        SFPageLoader page = SFShowPageLoader(f.identifier, f.title);
        if (!page) continue;   // app gone/unknown namespace
        SFItem *i = [SFItem new];
        i.kind = SFItemFolder;
        i.identifier = f.identifier;
        i.title = f.title;
        i.source = f.source; i.themeName = f.source;
        NSArray *latest = _items[f.identifier];
        SFItem *newest = latest.firstObject;
        i.image = usable(f.image) ? f.image : newest.image;
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

// the newest n of the given lists, deduplicated, as labelled copies (pure: any thread)
static NSArray *SFFollowsLatest(NSArray *lists, NSInteger n) {
    NSMutableArray *all = [NSMutableArray new];
    for (NSArray *l in lists) [all addObjectsFromArray:l];
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

// on the main thread: the stored lists of a source's follows (immutable snapshots - a refresh
// replaces a list, it never changes one)
- (NSArray *)listsOf:(NSString *)source {
    NSMutableArray *lists = [NSMutableArray new];
    for (NSString *fid in _items) {
        SFFollow *f = _follows[fid];
        if (!f || (source && ![f.source isEqualToString:source])) continue;
        [lists addObject:[_items[fid] copy]];
    }
    return lists;
}

- (NSArray *)latest:(NSInteger)n source:(NSString *)source {
    [self ready];
    return SFFollowsLatest([self listsOf:source], n);
}

- (void)latest:(NSInteger)n source:(NSString *)source done:(void (^)(NSArray *items))done {
    [self whenReady:^{
        NSArray *lists = [self listsOf:source];
        SFBackground(^{
            NSArray *items = SFFollowsLatest(lists, n);
            dispatch_async(dispatch_get_main_queue(), ^{ done(items); });
        });
    }];
}

#pragma mark Refresh (background, one after another)

// A follow's items without what changes on every refresh (view counts): "nothing new" must not
// mean a rewrite. Stored counts update with the next real change; memory always has fresh ones.
// Whether a fresh list (same items, same order) brings new values (a renamed episode, a new
// picture). Only its own fields count: the stored items can hold more than a list gives (a
// description from the details page, an exact date from a download) - that is no change. View
// counts change all the time and are no change either.
// A picture URL without its query: YouTube thumbnails carry signing parameters (sqp, rs) that
// differ per request for the same picture.
static NSString *pictureOf(id url) {
    if (![url isKindOfClass:[NSString class]]) return nil;
    NSRange q = [url rangeOfString:@"?"];
    return q.location == NSNotFound ? url : [url substringToIndex:q.location];
}

// Same episodes, but something one sees changed: title, description, duration, channel, playback
// limits or the picture. Not: view counts (and the subtitle built from them), dates computed from
// "vor 3 Tagen" (a little different at every fetch), picture URL parameters - they made nearly
// every check an "update": a database write and a Home rebuild every ~30 s (2026-11-07).
static NSString *changedField(NSArray *fresh, NSArray *stored) {   // nil: nothing one sees changed
    static NSArray *seen;
    static dispatch_once_t once;
    // what a tile or the info panel shows (channelImage: the tile's avatar)
    dispatch_once(&once, ^{ seen = @[@"title", @"plot", @"duration", @"channel", @"channelImage", @"drm", @"geo"]; });
    for (NSUInteger n = 0; n < fresh.count; n++) {
        NSDictionary *a = fresh[n], *b = n < stored.count ? stored[n] : nil;
        for (NSString *k in seen) if (a[k] != b[k] && ![a[k] isEqual:b[k]]) return k;
        for (NSString *k in @[@"image", @"backdrop"]) {
            NSString *pa = pictureOf(a[k]), *pb = pictureOf(b[k]);
            if (pa != pb && ![pa isEqualToString:pb]) return k;
        }
    }
    return nil;
}

static BOOL hasCounts(NSArray *dicts) {
    for (NSDictionary *d in dicts) if ([d[@"views"] longLongValue] > 0) return YES;
    return NO;
}

- (void)refreshOne:(SFFollow *)f done:(dispatch_block_t)done {
    if (!SFHasFeed(f.identifier)) { if (done) done(); return; }
    __block BOOL finished = NO;
    dispatch_block_t finish = ^{ if (finished) return; finished = YES; if (done) done(); };
    SFFetchFeed(f.identifier, ^(NSArray *items, NSError *e) {
        SFMain(^{
            if (items && self->_follows[f.identifier]) {
                NSMutableArray *keep = [NSMutableArray new];
                NSMutableSet *seen = [NSMutableSet new];
                for (SFItem *i in items) {
                    if (i.kind != SFItemVideo || !i.identifier || [seen containsObject:i.identifier]) continue;
                    [seen addObject:i.identifier];
                    SFItem *c = [i copy];
                    c.channel = f.title;   // uniform: the name it is followed under
                    c.style = SFTileStyleLandscape;
                    [keep addObject:c];
                    if ((NSInteger)keep.count >= kPerShow) break;
                }
                NSArray *dicts = [keep valueForKey:@"dictionaryRepresentation"];
                NSArray *before = [self->_items[f.identifier] valueForKey:@"dictionaryRepresentation"];
                BOOL news = ![[dicts valueForKey:@"id"] isEqualToArray:[before valueForKey:@"id"]];   // new episodes/videos
                NSString *field = news ? nil : changedField(dicts, before);
                BOOL updated = field != nil;
                // counts first known (stored before the source had them): written once, so they
                // survive a restart; later count changes alone are not a change
                BOOL gainedCounts = !hasCounts(before) && hasCounts(dicts);
                self->_items[f.identifier] = keep;
                if (!news && !updated && !gainedCounts) { finish(); return; }   // most refreshes: nothing new, nothing to write
                NSMutableArray *writes = [NSMutableArray arrayWithObject:@[@"DELETE FROM follow_items WHERE follow=?", @[f.identifier]]];
                [keep enumerateObjectsUsingBlock:^(SFItem *c, NSUInteger n, BOOL *stop) {
                    NSArray *iw = [[SFStore shared] itemWrite:c];
                    if (!iw) return;
                    [writes addObject:iw];
                    [writes addObject:@[@"INSERT OR REPLACE INTO follow_items (follow,id,pos) VALUES (?,?,?)", @[f.identifier, c.identifier, @(n)]]];
                }];
                [[SFStore shared] runAll:writes];   // one transaction: never a half-written list
                if (!news && !updated) { finish(); return; }   // only the counts were stored
                [self changed];
                if (news) {
                    SFLog(@"follows: %@ has news", f.title);
                    [[NSNotificationCenter defaultCenter] postNotificationName:SFFollowsNewItemsNotification object:f.identifier];
                } else SFLog(@"follows: %@ updated (%@)", f.title, field);
            }
            finish();
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), finish);   // time limit per feed
}

// One follow at a time, each at its own time (SFRefreshPlan: its upload rhythm, variation, night),
// with a gap between any two - spread over the day instead of all follows every 30 min in a burst
// (until 2026-11-06: 135 requests within a minute, part of what made YouTube suspect a bot).
- (NSDate *)dueOf:(SFFollow *)f {
    double checked = f.checked;
    if (checked <= 0) return [NSDate distantPast];   // never checked: first in line
    if (!_jitter[f.identifier]) _jitter[f.identifier] = @(arc4random_uniform(1000) / 1000.0);
    NSArray *dates = [_items[f.identifier] valueForKey:@"date"];
    return SFRefreshNextDue([dates filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self != nil"]],
                            [NSDate dateWithTimeIntervalSince1970:checked], [_jitter[f.identifier] doubleValue], nil);
}

- (void)planNext {
    [_timer invalidate]; _timer = nil;
    SFFollow *next = nil; NSDate *due = nil;
    for (SFFollow *f in _follows.allValues) {
        if (!SFHasFeed(f.identifier)) continue;
        NSDate *d = [self dueOf:f];
        if (!due || [d compare:due] == NSOrderedAscending) { due = d; next = f; }
    }
    if (!next) return;
    static NSTimeInterval gapScale;   // tests shorten the gap (SOFA_FOLLOW_GAP: seconds instead of 20-40)
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gapScale = SFDevSeconds(@"SOFA_FOLLOW_GAP", SFRefreshGapMin) / SFRefreshGapMin; });
    NSDate *earliest = [_lastCheck dateByAddingTimeInterval:gapScale * SFRefreshGap(arc4random_uniform(1000) / 1000.0)];
    NSDate *when = [due laterDate:earliest];
    NSString *fid = next.identifier;
    _timer = [NSTimer scheduledTimerWithTimeInterval:MAX(1, when.timeIntervalSinceNow) target:self selector:@selector(checkDue:) userInfo:fid repeats:NO];
}

- (void)checkDue:(NSTimer *)t {
    SFFollow *f = _follows[t.userInfo];
    _timer = nil;
    if (!f) { [self planNext]; return; }
    if (![SFNet isOnline]) {   // offline: look again in a while (the plan stays)
        _timer = [NSTimer scheduledTimerWithTimeInterval:300 target:self selector:@selector(checkDue:) userInfo:t.userInfo repeats:NO];
        return;
    }
    // its source paused background requests (YouTube bot check): wait it out - a check now would
    // send nothing yet use up the follow's turn
    // (one timer: only this follow waits; planNext spaces the ones after it)
    NSTimeInterval paused = SFBackgroundPausedUntil(f.identifier) - [NSDate date].timeIntervalSince1970;
    if (paused > 0) {
        SFLog(@"follows: %@ waits %.0f s for its source's pause", f.title, paused);
        _timer = [NSTimer scheduledTimerWithTimeInterval:paused + 1 target:self selector:@selector(checkDue:) userInfo:t.userInfo repeats:NO];
        return;
    }
    [self checkFollow:f];
}

- (void)checkFollow:(SFFollow *)f {
    _lastCheck = [NSDate date];
    f.checked = _lastCheck.timeIntervalSince1970;
    [_jitter removeObjectForKey:f.identifier];   // a new variation for the next one
    [[SFStore shared] run:@"UPDATE follows SET checked=? WHERE id=?" args:@[@(f.checked), f.identifier]];
    __weak SFFollows *ws = self;
    [self refreshOne:f done:^{
        SFFollows *me = ws;
        [me renewImage:f.identifier];
        [me planNext];
    }];
}
@end

@implementation SFFollow

+ (instancetype)followWithRow:(NSDictionary *)row {
    SFFollow *f = [self new];
    f.identifier = [row[@"id"] length] ? row[@"id"] : nil;
    f.source = row[@"source"] ?: @"";
    f.title = row[@"title"] ?: @"";
    f.image = [row[@"image"] length] ? row[@"image"] : nil;
    f.added = [row[@"added"] doubleValue];
    f.checked = [row[@"checked"] doubleValue];
    return f;
}

+ (instancetype)followOf:(SFItem *)folder {
    SFFollow *f = [self new];
    f.identifier = folder.identifier;
    f.source = folder.source ?: @"";
    f.title = folder.title ?: @"";
    f.image = folder.image.length ? folder.image : nil;
    f.added = [NSDate date].timeIntervalSince1970;
    return f;
}

// an upsert: REPLACE would delete the row its follow items and auto-download refer to
static NSString *const kWriteFollow = @"INSERT INTO follows (id,source,title,image,added,checked) VALUES (?,?,?,?,?,?) "
    "ON CONFLICT(id) DO UPDATE SET source = excluded.source, title = excluded.title, image = excluded.image, "
    "added = excluded.added, checked = excluded.checked";

- (NSArray *)writeStatement {
    return @[kWriteFollow,
             @[_identifier, _source ?: @"", _title ?: @"", _image ?: [NSNull null],
               @(_added > 0 ? _added : [NSDate date].timeIntervalSince1970), _checked > 0 ? @(_checked) : [NSNull null]]];
}

- (id)copyWithZone:(NSZone *)zone {
    SFFollow *c = [[self class] new];
    c.identifier = _identifier; c.source = _source; c.title = _title; c.image = _image; c.added = _added; c.checked = _checked;
    return c;
}

@end
