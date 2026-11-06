#import "SFDownloads.h"
#import "SFFollows.h"
#import "SFZDFApp.h"
#import "SFZDFParser.h"
#import "SFBrowseScreen.h"
#import "SFJSON.h"
#import "SFEngine.h"
#import "SFNet.h"
#import "SFStore.h"

static NSString *const kGQL = @"https://api.zdf.de/graphql";
static NSString *const kPlayer = @"android_native_6";


@implementation SFZDFApp

#pragma mark Token + GraphQL

+ (void)token:(void (^)(NSString *tok))done {
    static NSString *tok; static double exp;
    if (tok && [NSDate date].timeIntervalSince1970 < exp - 600) { done(tok); return; }
    [SFNet getJSON:@"https://zdf-prod-futura.zdf.de/mediathekV2/token" headers:nil cacheAge:0 done:^(id j, NSError *e) {
        NSString *t = str(dict(j)[@"token"]);
        if (t) { tok = t; exp = [nn(j[@"expires"]) doubleValue] ?: [NSDate date].timeIntervalSince1970 + 3600; }
        done(t);
    }];
}

+ (void)gql:(NSString *)query vars:(NSDictionary *)vars cache:(NSTimeInterval)age done:(SFJSONDone)done {
    [self token:^(NSString *tok) {
        if (!tok) { done(nil, SFError(@"ZDF-Anmeldung fehlgeschlagen.")); return; }
        [SFNet postJSON:kGQL body:@{@"query": query, @"variables": vars ?: @{}}
                headers:@{@"Api-Auth": [@"Bearer " stringByAppendingString:tok]} cacheAge:age done:^(id j, NSError *e) {
            NSDictionary *d = dict(dict(j)[@"data"]);
            if (!d) { SFLog(@"zdf: gql error %@", arr(dict(j)[@"errors"]).firstObject ?: e); done(nil, e ?: SFError(@"ZDF-Mediathek: ungültige Antwort.")); return; }
            done(d, nil);
        }];
    }];
}

#pragma mark Items

// a parsed item with the page loader of its kind of folder
+ (SFItem *)withLoader:(SFItem *)i {
    if (i.kind != SFItemFolder) return i;
    NSString *p = SFRefPrefix(i.identifier), *can = SFRefID(i.identifier);
    if ([p isEqualToString:@"zdfmeta"]) i.pageLoader = [self categoryLoader:can id:i.externalID title:i.title];
    else if ([p isEqualToString:@"zdfpage"]) i.pageLoader = [self curatedLoader:can title:i.title];
    else i.pageLoader = [self showLoader:can title:i.title season:0];
    return i;
}

#pragma mark Pages

+ (SFPageLoader)curatedLoader:(NSString *)canonical title:(NSString *)title {
    // items(first:) only allows 1...26 since 11/2026 (otherwise empty clusters + errors)
    NSString *q = [NSString stringWithFormat:@"query P($canonical: String!, $first: Int) { curatedCollectionByCanonical(canonical: $canonical) { title modules { nodes { __typename ... on StaticHorizontalCluster { title items(first: $first) { nodes { __typename ... on Video { %@ } ... on ISmartCollection { %@ } ... on MetaCollection { %@ } ... on CuratedCollection { %@ } } } } } } } }", SFZDF_VIDEO_F, SFZDF_COLL_F, SFZDF_META_F, SFZDF_COLL_F];
    return ^(SFPageDone done) {
        [self gql:q vars:@{@"canonical": canonical, @"first": @26} cache:900 done:^(id d, NSError *e) {
            NSDictionary *cc = dict(dict(d)[@"curatedCollectionByCanonical"]);
            if (!cc) { done(nil, e ?: SFError(@"ZDF-Seite nicht gefunden.")); return; }
            NSMutableArray *shelves = [NSMutableArray new];
            for (NSDictionary *c in [SFZDFParser clustersIn:cc]) {
                NSMutableArray *items = [NSMutableArray new];
                for (SFItem *it in c[@"items"]) [items addObject:[self withLoader:it]];
                SFItem *first = items.firstObject;
                [shelves addObject:[SFShelf shelf:c[@"title"] style:first.style == SFTileStyleWide ? SFTileStyleWide : SFTileStyleLandscape items:items]];
            }
            done([SFPage page:title ?: str(cc[@"title"]) theme:@"zdf" shelves:shelves], nil);
        }];
    };
}

