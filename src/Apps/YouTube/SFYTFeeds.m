// How a channel's feed stays cheap:
// - the RSS feed (one small request) is the change detector, the date and the views source;
// - while its video list is unchanged, the channel's last parsed list (stored, a few KB) is the
//   answer - no InnerTube request at all;
// - InnerTube browses have a budget per 30 min, so a refresh without stored lists (first launch,
//   cache lost) spreads over several cycles instead of one burst;
// - during a bot-check pause (SFYTBreaker) nothing is requested: every request while flagged
//   prolongs the flag (2026-11-05: feeds kept browsing through a pause).
#import "SFYTFeeds.h"
#import "SFApp.h"
#import "SFYTInnerTube.h"
#import "SFYTParser.h"
#import "SFYTBreaker.h"
#import "SFStore.h"
#import "SFCurl.h"

static NSString *feedID(NSString *cid) { return [@"ytchannel:" stringByAppendingString:cid]; }   // the follow's id = the stored feed's

// At most `max` calls per 30 min for one purpose; YES = this one may go.
static BOOL withinBudget(NSMutableArray *recent, NSUInteger max) {
    @synchronized (recent) {
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        while (recent.count && now - [recent.firstObject doubleValue] > 1800) [recent removeObjectAtIndex:0];
        if (recent.count >= max) return NO;
        [recent addObject:@(now)];
        return YES;
    }
}
static NSMutableArray *gFeedCalls, *gAvatarCalls;   // feeds: 20 per 30 min; avatars: 5 more, never at the feeds' expense
static NSMutableSet *gAvatarTried;                  // channels asked for their avatar since launch (once each)

// Exact publication times of a channel's latest long videos: YouTube's RSS feed of the UULF
// playlist (no Shorts) - 15 entries with <published> to the second, one light request outside
// InnerTube - and (out) each one's view count (media:statistics, the raw number YouTube shows;
// "Highlights": videos far above the channel's usual). Synchronous (call off main); nil when unavailable.
static NSDictionary *rssPublished(NSString *cid, NSDictionary **viewsOut) {
    NSInteger st = 0;
    NSString *u = [@"https://www.youtube.com/feeds/videos.xml?playlist_id=UULF" stringByAppendingString:[cid substringFromIndex:2]];
    NSData *d = SFCurlFetch(u, @"GET", nil, nil, &st, NULL);
    NSString *xml = st == 200 && d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
    if (!xml) return nil;
    static NSRegularExpression *re, *vre;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"<entry>.*?<yt:videoId>([^<]+)</yt:videoId>.*?<published>([^<]+)</published>.*?</entry>"
                                                       options:NSRegularExpressionDotMatchesLineSeparators error:nil];
        vre = [NSRegularExpression regularExpressionWithPattern:@"<media:statistics views=\"([0-9]+)\"" options:0 error:nil];
    });
    NSMutableDictionary *r = [NSMutableDictionary new], *views = [NSMutableDictionary new];
    for (NSTextCheckingResult *m in [re matchesInString:xml options:0 range:NSMakeRange(0, xml.length)]) {
        NSString *vid = [xml substringWithRange:[m rangeAtIndex:1]];
        NSDate *when = SFDateFromISO8601([xml substringWithRange:[m rangeAtIndex:2]]);
        if (when) r[vid] = when;
        NSTextCheckingResult *v = [vre firstMatchInString:xml options:0 range:m.range];
        if (v) views[vid] = @([[xml substringWithRange:[v rangeAtIndex:1]] longLongValue]);
    }
    if (viewsOut) *viewsOut = views;
    return r.count ? r : nil;
}

@implementation SFYTFeeds

+ (void)initialize {
    if (self != [SFYTFeeds class]) return;
    gFeedCalls = [NSMutableArray new]; gAvatarCalls = [NSMutableArray new]; gAvatarTried = [NSMutableSet new];
}

+ (void)feed:(NSString *)cid done:(void (^)(NSArray *, NSError *))done {
    if (![cid hasPrefix:@"UC"]) { done(nil, SFError(@"Unbekannter Kanal")); return; }
    SFBackground(^{
        [self migrateStorage];
        if ([SFYTBreaker shared].blockedUntil) {   // follows keep what they have
            NSArray *last = [self stored:cid sig:NULL];
            SFMain(^{ done(last.count ? last : nil, last.count ? nil : SFError(@"YouTube pausiert gerade (Bot-Prüfung).")); });
            return;
        }
        NSDictionary *views = nil, *published = rssPublished(cid, &views);
        [self feed:cid published:published done:^(NSArray *items, NSError *e) {
            for (SFItem *i in items) { NSNumber *v = views[SFRefID(i.identifier)]; if (v) i.viewCount = v.longLongValue; }
            SFMain(^{ done(items, e); });   // the stored-list path answers on this background thread
        }];
    });
}

