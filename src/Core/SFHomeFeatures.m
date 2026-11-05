#import "SFHomeFeatures.h"
#import "SFApp.h"
#import "SFStore.h"
#import "SFNet.h"
#import "SFFollows.h"

NSString *const SFHomeTopicLive = @"live";
NSString *const SFHomeTopicHighlights = @"highlights";
NSString *const SFHomeFeaturesDidChangeNotification = @"SFHomeFeaturesDidChange";

static NSString *const kStoreKey = @"home.features.v1";
static const NSTimeInterval kRefreshEvery = 30 * 60;
static const NSTimeInterval kAppTimeout = 45;   // an app that never answers must not hold the others back

// per topic: how many items one app may place in the merged row, and the row's length
static NSUInteger perApp(NSString *topic) { return [topic isEqualToString:SFHomeTopicLive] ? 40 : 6; }
static NSUInteger rowMax(NSString *topic) { return [topic isEqualToString:SFHomeTopicLive] ? 40 : 24; }

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

@implementation SFHomeFeatures {
    NSDictionary *_rows;        // topic -> merged SFItems
    BOOL _refreshing;
    NSTimer *_timer;
}

+ (instancetype)shared {
    static SFHomeFeatures *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [self new]; });
    return s;
}

- (void)start {
    [self restore];
    [self refresh];
    _timer = [NSTimer scheduledTimerWithTimeInterval:kRefreshEvery target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onlineChanged) name:SFNetOnlineDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(regionChanged) name:SFNetRegionDidChangeNotification object:nil];
}

- (void)regionChanged { [[NSNotificationCenter defaultCenter] postNotificationName:SFHomeFeaturesDidChangeNotification object:nil]; }

- (void)onlineChanged { if ([SFNet isOnline]) [self refresh]; }

- (NSArray *)itemsForTopic:(NSString *)topic {
    NSMutableArray *r = [NSMutableArray new];
    for (SFItem *i in _rows[topic]) {
        // Home offers only what plays here: no copy-protected streams, nothing limited to a region this device is known to be outside of
        if (i.drm || [SFNet stateOfRegion:i.geoRegion] == SFRegionOutside) continue;
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
        NSMutableDictionary *rows = [NSMutableDictionary new];
        for (NSString *topic in @[SFHomeTopicLive, SFHomeTopicHighlights]) {
            NSMutableArray *lists = [NSMutableArray new];
            for (Class<SFApp> app in apps) {   // registry order = home tile order
                NSArray *items = byApp[[app appIdentifier]][topic];
                if (!items) {
                    // no answer for this topic now (failed request, timeout): keep what the app featured before
                    NSMutableArray *old = [NSMutableArray new];
                    for (SFItem *i in self->_rows[topic]) if ([i.source isEqualToString:[app appIdentifier]]) [old addObject:i];
                    if (old.count) [lists addObject:old];
                    continue;
                }
                if (![items isKindOfClass:[NSArray class]] || !items.count) continue;   // answered: nothing to feature
                [lists addObject:[items subarrayWithRange:NSMakeRange(0, MIN(items.count, perApp(topic)))]];
            }
            rows[topic] = SFInterleave(lists, rowMax(topic), ^id(SFItem *i) { return i.identifier; });   // fair: every app gets a place at the front
        }
        if ([[self signature:rows] isEqualToString:[self signature:self->_rows]]) return;   // same rows: no reload
        self->_rows = rows;
        [self store];
        SFLog(@"home features: live %lu, highlights %lu", (unsigned long)[rows[SFHomeTopicLive] count], (unsigned long)[rows[SFHomeTopicHighlights] count]);
        [[NSNotificationCenter defaultCenter] postNotificationName:SFHomeFeaturesDidChangeNotification object:nil];
    });
}

- (NSString *)signature:(NSDictionary *)rows {
    NSMutableString *s = [NSMutableString new];
    for (NSString *topic in [rows.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [s appendFormat:@"%@:", topic];
        for (SFItem *i in rows[topic]) [s appendFormat:@"%@,", [self stored:i]];   // everything that is kept: a new broadcast on a channel changes ref, subtitle, drm
    }
    return s;
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
    for (NSString *topic in _rows) {
        NSMutableArray *a = [NSMutableArray new];
        for (SFItem *i in _rows[topic]) [a addObject:[self stored:i]];
        d[topic] = a;
    }
    [[SFStore shared] cacheJSON:d forKey:kStoreKey];
}

- (void)restore {
    NSDictionary *d = [[SFStore shared] cachedJSON:kStoreKey maxAge:7 * 86400];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    NSMutableDictionary *rows = [NSMutableDictionary new];
    for (NSString *topic in d) {
        NSMutableArray *a = [NSMutableArray new];
        for (NSDictionary *x in d[topic]) {
            if (![x isKindOfClass:[NSDictionary class]]) continue;
            SFItem *i = [SFItem itemWithDictionary:x];
            if (![SFAppRegistry appNamed:i.source]) continue;   // app gone
            // what the dictionary does not carry: theme, live badge, the page of a show
            i.themeName = i.source;
            i.badge = [x[@"badge"] isKindOfClass:[NSString class]] ? x[@"badge"] : nil;
            if (i.kind == SFItemFolder) {
                i.pageLoader = [SFAppRegistry isShowRef:i.identifier] ? SFShowPageLoader(i.identifier, i.title) : nil;
                if (!i.pageLoader) continue;
            }
            [a addObject:i];
        }
        rows[topic] = a;
    }
    _rows = rows;
}
@end