+ (SFPageLoader)showLoader:(NSString *)canonical title:(NSString *)title season:(NSInteger)season {
    NSString *q = [NSString stringWithFormat:@"query S($canonical: String!, $first: Int, $seasonIndex: Int) { smartCollectionByCanonical(canonical: $canonical) { __typename title collectionType teaser { description imageWithoutLogo { layouts { dim1280X720 } } } ... on ISeriesSmartCollection { countSeasons countEpisodes allSeasons: seasons(first: 60) { nodes { number title } } seasons(first: 1, offset: $seasonIndex) { nodes { number title countEpisodes episodes(first: $first, sortBy: [{field: EDITORIAL_DATE, direction: DESC}]) { nodes { %@ } } } } } ... on MovieSmartCollection { video { %@ } } } }", SFZDF_VIDEO_F, SFZDF_VIDEO_F];
    return ^(SFPageDone done) {
        [self gql:q vars:@{@"canonical": canonical, @"first": @100, @"seasonIndex": @(season)} cache:900 done:^(id d, NSError *e) {
            NSDictionary *sc = dict(dict(d)[@"smartCollectionByCanonical"]);
            if (!sc) { done(nil, e ?: SFError(@"Sendung nicht gefunden.")); return; }
            NSString *t = title ?: str(sc[@"title"]);
            NSMutableArray *shelves = [NSMutableArray new];
            NSDictionary *movie = dict(sc[@"video"]);
            if (movie) {
                SFItem *it = [SFZDFParser videoItem:movie];
                if (it) [shelves addObject:[SFShelf shelf:@"Film" style:SFTileStyleLandscape items:@[it]]];
            }
            NSDictionary *sn = dict(arr(dict(sc[@"seasons"])[@"nodes"]).firstObject);
            if (sn) {
                NSMutableArray *eps = [NSMutableArray new];
                for (NSDictionary *v in arr(dict(sn[@"episodes"])[@"nodes"])) { SFItem *it = [SFZDFParser videoItem:v]; if (it) [eps addObject:it]; }
                NSString *st = str(sn[@"title"]) ?: [NSString stringWithFormat:@"%@", nn(sn[@"number"]) ?: @""];
                NSInteger cnt = [nn(sn[@"countEpisodes"]) integerValue];
                NSString *head = cnt > (NSInteger)eps.count ? [NSString stringWithFormat:@"%@ · neueste %lu von %ld", st, (unsigned long)eps.count, (long)cnt]
                                                            : [NSString stringWithFormat:@"%@ · %lu %@", st, (unsigned long)eps.count, eps.count == 1 ? @"Folge" : @"Folgen"];
                if (eps.count) [shelves addObject:[SFShelf grid:head style:SFTileStyleLandscape items:eps]];
                NSInteger seasons = [nn(sc[@"countSeasons"]) integerValue];
                if (seasons > 1) {
                    NSMutableArray *other = [NSMutableArray new];
                    NSArray *named = arr(dict(sc[@"allSeasons"])[@"nodes"]);
                    NSString *showImg = [SFZDFParser image:dict(sc[@"teaser"]) big:NO], *showBig = [SFZDFParser image:dict(sc[@"teaser"]) big:YES];
                    for (NSInteger k = 0; k < seasons; k++) {
                        if (k == season) continue;
                        SFItem *f = [SFItem new];
                        f.kind = SFItemFolder; f.themeName = @"zdf"; f.source = @"zdf";
                        f.identifier = [NSString stringWithFormat:@"zdfseason:%@:%ld", canonical, (long)k];
                        // ZDF names seasons ("2026", "Staffel 3") or only numbers them; allSeasons is in the order of seasons(offset:)
                        f.title = [SFZDFParser seasonName:k < (NSInteger)named.count ? dict(named[k]) : nil] ?: [NSString stringWithFormat:@"Teil %ld", (long)k + 1];
                        f.image = showImg; f.backdrop = showBig;
                        f.style = SFTileStyleWide;
                        f.pageLoader = [self showLoader:canonical title:t season:k];
                        [other addObject:f];
                    }
                    [shelves insertObject:[SFShelf shelf:@"Weitere Staffeln" style:SFTileStyleWide items:other] atIndex:0];
                    // season tiles: image of the show, title = season name
                }
            }
            SFPage *p = [SFPage page:t theme:@"zdf" shelves:shelves];
            p.backdrop = [SFZDFParser image:dict(sc[@"teaser"]) big:YES];
            // season picker sits at the top (like streaming services), but focus starts on the episodes
            if (shelves.count > 1 && [[shelves[0] title] isEqualToString:@"Weitere Staffeln"]) p.focusShelf = 1;
            if (!shelves.count) p.emptyText = @"Aktuell sind keine Folgen verfügbar.";
            done(p, nil);
        }];
    };
}