// The stored list or a fresh one; dates: exact from RSS where it has them
+ (void)feed:(NSString *)cid published:(NSDictionary *)published done:(void (^)(NSArray *, NSError *))done {
    NSString *sig = published ? [[published.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","] : nil;
    void (^finish)(NSArray *, NSError *) = ^(NSArray *items, NSError *err) {
        NSDate *oldest = nil;
        for (SFItem *i in items) {
            NSDate *exact = published[SFRefID(i.identifier)];
            if (exact) { i.date = exact; oldest = oldest ? [oldest earlierDate:exact] : exact; }
        }
        // beyond the 15 RSS entries only the approximation exists (relative to a possibly days-old
        // answer): never newer than the oldest exact entry, so the order stays right
        for (SFItem *i in items)
            if (oldest && !published[SFRefID(i.identifier)] && (!i.date || [i.date compare:oldest] != NSOrderedAscending))
                i.date = [oldest dateByAddingTimeInterval:-60];
        done(items, err);
    };
    NSString *stored = nil;
    NSArray *last = [self stored:cid sig:&stored];
    NSArray *parts = [stored componentsSeparatedByString:@"@"];
    BOOL unchanged = sig && [parts.firstObject isEqualToString:sig] &&
                     (parts.count == 1 || [NSDate date].timeIntervalSince1970 - [parts.lastObject doubleValue] < 2 * 3600);
    // RSS failed (no signature): nothing known to have changed - the stored list, signature kept
    if ((unchanged || !sig) && last.count) { finish(last, nil); return; }
    [self uploads:cid done:^(NSArray *online, NSError *e) {
        if (!online) { finish(last.count ? last : nil, last.count ? nil : e); return; }   // failed: the last known list
        NSString *newSig = sig;
        if (sig) {
            NSMutableSet *ids = [NSMutableSet new];
            for (SFItem *i in online) [ids addObject:SFRefID(i.identifier)];
            if (![[NSSet setWithArray:published.allKeys] isSubsetOfSet:ids])
                newSig = [NSString stringWithFormat:@"%@@%.0f", sig, [NSDate date].timeIntervalSince1970];
        }
        [self store:online sig:newSig channel:cid];
        finish(online, nil);
    }];
}

// the channel's long videos (InnerTube browse of the UULF playlist). Not kept in the response
// cache: the answer is ~1 MB, the parsed list (stored) is what is reused.
+ (void)uploads:(NSString *)cid done:(void (^)(NSArray *, NSError *))done {
    if (!withinBudget(gFeedCalls, 20)) { done(nil, SFError(@"YouTube: später erneut")); return; }
    SFYTCall(@"browse", @{@"browseId": [@"VLUULF" stringByAppendingString:[cid substringFromIndex:2]]}, 0, ^(id j, NSError *e) {
        done(j ? [self videosInUploads:j] : nil, e);
    });
}

+ (NSArray *)videosInUploads:(id)browse {
    NSMutableArray *videos = [NSMutableArray new];
    for (SFItem *i in [SFYTParser itemsIn:browse continuation:NULL channels:nil]) if (i.kind == SFItemVideo) [videos addObject:i];
    return videos;
}

// A followed channel without a usable picture asks once per launch - its header is the channel
// page's own answer (cached a day), on a budget of its own: a library adopted with many such
// channels heals over a few refresh cycles without delaying anyone's new videos.
+ (void)avatar:(NSString *)cid done:(void (^)(NSString *))done {
    BOOL ask;
    @synchronized (gAvatarTried) {
        ask = [cid hasPrefix:@"UC"] && ![gAvatarTried containsObject:cid] && ![SFYTBreaker shared].blockedUntil && withinBudget(gAvatarCalls, 5);
        if (ask) [gAvatarTried addObject:cid];
    }
    if (!ask) { SFMain(^{ done(nil); }); return; }
    SFYTCall(@"browse", @{@"browseId": cid}, 86400, ^(id j, NSError *e) {
        if (!j) @synchronized (gAvatarTried) { [gAvatarTried removeObject:cid]; }   // no answer: ask again next cycle
        NSString *avatar = [SFYTParser channelHeaderIn:j][@"avatar"];
        SFLog(@"youtube: avatar of %@ %@", cid, avatar.length ? @"found" : j ? @"not in the header" : @"not loaded");
        SFMain(^{ done(avatar); });
    });
}

#pragma mark Stored feeds

// The stored feed of a channel (table feed_cache, docs/architecture.md "Data"): the last parsed
// list + its RSS signature. Signature "<ids>" = the list holds every RSS video; "<ids>@<epoch>" =
// it did not (InnerTube lagging behind RSS, a premiere not aired yet) - then reused for 2 h only,
// so the new upload shows up soon without asking on every refresh.
static NSArray *itemsFrom(NSArray *dicts) {
    NSMutableArray *a = [NSMutableArray new];
    for (NSDictionary *d in dicts)
        if ([d isKindOfClass:[NSDictionary class]]) { SFItem *i = [SFItem itemWithDictionary:d]; if (i.identifier) [a addObject:i]; }
    return a;
}

+ (void)store:(NSArray *)items sig:(NSString *)sig channel:(NSString *)cid {
    NSString *j = SFJSONString([items valueForKey:@"dictionaryRepresentation"]);
    if (!j) return;
    [[SFStore shared] run:@"INSERT OR REPLACE INTO feed_cache (id, sig, items, updated) VALUES (?,?,?,?)"
                     args:@[feedID(cid), sig ?: [NSNull null], j, @([NSDate date].timeIntervalSince1970)]];
}

+ (NSArray *)stored:(NSString *)cid sig:(NSString **)sig {
    NSDictionary *r = [[SFStore shared] rows:@"SELECT sig, items FROM feed_cache WHERE id=?" args:@[feedID(cid)]].firstObject;
    if (sig) *sig = [r[@"sig"] isKindOfClass:[NSString class]] ? r[@"sig"] : nil;
    id list = SFJSONParse(r[@"items"]);
    return itemsFrom([list isKindOfClass:[NSArray class]] ? list : @[]);
}

// One-time move to the stored feeds (0.3.8 -> 0.3.9). Until then the raw browse answers (~1 MB
// each) sat in the response cache and the signatures in the settings (yt.feedsig.<cid>): the parsed
// lists with their signatures become the stored feeds, the rest goes - otherwise every channel
// would ask InnerTube at once on the first refresh (a burst right after a bot pause).
+ (void)migrateStorage {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SFStore *st = [SFStore shared];
        if ([st setting:@"yt.feeds.v2"]) return;
        NSMutableDictionary *lists = [NSMutableDictionary new];   // cid -> items
        NSMutableArray *drop = [NSMutableArray new];
        // keys first, then one ~1 MB answer at a time (not all of them in memory at once)
        for (NSDictionary *r in [st rows:@"SELECT k FROM jcache WHERE k LIKE 'POST https://www.youtube.com/youtubei/v1/browse%VLUULF%'" args:nil]) {
            NSString *rest = [r[@"k"] substringFromIndex:NSMaxRange([r[@"k"] rangeOfString:@"VLUULF"])];
            @autoreleasepool {
                id j = rest.length >= 22 ? [st cachedJSON:r[@"k"] maxAge:DBL_MAX] : nil;
                NSArray *items = j ? [self videosInUploads:j] : nil;
                if (items.count) lists[[@"UC" stringByAppendingString:[rest substringToIndex:22]]] = items;
            }
            [drop addObject:@[@"DELETE FROM jcache WHERE k=?", @[r[@"k"]]]];
        }
        [lists enumerateKeysAndObjectsUsingBlock:^(NSString *cid, NSArray *items, BOOL *stop) {
            [self store:items sig:[st setting:[@"yt.feedsig." stringByAppendingString:cid]] channel:cid];
        }];
        [drop addObject:@[@"DELETE FROM settings WHERE k LIKE 'yt.feedsig.%' OR k = 'yt.feeds.adopted'"]];
        [st runAll:drop];
        [st setSetting:@"1" forKey:@"yt.feeds.v2"];
        if (lists.count) SFLog(@"yt: %lu channel feeds moved to the stored feeds", (unsigned long)lists.count);
    });
}

+ (void)devFeed:(NSString *)cid {
    SFBackground(^{
        NSDictionary *pub = rssPublished(cid, NULL);
        SFLog(@"dev: ytfeed %@: rss %lu dates", cid, (unsigned long)pub.count);
        [self migrateStorage];
        [self feed:cid published:pub done:^(NSArray *items, NSError *e) {
            for (SFItem *i in items)
                SFLog(@"dev: ytfeed %@ %@ %@ %@", SFRefID(i.identifier), i.date, pub[SFRefID(i.identifier)] ? @"rss" : @"relative", i.title);
            SFLog(@"dev: ytfeed end (%lu items%@)", (unsigned long)items.count, e ? [@", " stringByAppendingString:e.localizedDescription] : @"");
        }];
    });
}
@end
