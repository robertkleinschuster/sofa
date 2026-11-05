#import "SFHomeFeatures.h"
#import "SFApp.h"
#import "SFStore.h"
#import "SFNet.h"
#import "SFFollows.h"

NSString *const SFHomeTopicLive = @"live";
NSString *const SFHomeTopicNews = @"news";
NSString *const SFHomeTopicHighlights = @"highlights";
NSString *const SFHomeFeaturesDidChangeNotification = @"SFHomeFeaturesDidChange";

static NSString *const kStoreKey = @"home.features.v2";   // v2: per app, merged when shown
static const NSTimeInterval kRefreshEvery = 30 * 60;
static const NSTimeInterval kAppTimeout = 45;   // an app that never answers must not hold the others back

// per topic: how many items one app may place in the merged row, and the row's length
static NSUInteger perApp(NSString *topic) { return [topic isEqualToString:SFHomeTopicLive] ? 40 : 6; }
static const NSUInteger kKeepPerApp = 40;   // kept per app and topic (before filtering what can't play here)
static NSUInteger rowMax(NSString *topic) { return [topic isEqualToString:SFHomeTopicLive] ? 40 : [topic isEqualToString:SFHomeTopicNews] ? 18 : 24; }
// news is about time: each app's items newest first (the others keep the app's own order); merged
// round robin either way, so one broadcaster's clips of one programme don't fill the row
static BOOL byDate(NSString *topic) { return [topic isEqualToString:SFHomeTopicNews]; }

static BOOL featurable(SFItem *i) {
    return i.kind == SFItemVideo || (i.kind == SFItemFolder && [SFAppRegistry isShowRef:i.identifier]);
}

NSDictionary *SFHomeFeaturesFromPage(SFPage *page, NSUInteger highlightShelf) {
    if (!page) return nil;
    NSMutableArray *live = [NSMutableArray new], *top = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    for (SFShelf *sh in page.shelves)
        for (SFItem *i in sh.items)
            if (i.kind == SFItemLive && i.identifier && ![seen containsObject:i.identifier]) { [seen addObject:i.identifier]; [live addObject:i]; }
    if (highlightShelf < page.shelves.count)
        for (SFItem *i in [page.shelves[highlightShelf] items]) if (featurable(i)) [top addObject:i];
    return @{SFHomeTopicLive: live, SFHomeTopicHighlights: top};
}

NSArray *SFHomeFeaturesLeadVideos(SFPage *page) {
    for (SFShelf *sh in page.shelves) {
        NSMutableArray *v = [NSMutableArray new];
        for (SFItem *i in sh.items) if (i.kind == SFItemVideo) [v addObject:i];
        if (v.count) return v;
    }
    return nil;
}

@implementation SFHomeFeatures {
    NSDictionary *_lists;       // topic -> app identifier -> SFItems in the app's order (merged only when shown)
    BOOL _refreshing;
    NSTimer *_timer, *_boundary;
    NSDate *_lastRefresh;
}

+ (instancetype)shared {
    static SFHomeFeatures *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [self new]; });
    return s;
}

- (void)start {
    [self restore];
    [self scheduleBoundaryRefresh];
    [self refresh];
    _timer = [NSTimer scheduledTimerWithTimeInterval:kRefreshEvery target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onlineChanged) name:SFNetOnlineDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(regionChanged) name:SFNetRegionDidChangeNotification object:nil];
}

+ (NSArray *)topics { return @[SFHomeTopicLive, SFHomeTopicNews, SFHomeTopicHighlights]; }

- (void)regionChanged { [[NSNotificationCenter defaultCenter] postNotificationName:SFHomeFeaturesDidChangeNotification object:nil]; }

- (void)onlineChanged { if ([SFNet isOnline]) [self refresh]; }