// A category or brand page (MetaCollection, e.g. "Bares für Rares"): metaCollectionContent takes its
// id. Lists deliver it with the tile; a ref known only by canonical (dev command) asks for it once.
+ (SFPageLoader)categoryLoader:(NSString *)canonical id:(NSString *)mid title:(NSString *)title {
    return ^(SFPageDone done) {
        if (mid.length) { [self categoryContent:mid title:title done:done]; return; }
        [self gql:@"query M($c: String!) { metaCollectionByCanonical(canonical: $c) { id } }" vars:@{@"c": canonical} cache:86400 done:^(id d, NSError *e) {
            NSString *got = str(dict(dict(d)[@"metaCollectionByCanonical"])[@"id"]);
            if (!got.length) { done(nil, e ?: SFError(@"ZDF-Seite nicht gefunden.")); return; }
            [self categoryContent:got title:title done:done];
        }];
    };
}

+ (void)categoryContent:(NSString *)mid title:(NSString *)title done:(SFPageDone)done {
    NSString *q = [NSString stringWithFormat:@"query C($collectionId: String!, $input: MetaCollectionContentInput!) { metaCollectionContent(collectionId: $collectionId, input: $input) { smartCollections { %@ } } }", SFZDF_COLL_F];
    NSDictionary *input = @{@"appId": @"ffw-mt-web-879d5c17", @"filters": @{@"contentOwner": @[], @"fsk": @[], @"language": @[]},
                            @"pagination": @{@"first": @60, @"after": [NSNull null]}, @"user": @{@"abGroup": @"gruppe-d", @"userSegment": @"segment_0"},
                            @"tabId": [NSNull null]};
    [self gql:q vars:@{@"collectionId": mid, @"input": input} cache:1800 done:^(id d, NSError *e) {
        if (!d) { done(nil, e); return; }
        NSMutableArray *items = [NSMutableArray new];
        for (NSDictionary *c in arr(dict(dict(d)[@"metaCollectionContent"])[@"smartCollections"])) {
            SFItem *it = [self withLoader:[SFZDFParser itemFromNode:c]];
            if (it) [items addObject:it];
        }
        SFPage *p = [SFPage page:title theme:@"zdf" shelves:@[[SFShelf grid:[NSString stringWithFormat:@"%lu Sendungen", (unsigned long)items.count] style:SFTileStyleLandscape items:items]]];
        if (!items.count) p.emptyText = @"Keine Inhalte.";
        done(p, nil);
    }];
}

+ (SFPageLoader)homeLoader {
    SFPageLoader start = [self curatedLoader:@"mt2025-startseite-100" title:nil];
    return ^(SFPageDone done) {
        start(^(SFPage *p, NSError *e) {
            if (!p) { done(nil, e); return; }
            NSMutableArray *sh = [p.shelves mutableCopy];
            NSArray *cont = [[SFStore shared] continueWatching:20 source:@"zdf"];
            if (cont.count) [sh insertObject:[SFShelf shelf:@"Weiterschauen" style:SFTileStyleLandscape items:cont] atIndex:0];
            // the categories (the cluster of MetaCollections) further up: navigation
            for (NSUInteger k = 0; k < sh.count; k++) {
                SFShelf *s = sh[k];
                BOOL categories = s.items.count > 0;
                for (SFItem *i in s.items) if (![SFRefPrefix(i.identifier) isEqualToString:@"zdfmeta"]) categories = NO;
                if (categories && k > 2) { [sh removeObjectAtIndex:k]; [sh insertObject:s atIndex:MIN((NSUInteger)2, sh.count)]; break; }
            }
            p.shelves = sh; p.title = nil;
            done(p, nil);
        });
    };
}

#pragma mark Search

