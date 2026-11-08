#import "SFExampleApp.h"
#import "SFEngine.h"
#import "SFDownloads.h"
#import "SFMediaStore.h"

// --- the "API client": a static catalogue (a real app maps its source's JSON to SFItems) ---

static NSArray *catalogue(void) {
    return @[@[@"1", @"Testbild", @"testsrc2"], @[@"2", @"Farbbalken", @"smptehdbars"],
             @[@"3", @"Mandelbrot", @"mandelbrot"], @[@"4", @"Leben", @"life=mold=10:ratio=0.1:death_color=#202020:life_color=#40c0ff"]];
}

static SFItem *video(NSArray *entry);
static NSArray *morePortion(NSInteger n) {   // test rail (SOFA_EXAMPLE_MORE): portion n, 8 videos
    NSMutableArray *out = [NSMutableArray new];
    for (NSInteger k = 0; k < 8; k++) {
        SFItem *i = video(catalogue()[(NSUInteger)(n * 8 + k) % catalogue().count]);
        i.identifier = [NSString stringWithFormat:@"example:more%ld", (long)(n * 8 + k)];
        i.title = [NSString stringWithFormat:@"Weiteres Video %ld", (long)(n * 8 + k + 1)];
        [out addObject:i];
    }
    return out;
}

static SFItem *video(NSArray *entry) {
    SFItem *i = [SFItem new];
    i.kind = SFItemVideo;
    i.identifier = [@"example:" stringByAppendingString:entry[0]];   // the ref: namespace "example" -> this app
    i.resolverRef = i.identifier;
    i.title = entry[1];
    i.channel = @"Beispielsendung";
    i.showRef = @"exampleshow:demo";        // "Zur Sendung" + follow
    i.duration = 60;
    i.viewCount = 1000 * [entry[0] integerValue];   // views at the source, where it has them
    i.source = [SFExampleApp appIdentifier];
    i.themeName = i.source;
    i.style = SFTileStyleLandscape;
    i.plot = @"Ein Video der Beispiel-App – Vorlage für neue Apps (docs/new-app.md).";
    return i;
}

static NSArray *videos(NSString *filter) {
    NSMutableArray *r = [NSMutableArray new];
    for (NSArray *e in catalogue())
        if (!filter.length || [e[1] rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound) [r addObject:video(e)];
    return r;
}

@implementation SFExampleApp

#pragma mark Identity (required)

+ (NSString *)appIdentifier { return @"example"; }
+ (NSString *)appName { return @"Beispiel"; }
+ (NSString *)appSummary { return @"Vorlage für neue Apps"; }
+ (NSArray *)refPrefixes { return @[@"example", @"exampleshow"]; }
+ (NSArray *)showRefPrefixes { return @[@"exampleshow"]; }
+ (NSColor *)homeTileColor { return SFHex(0x5b3fa8); }
+ (NSInteger)homeTileLogoVariant { return 0; }

+ (void)configureTheme:(SFTheme *)t {
    t.wordmark = @"Beispiel";   // no logo file: wordmark + header mark
    t.background = SFHex(0x120d1f);
    t.backgroundTop = SFHex(0x2a1f4a);
    t.accent = SFHex(0xa68bff);
    t.accentText = SFHex(0x120d1f);
    t.focus = SFHex(0xa68bff);
    t.headerMark = SFHeaderMarkDot;
}

#pragma mark Start page (required): only the app's own shelves; the shell adds the shared ones

+ (SFPageLoader)homeLoader {
    return ^(SFPageDone done) {
        SFItem *show = [SFItem new];
        show.kind = SFItemFolder; show.identifier = @"exampleshow:demo"; show.title = @"Beispielsendung";
        show.source = [self appIdentifier]; show.themeName = show.source; show.style = SFTileStyleWide;
        show.pageLoader = [self showPageLoader:show.identifier title:show.title];
        NSMutableArray *shelves = [@[[SFShelf shelf:@"Neu" style:SFTileStyleLandscape items:videos(nil)],
                                     [SFShelf shelf:@"Sendungen" style:SFTileStyleWide items:@[show]]] mutableCopy];
        // tests: a rail that loads more as the viewer nears its end (SFShelf moreLoader) -
        // SOFA_EXAMPLE_MORE=<portions after the first>, 8 videos each
        NSInteger portions = SFDevEnv(@"SOFA_EXAMPLE_MORE").integerValue;
        if (portions > 0) {
            __block NSInteger next = 1;
            SFShelf *more = [SFShelf shelf:@"Mehr Beispiele" style:SFTileStyleLandscape items:morePortion(0)];
            more.moreLoader = ^(void (^got)(NSArray *, BOOL)) {
                NSInteger n = next++;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ got(morePortion(n), n < portions); });
            };
            [shelves addObject:more];
        }
        done([SFPage page:nil theme:[self appIdentifier] shelves:shelves], nil);
    };
}