// Filter first, then merge: an app whose first items can't play here moves its playable ones up
// instead of losing its places at the front. A TV channel offered by two apps (3sat, phoenix, KiKA
// in ZDF and ARD) appears once: at the first place either gets, as the richer of the two (with
// its programme).
- (NSArray *)itemsForTopic:(NSString *)topic {
    NSMutableArray *lists = [NSMutableArray new];
    NSMutableDictionary *best = [NSMutableDictionary new];   // station -> the item shown for it
    for (Class<SFApp> app in [SFAppRegistry apps]) {   // registry order = home tile order
        NSMutableArray *l = [NSMutableArray new];
        for (SFItem *i in _lists[topic][[app appIdentifier]]) {
            // Home offers only what plays here: no copy-protected streams, nothing limited to a region this device is known to be outside of
            if (i.drm || [SFNet stateOfRegion:i.geoRegion] == SFRegionOutside) continue;
            if (i.kind == SFItemVideo && [[SFStore shared] watched:i.identifier]) continue;   // seen already: no longer a suggestion
            if (i.station.length && (!best[i.station] || (![best[i.station] schedule].count && i.schedule.count))) best[i.station] = i;
            [l addObject:i];
            if (l.count >= perApp(topic)) break;
        }
        if (byDate(topic)) [l sortUsingComparator:^NSComparisonResult(SFItem *a, SFItem *b) { return [(b.date ?: [NSDate distantPast]) compare:(a.date ?: [NSDate distantPast])]; }];
        if (l.count) [lists addObject:l];
    }
    NSMutableArray *r = [NSMutableArray new];
    NSArray *merged = SFInterleave(lists, rowMax(topic), ^id(SFItem *i) { return i.station.length ? [@"station:" stringByAppendingString:i.station] : i.identifier; });   // fair: every app gets a place at the front
    for (SFItem *m in merged) {
        SFItem *i = m.station.length ? best[m.station] : m;
        SFItem *c = [i copy];
        c.showsSourceMark = YES;   // mixed row: say which app it comes from
        c.style = SFTileStyleLandscape;
        [r addObject:c];
    }
    return r;
}

#pragma mark Refresh

- (void)refresh {
    if (_refreshing || ![SFNet isOnline]) return;
    _refreshing = YES;
    _lastRefresh = [NSDate date];
    NSArray *apps = [SFAppRegistry apps];
    NSMutableDictionary *byApp = [NSMutableDictionary new];   // app identifier -> {topic: items}
    dispatch_group_t g = dispatch_group_create();
    for (Class<SFApp> app in apps) {
        if (![app respondsToSelector:@selector(homeFeatures:)]) continue;
        NSString *aid = [app appIdentifier];
        dispatch_group_enter(g);
        __block BOOL answered = NO;
        void (^answer)(NSDictionary *) = ^(NSDictionary *d) {
            SFMain(^{
                if (answered) return;   // late answer after the timeout, or answered twice
                answered = YES;
                if ([d isKindOfClass:[NSDictionary class]]) byApp[aid] = d;
                dispatch_group_leave(g);
            });
        };
        [app homeFeatures:answer];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAppTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!answered) SFLog(@"home features: %@ did not answer in %.0f s", aid, kAppTimeout);
            answer(nil);
        });
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        self->_refreshing = NO;
        NSMutableDictionary *lists = [NSMutableDictionary new];
        for (NSString *topic in [SFHomeFeatures topics]) {
            NSMutableDictionary *t = [NSMutableDictionary new];
            for (Class<SFApp> app in apps) {
                NSString *aid = [app appIdentifier];
                NSArray *items = byApp[aid][topic];
                // no answer for this topic now (failed request, timeout): keep what the app featured before
                if (!items) { if (self->_lists[topic][aid]) t[aid] = self->_lists[topic][aid]; continue; }
                if (![items isKindOfClass:[NSArray class]] || !items.count) continue;   // answered: nothing to feature
                t[aid] = [items subarrayWithRange:NSMakeRange(0, MIN(items.count, kKeepPerApp))];
            }
            lists[topic] = t;
        }
        BOOL same = [[self signature:lists] isEqualToString:[self signature:self->_lists]];
        self->_lists = lists;
        [self scheduleBoundaryRefresh];
        if (same) return;   // same rows: no reload
        [self store];
        SFLog(@"home features: live %lu, news %lu, highlights %lu", (unsigned long)[self itemsForTopic:SFHomeTopicLive].count,
              (unsigned long)[self itemsForTopic:SFHomeTopicNews].count, (unsigned long)[self itemsForTopic:SFHomeTopicHighlights].count);
        [[NSNotificationCenter defaultCenter] postNotificationName:SFHomeFeaturesDidChangeNotification object:nil];
    });
}