// searchDocuments: TOP_RESULTS = matching shows, ALL_RESULTS_EXCLUDING_TOP_RESULTS = videos (pages of 48)
+ (SFPageLoader)searchLoader:(NSString *)query {
    NSString *q = [NSString stringWithFormat:@"query Q($query: String!, $first: Int, $mode: SearchMode) { searchDocuments(query: $query, first: $first, mode: $mode) { results { item { __typename ... on Video { %@ } ... on ISmartCollection { %@ } ... on MetaCollection { %@ } } } } }", SFZDF_VIDEO_F, SFZDF_COLL_F, SFZDF_META_F];
    return ^(SFPageDone done) {
        __block NSArray *top = nil, *all = nil;
        __block NSError *err = nil;
        dispatch_group_t g = dispatch_group_create();
        NSArray *modes = @[@"TOP_RESULTS", @"ALL_RESULTS_EXCLUDING_TOP_RESULTS"];
        for (NSString *mode in modes) {
            dispatch_group_enter(g);
            [self gql:q vars:@{@"query": query ?: @"", @"first": [mode hasPrefix:@"TOP"] ? @12 : @48, @"mode": mode} cache:600 done:^(id d, NSError *e) {
                NSMutableArray *items = [NSMutableArray new];
                for (NSDictionary *r in arr(dict(dict(d)[@"searchDocuments"])[@"results"])) {
                    SFItem *it = [self withLoader:[SFZDFParser itemFromNode:dict(dict(r)[@"item"])]];
                    if (it) [items addObject:it];
                }
                if ([mode hasPrefix:@"TOP"]) top = d ? items : nil; else all = d ? items : nil;
                if (!d) err = e;
                dispatch_group_leave(g);
            }];
        }
        dispatch_group_notify(g, dispatch_get_main_queue(), ^{
            if (!top && !all) { done(nil, err ?: SFError(@"ZDF-Suche nicht erreichbar.")); return; }
            NSMutableArray *shows = [NSMutableArray new], *videos = [NSMutableArray new];
            NSMutableSet *seen = [NSMutableSet new];
            for (SFItem *it in [(top ?: @[]) arrayByAddingObjectsFromArray:all ?: @[]]) {
                if ([seen containsObject:it.identifier]) continue;
                [seen addObject:it.identifier];
                [(it.kind == SFItemFolder ? shows : videos) addObject:it];
            }
            NSMutableArray *shelves = [NSMutableArray new];
            if (shows.count) [shelves addObject:[SFShelf shelf:@"Sendungen" style:SFTileStyleLandscape items:shows]];
            if (videos.count) [shelves addObject:[SFShelf grid:@"Videos" style:SFTileStyleLandscape items:videos]];
            SFPage *p = [SFPage page:[NSString stringWithFormat:@"„%@“", query] theme:@"zdf" shelves:shelves];
            if (!shelves.count) p.emptyText = [NSString stringWithFormat:@"Keine Treffer für „%@“.", query];
            done(p, nil);
        });
    };
}

#pragma mark Stream

#pragma mark SFApp

+ (NSString *)appIdentifier { return @"zdf"; }
+ (NSString *)appName { return @"ZDF"; }
+ (NSString *)appSummary { return @"Mediathek, Sendungen und Live-TV"; }
+ (NSArray *)refPrefixes { return @[@"zdf", @"zdfshow", @"zdfmeta", @"zdfpage"]; }
+ (NSArray *)showRefPrefixes { return @[@"zdfshow"]; }
+ (NSColor *)homeTileColor { return SFHex(0x24272d); }
+ (NSInteger)homeTileLogoVariant { return 0; }
+ (NSString *)searchPlaceholder { return @"Sendungen und Videos suchen"; }
+ (void)configureTheme:(SFTheme *)t {
    // Anthracite, orange as signal colour.
    t.wordmark = @"ZDF"; t.logo = @"zdf"; t.logoVariant = 0;
    t.background = SFHex(0x121417);
    t.backgroundTop = SFHex(0x22262c);
    t.surface = SFHex(0x2a2e35);
    t.accent = SFHex(0xfa7d19);
    t.accentText = SFHex(0x111111);
    t.focus = SFHex(0xfa7d19);
    t.fontRegular = @"AvenirNext-Regular";
    t.fontMedium = @"AvenirNext-Medium";
    t.fontBold = @"AvenirNext-Bold";
    t.fontWordmark = @"AvenirNext-Heavy";
    t.corner = 4;
    t.headerMark = SFHeaderMarkBar;
}

// page of a show ref (zdfshow:…)
+ (SFPageLoader)showPageLoader:(NSString *)fullRef title:(NSString *)title {
    if (![SFRefPrefix(fullRef) isEqualToString:@"zdfshow"]) return nil;
    NSString *ref = SFRefID(fullRef);
    return [self showLoader:ref title:title season:0];
}