#pragma mark Capabilities (optional)

+ (SFPageLoader)searchLoader:(NSString *)query {
    return ^(SFPageDone done) {
        NSArray *r = videos(query);
        SFPage *p = [SFPage page:query theme:[self appIdentifier] shelves:r.count ? @[[SFShelf grid:@"Videos" style:SFTileStyleLandscape items:r]] : @[]];
        if (!r.count) p.emptyText = @"Nichts gefunden.";
        done(p, nil);
    };
}

+ (void)resolve:(NSString *)ref done:(SFURLDone)done {
    for (NSArray *e in catalogue())
        if ([e[0] isEqualToString:SFRefID(ref)]) {
            // tests: a real file/URL (downloads fill from it through the media proxy), else mpv's test pattern, 60 s
            NSString *media = SFDevEnv(@"SOFA_EXAMPLE_MEDIA");
            // ...as a DASH pair like YouTube's engine serves it: SOFA_EXAMPLE_AUDIO=<separate audio track>
            NSString *audio = SFDevEnv(@"SOFA_EXAMPLE_AUDIO");
            if (media && audio) SFSetMPVSource([NSURL URLWithString:media], @{@"video": media, @"audio": audio});
            if (media) { done([NSURL URLWithString:media], nil); return; }
            NSString *u = [NSString stringWithFormat:@"av://lavfi:%@,trim=duration=60", e[2]];
            done([NSURL URLWithString:[u stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]], nil);
            return;
        }
    done(nil, SFError(@"Video nicht gefunden"));
}

// Downloads into the media store (fillItem:, docs/media-store.md) - tests only: SOFA_EXAMPLE_FILL=<s
// per piece> makes the Example app fill itself (else the media proxy fills from its file). One
// track of 8 synthetic 1-MB pieces (two store blocks) plus the manifest naming it; a piece already stored is skipped
// (a resumed download fetches only the rest), every fetched one is logged.
+ (BOOL)respondsToSelector:(SEL)sel {
    if (sel == @selector(fillItem:progress:done:)) return SFDevEnv(@"SOFA_EXAMPLE_FILL") != nil;
    return [super respondsToSelector:sel];
}

+ (dispatch_block_t)fillItem:(SFItem *)item progress:(void (^)(double))progress done:(void (^)(NSDictionary *, NSError *))done {
    __block BOOL cancelled = NO;
    NSString *item_ = item.identifier, *track = [item.identifier stringByAppendingString:@":v"];
    const long long piece = 1 << 20, total = 8 * piece;
    double gap = [SFDevEnv(@"SOFA_EXAMPLE_FILL") doubleValue];
    SFMediaStore *store = [SFDownloads shared].mediaStore;
    if (![catalogue() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF[0] == %@", SFRefID(item_)]].count) {
        done(nil, SFError(@"Video nicht gefunden")); return ^{};
    }
    [store setManifest:@{@"required": @[track]} forItem:item_];
    __block void (^step)(long long);
    __block __weak void (^weakStep)(long long);
    weakStep = step = ^(long long k) {
        if (cancelled) return;
        if (k >= 8) { [store sync]; done(@{}, nil); return; }
        if ([[store extentsOf:track] coversStart:k * piece end:(k + 1) * piece]) { weakStep(k + 1); return; }
        NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)piece];
        memset(d.mutableBytes, (int)k + 1, (size_t)piece);
        [store write:d key:track item:item_ kind:@"video" total:total at:k * piece];
        SFLog(@"example: filled %@ piece %lld", item_, k);
        progress((k + 1) / 8.0);
        void (^next)(long long) = weakStep;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gap * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ next(k + 1); });
    };
    step(0);
    return ^{ cancelled = YES; step = nil; };
}