- (NSString *)signature:(NSDictionary *)lists {
    NSMutableString *s = [NSMutableString new];
    for (NSString *topic in [lists.allKeys sortedArrayUsingSelector:@selector(compare:)])
        for (NSString *aid in [[lists[topic] allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            [s appendFormat:@"%@/%@:", topic, aid];
            for (SFItem *i in lists[topic][aid]) [s appendFormat:@"%@,", [self stored:i]];   // everything that is kept: a new broadcast on a channel changes ref, subtitle, drm
        }
    return s;
}

// A live channel's programme changes: ask the apps again when the first current broadcast ends
// (new stream ref, drm, geo right per broadcast - ORF), at most every 5 min; the 30 min timer stays.
- (void)scheduleBoundaryRefresh {
    [_boundary invalidate]; _boundary = nil;
    NSDate *now = [NSDate date], *first = nil;
    for (NSArray *l in [_lists[SFHomeTopicLive] allValues])
        for (SFItem *i in l) {
            NSDate *end = [i broadcastAt:now].end;
            if (end && (!first || [end compare:first] == NSOrderedAscending)) first = end;
        }
    if (!first) return;
    NSTimeInterval at = MAX([first timeIntervalSinceNow] + 5, (_lastRefresh ? [_lastRefresh timeIntervalSinceNow] : 0) + 300);
    if (at > kRefreshEvery) return;
    _boundary = [NSTimer scheduledTimerWithTimeInterval:MAX(at, 5) target:self selector:@selector(refresh) userInfo:nil repeats:NO];
}

#pragma mark Store (Home shows the last rows at once after a launch)

// an item as stored: its dictionary + what the dictionary leaves out but a tile shows (badge)
- (NSDictionary *)stored:(SFItem *)i {
    NSMutableDictionary *d = [[i dictionaryRepresentation] mutableCopy];
    if (i.badge) d[@"badge"] = i.badge;
    return d;
}

- (void)store {
    NSMutableDictionary *d = [NSMutableDictionary new];
    for (NSString *topic in _lists) {
        NSMutableDictionary *t = [NSMutableDictionary new];
        for (NSString *aid in _lists[topic]) {
            NSMutableArray *a = [NSMutableArray new];
            for (SFItem *i in _lists[topic][aid]) [a addObject:[self stored:i]];
            t[aid] = a;
        }
        d[topic] = t;
    }
    [[SFStore shared] cacheJSON:d forKey:kStoreKey];
}

- (void)restore {
    NSDictionary *d = [[SFStore shared] cachedJSON:kStoreKey maxAge:7 * 86400];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    NSMutableDictionary *lists = [NSMutableDictionary new];
    for (NSString *topic in d) {
        if (![d[topic] isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *t = [NSMutableDictionary new];
        for (NSString *aid in d[topic]) {
            if (![SFAppRegistry appNamed:aid] || ![d[topic][aid] isKindOfClass:[NSArray class]]) continue;   // app gone
            NSMutableArray *a = [NSMutableArray new];
            for (NSDictionary *x in d[topic][aid]) {
                if (![x isKindOfClass:[NSDictionary class]]) continue;
                SFItem *i = [SFItem itemWithDictionary:x];
                // what the dictionary does not carry: theme, badge, the page of a show
                i.themeName = i.source;
                i.badge = [x[@"badge"] isKindOfClass:[NSString class]] ? x[@"badge"] : nil;
                if (i.kind == SFItemFolder) {
                    i.pageLoader = [SFAppRegistry isShowRef:i.identifier] ? SFShowPageLoader(i.identifier, i.title) : nil;
                    if (!i.pageLoader) continue;
                }
                [a addObject:i];
            }
            if (a.count) t[aid] = a;
        }
        lists[topic] = t;
    }
    _lists = lists;
}
@end