// newest episodes of a show ("Neue Folgen", automatic downloads)
+ (void)feed:(NSString *)fullRef done:(void (^)(NSArray *, NSError *))done {
    NSString *ref = SFRefID(fullRef), *title = nil;
    SFFeedFromPage([SFRefPrefix(fullRef) isEqualToString:@"zdfshow"] ? [self showLoader:ref title:nil season:0] : nil, done);
}

+ (void)resolve:(NSString *)ref done:(SFURLDone)done {
    NSString *p = SFRefPrefix(ref), *rid = SFRefID(ref);
    if ([p isEqualToString:@"zdf"]) [self resolve_zdf:rid done:done];
    else done(nil, SFError(@"Quelle nicht verfügbar"));
}

// The stream of a video: best URL, subtitles, and the region it is limited to (its geoLocation:
// "DE", "DACH"; nil = everywhere). No side effects - also used for the region probe of homeFeatures:.
+ (void)stream:(NSString *)canonical done:(void (^)(NSString *url, NSArray *subs, NSString *region, NSError *e))done {
    NSString *q = [NSString stringWithFormat:@"query V($canonical: String!) { videoByCanonical(canonical: $canonical) { %@ } }", SFZDF_VIDEO_F];
    [self gql:q vars:@{@"canonical": canonical} cache:300 done:^(id d, NSError *e) {
        NSDictionary *m = [SFZDFParser mainMedia:dict(dict(d)[@"videoByCanonical"])];
        NSString *tpl = str(m[@"ptmdTemplate"]);
        if (!tpl) { done(nil, nil, nil, e ?: SFError(@"Dieses Video ist (noch) nicht verfügbar.")); return; }
        NSString *url = [@"https://api.zdf.de" stringByAppendingString:[tpl stringByReplacingOccurrencesOfString:@"{playerId}" withString:kPlayer]];
        [self token:^(NSString *tok) {
            [SFNet getJSON:url headers:@{@"Api-Auth": [@"Bearer " stringByAppendingString:tok ?: @""]} cacheAge:0 done:^(id p, NSError *pe) {
                NSDictionary *st = [SFZDFParser streamIn:dict(p)];
                if (!st[@"url"]) { done(nil, nil, nil, pe ?: SFError(@"Kein abspielbares Format.")); return; }
                done(st[@"url"], st[@"subs"], SFZDFRegion(str(m[@"geoLocation"])), nil);
            }];
        }];
    }];
}

+ (void)resolve_zdf:(NSString *)canonical done:(SFURLDone)done {
    [self stream:canonical done:^(NSString *u, NSArray *subs, NSString *region, NSError *e) {
        if (!u) { done(nil, e); return; }
        SFSetMPVSource([NSURL URLWithString:u], @{@"subs": subs, @"alang": @"de"});   // the chosen one is always the main track (German)
        if (!region) { done([NSURL URLWithString:u], nil); return; }
        // geo-limited streams answer 403 outside the region -> check beforehand instead of a failed start
        [SFNet checkRegion:u expect:nil region:region done:^(BOOL ok) {
            if (ok) done([NSURL URLWithString:u], nil);
            else done(nil, SFError([region isEqualToString:@"DE"] ? @"Nur in Deutschland verfügbar." : [region isEqualToString:@"DACH"] ? @"Nur in Deutschland, Österreich und der Schweiz verfügbar." : @"In dieser Region nicht verfügbar."));
        }];
    }];
}

+ (BOOL)handleDevCommand:(NSString *)cmd arg:(NSString *)arg host:(id<SFPlayerHost>)host {
    if (![cmd isEqualToString:@"open"]) return NO;
    SFItem *f = [SFItem new]; f.kind = SFItemFolder; f.themeName = @"zdf";
    if ([arg hasPrefix:@"zdfmeta:"]) f.pageLoader = [self categoryLoader:SFRefID(arg) id:nil title:@"Test"];   // brand page (crash test)
    else if ([arg hasPrefix:@"zdfshow:"]) f.pageLoader = [self showLoader:SFRefID(arg) title:nil season:0];
    else return NO;
    SFOpenItem([host nav], f, nil, 0);
    return YES;
}