// Session streams (an app service behind the URL, like YouTube's engine): tests make the Example
// app's streams count as such (SOFA_EXAMPLE_SESSION=1) to exercise the player's session recovery.
+ (BOOL)playbackIsSession:(NSDictionary *)source { return SFDevEnv(@"SOFA_EXAMPLE_SESSION") != nil; }
+ (void)playbackSessionFailed:(NSDictionary *)source item:(SFItem *)item reason:(NSString *)why { SFLog(@"example: session failed (%@)", why); }

// Autoplay recommendation (YouTube: its /next answer): the catalogue's next video. Only when a test
// asks for it - SOFA_EXAMPLE_UPNEXT=<seconds the answer takes> exercises the player's wait at the end;
// without it there is none (the other tests' videos end and leave).
+ (void)upNextForItem:(SFItem *)item done:(void (^)(SFItem *))done {
    NSString *delay = SFDevEnv(@"SOFA_EXAMPLE_UPNEXT");
    if (!delay) { done(nil); return; }
    NSArray *all = videos(nil);
    NSUInteger i = [[all valueForKey:@"identifier"] indexOfObject:item.identifier];
    SFItem *next = i != NSNotFound && i + 1 < all.count ? all[i + 1] : nil;
    SFLog(@"example: up next for %@ asked", item.identifier);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ done(next); });
}

+ (SFPageLoader)showPageLoader:(NSString *)ref title:(NSString *)title {
    return ^(SFPageDone done) {
        done([SFPage page:title ?: @"Beispielsendung" theme:[self appIdentifier]
                  shelves:@[[SFShelf grid:@"Folgen" style:SFTileStyleLandscape items:videos(nil)]]], nil);
    };
}

+ (void)feed:(NSString *)ref done:(void (^)(NSArray *, NSError *))done { SFLog(@"example: feed %@", ref); done(videos(nil), nil); }

// A source may pause its background requests (YouTube: bot check). Tests set one with
// SOFA_EXAMPLE_PAUSE=<seconds from launch>.
+ (NSTimeInterval)backgroundPausedUntil {
    static NSTimeInterval until;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ double s = SFDevEnv(@"SOFA_EXAMPLE_PAUSE").doubleValue; until = s > 0 ? [NSDate date].timeIntervalSince1970 + s : 0; });
    return until;
}

// Home rows mixed from all apps (SFHomeFeatures.h): items per topic. A real app reads them from its
// start page (SFHomeFeaturesFromPage) and sets `drm` / `geoRegion` from the source's raw data -
// Home then leaves out what can't play here. The three channels exercise exactly that (tools/test-home).
+ (void)homeFeatures:(void (^)(NSDictionary *))done {
    SFLog(@"example: home features asked");
    NSMutableArray *live = [NSMutableArray new];
    for (NSArray *e in @[@[@"live1", @"Testkanal", @""], @[@"live2", @"Testkanal DRM", @"drm"], @[@"live3", @"Testkanal XX", @"XX"]]) {
        SFItem *i = video(@[e[0], e[1], @""]);
        i.kind = SFItemLive; i.badge = @"LIVE"; i.duration = 0; i.showRef = nil;
        i.drm = [e[2] isEqualToString:@"drm"];
        if ([e[2] length] == 2) i.geoRegion = e[2];   // only playable in country XX
        // the channel's programme (a real app maps its EPG): tiles show what runs now, the hero what comes next
        NSDate *t0 = [NSDate dateWithTimeIntervalSinceNow:-900];   // began 15 min ago, runs 45 min more (tests never cross a change)
        SFBroadcast *now = [SFBroadcast title:@"Testsendung" start:t0 end:[t0 dateByAddingTimeInterval:3600]];
        now.plot = @"Was gerade läuft – aus dem Programm der Quelle.";
        i.schedule = @[now, [SFBroadcast title:@"Nächste Sendung" start:now.end end:[now.end dateByAddingTimeInterval:1800]]];
        [live addObject:i];
    }
    // news: the app's own order is oldest first here - Home shows each app's news newest first
    NSArray *news = [videos(nil) subarrayWithRange:NSMakeRange(2, 2)];
    [news[0] setDate:[NSDate dateWithTimeIntervalSinceNow:-7200]];
    [news[1] setDate:[NSDate dateWithTimeIntervalSinceNow:-600]];
    done(@{SFHomeTopicLive: live, SFHomeTopicNews: news, SFHomeTopicHighlights: [videos(nil) subarrayWithRange:NSMakeRange(0, 2)]});
}

@end