// tools/test-parse: the data of the GraphQL answer ({"data": ...} as recorded) by its root field -
// curated (curatedCollectionByCanonical), show (smartCollectionByCanonical), video (videoByCanonical),
// category (metaCollectionContent). ZDF dates are absolute.
+ (NSArray *)parseFixture:(id)j kind:(NSString *)kind {
    NSDictionary *d = dict(dict(j)[@"data"]) ?: dict(j);
    NSMutableArray *o = [NSMutableArray new];
    void (^items)(NSArray *) = ^(NSArray *a) { for (SFItem *i in a) [o addObject:[@"item " stringByAppendingString:SFCanonicalItem(i, NO)]]; };
    if ([kind isEqualToString:@"curated"]) {
        for (NSDictionary *c in [SFZDFParser clustersIn:dict(d[@"curatedCollectionByCanonical"])]) { [o addObject:[@"cluster " stringByAppendingString:c[@"title"]]]; items(c[@"items"]); }
    } else if ([kind isEqualToString:@"video"]) {
        SFItem *i = [SFZDFParser videoItem:dict(d[@"videoByCanonical"])];
        items(i ? @[i] : @[]);
    } else if ([kind isEqualToString:@"show"]) {
        NSDictionary *sc = dict(d[@"smartCollectionByCanonical"]);
        for (NSDictionary *sn in arr(dict(sc[@"allSeasons"])[@"nodes"])) [o addObject:[NSString stringWithFormat:@"season %@", [SFZDFParser seasonName:dict(sn)] ?: @"-"]];
        NSMutableArray *eps = [NSMutableArray new];
        for (NSDictionary *v in arr(dict(dict(arr(dict(sc[@"seasons"])[@"nodes"]).firstObject)[@"episodes"])[@"nodes"])) { SFItem *i = [SFZDFParser videoItem:v]; if (i) [eps addObject:i]; }
        SFItem *movie = [SFZDFParser videoItem:dict(sc[@"video"])];
        items(movie ? [eps arrayByAddingObject:movie] : eps);
    } else if ([kind isEqualToString:@"category"]) {
        NSMutableArray *a = [NSMutableArray new];
        for (NSDictionary *c in arr(dict(d[@"metaCollectionContent"])[@"smartCollections"])) { SFItem *i = [SFZDFParser itemFromNode:c]; if (i) [a addObject:i]; }
        items(a);
    } else return nil;
    return o;
}

// Home: the curated start page (cached) - its first cluster is the editors' lead, the
// "Livestreams" cluster carries the channels (kind live)
+ (void)homeFeatures:(void (^)(NSDictionary *))done {
    [self curatedLoader:@"mt2025-startseite-100" title:nil](^(SFPage *p, NSError *e) {
        NSMutableDictionary *features = [SFHomeFeaturesFromPage(p, 0) mutableCopy] ?: [NSMutableDictionary new];
        if (!p) [features removeAllObjects];   // failed: keep what ZDF featured before
        // News: the editors' news page, its lead cluster "Aktuelle Nachrichten-Sendungen" (heute, heute journal …)
        [self curatedLoader:@"nachrichten-politik-news-100" title:nil](^(SFPage *np, NSError *ne) {
            if (np) features[SFHomeTopicNews] = SFHomeFeaturesLeadVideos(np) ?: @[];
            // geo-limited items (Germany only: ZDF itself, ZDFneo, many films; DACH) are left out of Home where
            // they can't play: Home needs to know the region before it shows them - probe one stream per
            // region nobody has checked yet
            NSMutableDictionary *probes = [NSMutableDictionary new];   // region -> item
            for (NSArray *items in features.allValues)
                for (SFItem *i in items)
                    if (i.geoRegion && SFRefID(i.resolverRef) && !probes[i.geoRegion] && [SFNet stateOfRegion:i.geoRegion] == SFRegionUnknown) probes[i.geoRegion] = i;
            dispatch_group_t g = dispatch_group_create();
            for (SFItem *probe in probes.allValues) {
                dispatch_group_enter(g);
                [self stream:SFRefID(probe.resolverRef) done:^(NSString *u, NSArray *subs, NSString *region, NSError *se) {
                    if (!u || !region) { dispatch_group_leave(g); return; }
                    [SFNet checkRegion:u expect:nil region:region done:^(BOOL ok) { dispatch_group_leave(g); }];
                }];
            }
            dispatch_group_notify(g, dispatch_get_main_queue(), ^{ done(features); });
        });
    });
}
@end
