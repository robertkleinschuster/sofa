#import "SFDownloads.h"
#import "SFFollows.h"
#import "SFProviderZDF.h"
#import "SFJSON.h"
#import "SFEngine.h"
#import "SFNet.h"
#import "SFStore.h"

static NSString *const kGQL = @"https://api.zdf.de/graphql";
static NSString *const kPlayer = @"android_native_6";


// GraphQL-Fragmente (frei formulierte Queries; persisted hashes brechen bei Redeploys)
#define VIDEO_F @"canonical title editorialDate teaser { description imageWithoutLogo { layouts { dim768X432 dim1280X720 } } } smartCollection { title canonical } currentMedia { nodes { ptmdTemplate ... on VodMedia { duration geoLocation vodMediaType } ... on LiveMedia { geoLocation } } }"
#define COLL_F  @"canonical title collectionType teaser { description imageWithoutLogo { layouts { dim768X432 dim1280X720 } } }"

static NSDate *isoDate(NSString *s) {
    if (s.length < 19) return nil;
    static NSDateFormatter *df; static dispatch_once_t o;
    dispatch_once(&o, ^{
        df = [NSDateFormatter new];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
    });
    @synchronized (df) { return [df dateFromString:[s substringToIndex:19]]; }
}

@implementation SFProviderZDF

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

+ (NSString *)img:(NSDictionary *)teaser big:(BOOL)big {
    NSDictionary *l = dict(dict(dict(teaser)[@"imageWithoutLogo"])[@"layouts"]);
    return big ? (str(l[@"dim1280X720"]) ?: str(l[@"dim768X432"])) : (str(l[@"dim768X432"]) ?: str(l[@"dim1280X720"]));
}

+ (SFItem *)videoItem:(NSDictionary *)v {
    NSString *can = str(v[@"canonical"]);
    if (!can) return nil;
    SFItem *i = [SFItem new];
    i.kind = SFItemVideo;
    i.identifier = [@"zdf:" stringByAppendingString:can];
    i.resolverRef = i.identifier;
    i.title = str(v[@"title"]);
    i.plot = str(dict(v[@"teaser"])[@"description"]);
    i.image = [self img:dict(v[@"teaser"]) big:NO];
    i.backdrop = [self img:dict(v[@"teaser"]) big:YES];
    i.channel = str(dict(v[@"smartCollection"])[@"title"]);
    NSString *sc = str(dict(v[@"smartCollection"])[@"canonical"]);
    if (sc.length) i.showRef = [@"zdfshow:" stringByAppendingString:sc];
    i.date = isoDate(str(v[@"editorialDate"]));
    i.source = @"zdf"; i.themeName = @"zdf";
    i.style = SFTileStyleLandscape;
    NSArray *media = arr(dict(v[@"currentMedia"])[@"nodes"]);
    BOOL live = [can rangeOfString:@"live"].location != NSNotFound && media.count && ![dict(media.firstObject)[@"duration"] doubleValue];
    for (NSDictionary *m in media) {
        if (![str(m[@"vodMediaType"]) isEqualToString:@"DEFAULT"] && m[@"vodMediaType"]) continue;
        i.duration = [nn(m[@"duration"]) doubleValue];
        if ([str(m[@"geoLocation"]) isEqualToString:@"DE"]) i.badge = @"DE";
        break;
    }
    if (live) { i.kind = SFItemLive; i.badge = @"LIVE"; }
    NSMutableArray *sub = [NSMutableArray new];
    if (i.channel && ![i.channel isEqualToString:i.title]) [sub addObject:i.channel];
    if (i.date && !live) [sub addObject:SFFormatDateShort(i.date)];
    i.subtitle = [sub componentsJoinedByString:@" · "];
    return i;
}

+ (SFItem *)collectionItem:(NSDictionary *)c type:(NSString *)type {
    NSString *can = str(c[@"canonical"]);
    if (!can) return nil;
    SFItem *i = [SFItem new];
    i.kind = SFItemFolder;
    i.title = str(c[@"title"]);
    i.plot = str(dict(c[@"teaser"])[@"description"]);
    i.image = [self img:dict(c[@"teaser"]) big:NO];
    i.backdrop = [self img:dict(c[@"teaser"]) big:YES];
    i.source = @"zdf"; i.themeName = @"zdf";
    i.style = SFTileStyleLandscape;
    if ([type isEqualToString:@"MetaCollection"]) {
        i.identifier = [@"zdfmeta:" stringByAppendingString:can];
        i.pageLoader = [self categoryLoader:can title:i.title];
    } else if ([type isEqualToString:@"CuratedCollection"]) {
        i.identifier = [@"zdfpage:" stringByAppendingString:can];
        i.pageLoader = [self curatedLoader:can title:i.title];
    } else {
        i.identifier = [@"zdfshow:" stringByAppendingString:can];
        i.subtitle = [type hasPrefix:@"Movie"] ? @"Film" : nil;
        i.pageLoader = [self showLoader:can title:i.title season:0];
    }
    return i;
}

+ (SFItem *)itemFromNode:(NSDictionary *)n {
    NSString *t = str(n[@"__typename"]);
    if ([t isEqualToString:@"Video"]) return [self videoItem:n];
    if ([t hasSuffix:@"SmartCollection"] || [t isEqualToString:@"MetaCollection"] || [t isEqualToString:@"CuratedCollection"])
        return [self collectionItem:n type:t];
    return nil;   // ExternalLink, ZappingChannel, Catalog
}

#pragma mark Seiten

+ (SFPageLoader)curatedLoader:(NSString *)canonical title:(NSString *)title {
    // items(first:) erlaubt seit 11/2026 nur 1…26 (sonst leere Cluster + Fehler)
    NSString *q = [NSString stringWithFormat:@"query P($canonical: String!, $first: Int) { curatedCollectionByCanonical(canonical: $canonical) { title modules { nodes { __typename ... on StaticHorizontalCluster { title items(first: $first) { nodes { __typename ... on Video { %@ } ... on ISmartCollection { %@ } ... on MetaCollection { canonical title teaser { description imageWithoutLogo { layouts { dim768X432 dim1280X720 } } } } ... on CuratedCollection { canonical title teaser { description imageWithoutLogo { layouts { dim768X432 dim1280X720 } } } } } } } } } } }", VIDEO_F, COLL_F];
    return ^(SFPageDone done) {
        [self gql:q vars:@{@"canonical": canonical, @"first": @26} cache:900 done:^(id d, NSError *e) {
            NSDictionary *cc = dict(dict(d)[@"curatedCollectionByCanonical"]);
            if (!cc) { done(nil, e ?: SFError(@"ZDF-Seite nicht gefunden.")); return; }
            NSMutableArray *shelves = [NSMutableArray new];
            for (NSDictionary *m in arr(dict(cc[@"modules"])[@"nodes"])) {
                if (![str(m[@"__typename"]) isEqualToString:@"StaticHorizontalCluster"]) continue;
                NSMutableArray *items = [NSMutableArray new];
                for (NSDictionary *n in arr(dict(m[@"items"])[@"nodes"])) { SFItem *it = [self itemFromNode:n]; if (it) [items addObject:it]; }
                if (!items.count) continue;
                BOOL folders = YES;
                for (SFItem *it in items) if (it.kind != SFItemFolder) folders = NO;
                BOOL meta = [[items.firstObject identifier] hasPrefix:@"zdfmeta:"];
                [shelves addObject:[SFShelf shelf:str(m[@"title"]) style:meta ? SFTileStyleWide : SFTileStyleLandscape items:items]];
                (void)folders;
            }
            done([SFPage page:title ?: str(cc[@"title"]) theme:@"zdf" shelves:shelves], nil);
        }];
    };
}

+ (SFPageLoader)showLoader:(NSString *)canonical title:(NSString *)title season:(NSInteger)season {
    NSString *q = [NSString stringWithFormat:@"query S($canonical: String!, $first: Int, $seasonIndex: Int) { smartCollectionByCanonical(canonical: $canonical) { __typename title collectionType teaser { description imageWithoutLogo { layouts { dim1280X720 } } } ... on ISeriesSmartCollection { countSeasons countEpisodes allSeasons: seasons(first: 60) { nodes { number title } } seasons(first: 1, offset: $seasonIndex) { nodes { number title countEpisodes episodes(first: $first, sortBy: [{field: EDITORIAL_DATE, direction: DESC}]) { nodes { %@ } } } } } ... on MovieSmartCollection { video { %@ } } } }", VIDEO_F, VIDEO_F];
    return ^(SFPageDone done) {
        [self gql:q vars:@{@"canonical": canonical, @"first": @100, @"seasonIndex": @(season)} cache:900 done:^(id d, NSError *e) {
            NSDictionary *sc = dict(dict(d)[@"smartCollectionByCanonical"]);
            if (!sc) { done(nil, e ?: SFError(@"Sendung nicht gefunden.")); return; }
            NSString *t = title ?: str(sc[@"title"]);
            NSMutableArray *shelves = [NSMutableArray new];
            NSDictionary *movie = dict(sc[@"video"]);
            if (movie) {
                SFItem *it = [self videoItem:movie];
                if (it) [shelves addObject:[SFShelf shelf:@"Film" style:SFTileStyleLandscape items:@[it]]];
            }
            NSDictionary *sn = dict(arr(dict(sc[@"seasons"])[@"nodes"]).firstObject);
            if (sn) {
                NSMutableArray *eps = [NSMutableArray new];
                for (NSDictionary *v in arr(dict(sn[@"episodes"])[@"nodes"])) { SFItem *it = [self videoItem:v]; if (it) [eps addObject:it]; }
                NSString *st = str(sn[@"title"]) ?: [NSString stringWithFormat:@"%@", nn(sn[@"number"]) ?: @""];
                NSInteger cnt = [nn(sn[@"countEpisodes"]) integerValue];
                NSString *head = cnt > (NSInteger)eps.count ? [NSString stringWithFormat:@"%@ · neueste %lu von %ld", st, (unsigned long)eps.count, (long)cnt]
                                                            : [NSString stringWithFormat:@"%@ · %lu %@", st, (unsigned long)eps.count, eps.count == 1 ? @"Folge" : @"Folgen"];
                if (eps.count) [shelves addObject:[SFShelf grid:head style:SFTileStyleLandscape items:eps]];
                NSInteger seasons = [nn(sc[@"countSeasons"]) integerValue];
                if (seasons > 1) {
                    NSMutableArray *other = [NSMutableArray new];
                    NSArray *named = arr(dict(sc[@"allSeasons"])[@"nodes"]);
                    NSString *showImg = [self img:dict(sc[@"teaser"]) big:NO], *showBig = [self img:dict(sc[@"teaser"]) big:YES];
                    for (NSInteger k = 0; k < seasons; k++) {
                        if (k == season) continue;
                        SFItem *f = [SFItem new];
                        f.kind = SFItemFolder; f.themeName = @"zdf"; f.source = @"zdf";
                        f.identifier = [NSString stringWithFormat:@"zdfseason:%@:%ld", canonical, (long)k];
                        // ZDF benennt Staffeln oft nach Jahr („2026“) – den echten Namen zeigen, Bild der Sendung
                        NSDictionary *sn2 = k < (NSInteger)named.count ? dict(named[k]) : nil;
                        NSString *nm = str(sn2[@"title"]);
                        if (!nm.length && nn(sn2[@"number"])) nm = [NSString stringWithFormat:@"%@", sn2[@"number"]];
                        BOOL isYear = nm.length == 4 && [nm rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound;
                        f.title = nm.length ? (isYear || [nm.lowercaseString hasPrefix:@"staffel"] ? nm : [@"Staffel " stringByAppendingString:nm])
                                            : [NSString stringWithFormat:@"Staffel %ld", (long)(seasons - k)];
                        f.image = showImg; f.backdrop = showBig;
                        f.style = SFTileStyleWide;
                        f.pageLoader = [self showLoader:canonical title:t season:k];
                        [other addObject:f];
                    }
                    [shelves insertObject:[SFShelf shelf:@"Weitere Staffeln" style:SFTileStyleWide items:other] atIndex:0];
                    // Staffel-Kacheln: Bild der Sendung, Titel = Staffelname
                }
            }
            SFPage *p = [SFPage page:t theme:@"zdf" shelves:shelves];
            p.backdrop = [self img:dict(sc[@"teaser"]) big:YES];
            // Staffelauswahl steht oben (wie bei Streamingdiensten), der Fokus startet aber auf den Folgen
            if (shelves.count > 1 && [[shelves[0] title] isEqualToString:@"Weitere Staffeln"]) p.focusShelf = 1;
            if (!shelves.count) p.emptyText = @"Aktuell sind keine Folgen verfügbar.";
            done(p, nil);
        }];
    };
}

+ (SFPageLoader)categoryLoader:(NSString *)collectionId title:(NSString *)title {
    NSString *q = [NSString stringWithFormat:@"query C($collectionId: String!, $input: MetaCollectionContentInput!) { metaCollectionContent(collectionId: $collectionId, input: $input) { smartCollections { %@ } } }", COLL_F];
    NSDictionary *input = @{@"appId": @"ffw-mt-web-879d5c17", @"filters": @{@"contentOwner": @[], @"fsk": @[], @"language": @[]},
                            @"pagination": @{@"first": @60, @"after": [NSNull null]}, @"user": @{@"abGroup": @"gruppe-d", @"userSegment": @"segment_0"},
                            @"tabId": [NSNull null]};
    return ^(SFPageDone done) {
        // metaCollectionContent braucht die interne ID (UUID); Markenseiten (z. B. „Bares für Rares“)
        // kennen wir nur per canonical -> erst auflösen, sonst kommt eine leere Liste.
        BOOL isID = [collectionId rangeOfString:@"^[0-9a-f]{8}-[0-9a-f]{4}-" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound;
        if (!isID) {
            // Einmal auflösen, dann direkt Inhalte laden (ohne erneute Prüfung: sonst Endlosschleife,
            // falls die ID anders aussieht – zwei Abstürze am 2026-11-03)
            [self gql:@"query M($c: String!) { metaCollectionByCanonical(canonical: $c) { id } }" vars:@{@"c": collectionId} cache:86400 done:^(id d, NSError *e) {
                NSString *mid = str(dict(dict(d)[@"metaCollectionByCanonical"])[@"id"]);
                if (!mid.length || [mid isEqualToString:collectionId]) { done(nil, e ?: SFError(@"ZDF-Seite nicht gefunden.")); return; }
                [self categoryContent:mid title:title query:q input:input done:done];
            }];
            return;
        }
        [self categoryContent:collectionId title:title query:q input:input done:done];
    };
}

+ (void)categoryContent:(NSString *)collectionId title:(NSString *)title query:(NSString *)q input:(NSDictionary *)input done:(SFPageDone)done {
    {
        [self gql:q vars:@{@"collectionId": collectionId, @"input": input} cache:1800 done:^(id d, NSError *e) {
            NSArray *scs = arr(dict(dict(d)[@"metaCollectionContent"])[@"smartCollections"]);
            if (!d) { done(nil, e); return; }
            NSMutableArray *items = [NSMutableArray new];
            for (NSDictionary *c in scs) {
                NSString *ct = str(c[@"collectionType"]);
                SFItem *it = [self collectionItem:c type:[ct.lowercaseString hasPrefix:@"movie"] ? @"MovieSmartCollection" : @"SmartCollection"];
                if (it) [items addObject:it];
            }
            SFPage *p = [SFPage page:title theme:@"zdf" shelves:@[[SFShelf grid:[NSString stringWithFormat:@"%lu Sendungen", (unsigned long)items.count] style:SFTileStyleLandscape items:items]]];
            if (!items.count) p.emptyText = @"Keine Inhalte.";
            done(p, nil);
        }];
    };
}

+ (SFPageLoader)homeLoader {
    SFPageLoader start = [self curatedLoader:@"mt2025-startseite-100" title:nil];
    return ^(SFPageDone done) {
        start(^(SFPage *p, NSError *e) {
            if (!p) { done(nil, e); return; }
            NSMutableArray *sh = [p.shelves mutableCopy];
            NSArray *cont = [[SFStore shared] continueWatching:20 source:@"zdf"];
            if (cont.count) [sh insertObject:[SFShelf shelf:@"Weiterschauen" style:SFTileStyleLandscape items:cont] atIndex:0];
            // Kategorien weiter nach oben (Navigation)
            for (NSUInteger k = 0; k < sh.count; k++) {
                SFShelf *s = sh[k];
                if ([s.title isEqualToString:@"Kategorien"] && k > 2) { [sh removeObjectAtIndex:k]; [sh insertObject:s atIndex:MIN((NSUInteger)2, sh.count)]; break; }
            }
            p.shelves = sh; p.title = nil;
            done(p, nil);
        });
    };
}

#pragma mark Suche

// searchDocuments: TOP_RESULTS = passende Sendungen, ALL_RESULTS_EXCLUDING_TOP_RESULTS = Videos (Seiten à 48)
+ (SFPageLoader)searchLoader:(NSString *)query {
    NSString *q = [NSString stringWithFormat:@"query Q($query: String!, $first: Int, $mode: SearchMode) { searchDocuments(query: $query, first: $first, mode: $mode) { results { item { __typename ... on Video { %@ } ... on ISmartCollection { %@ } ... on MetaCollection { canonical title teaser { description imageWithoutLogo { layouts { dim768X432 dim1280X720 } } } } } } } }", VIDEO_F, COLL_F];
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
                    SFItem *it = [self itemFromNode:dict(dict(r)[@"item"])];
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

+ (void)registerResolver {
    // Abo-Feed ("Neue Folgen automatisch laden")
    SFRegisterFeedFromLoader(@"zdfshow", ^SFPageLoader(NSString *ref) { return [self showLoader:ref title:nil season:0]; });
    SFRegisterShowPage(@"zdfshow", ^SFPageLoader(NSString *ref, NSString *title) { return [self showLoader:ref title:title season:0]; });
    SFRegisterResolver(@"zdf", ^(NSString *canonical, SFURLDone done) {
        NSString *q = [NSString stringWithFormat:@"query V($canonical: String!) { videoByCanonical(canonical: $canonical) { %@ } }", VIDEO_F];
        [self gql:q vars:@{@"canonical": canonical} cache:300 done:^(id d, NSError *e) {
            NSDictionary *v = dict(dict(d)[@"videoByCanonical"]);
            NSArray *media = arr(dict(v[@"currentMedia"])[@"nodes"]);
            NSDictionary *m = nil;
            for (NSDictionary *x in media) if (!str(x[@"vodMediaType"]) || [str(x[@"vodMediaType"]) isEqualToString:@"DEFAULT"]) { m = x; break; }
            NSString *tpl = str(m[@"ptmdTemplate"]);
            if (!tpl) { done(nil, e ?: SFError(@"Dieses Video ist (noch) nicht verfügbar.")); return; }
            NSString *url = [@"https://api.zdf.de" stringByAppendingString:[tpl stringByReplacingOccurrencesOfString:@"{playerId}" withString:kPlayer]];
            [self token:^(NSString *tok) {
                [SFNet getJSON:url headers:@{@"Api-Auth": [@"Bearer " stringByAppendingString:tok ?: @""]} cacheAge:0 done:^(id p, NSError *pe) {
                    NSString *best = nil, *hls = nil; int bestScore = -1;
                    for (NSDictionary *pl in arr(dict(p)[@"priorityList"])) {
                        for (NSDictionary *f in arr(pl[@"formitaeten"])) {
                            NSString *mime = str(f[@"mimeType"]);
                            for (NSDictionary *qq in arr(f[@"qualities"])) {
                                NSString *u = nil;
                                for (NSDictionary *t in arr(dict(qq[@"audio"])[@"tracks"]))
                                    if ([str(t[@"class"]) isEqualToString:@"main"] || !t[@"class"]) { u = str(t[@"uri"]); break; }
                                if (!u) continue;
                                if ([mime isEqualToString:@"application/x-mpegURL"]) { if (!hls) hls = u; continue; }
                                if (![mime isEqualToString:@"video/mp4"]) continue;
                                int h = [nn(qq[@"highestVerticalResolution"]) intValue];
                                int sc = h == 720 ? 1000 : (h < 720 ? h : 700 - (h - 720) / 10);
                                if (sc > bestScore) { bestScore = sc; best = u; }
                            }
                        }
                    }
                    NSString *u = best ?: hls;
                    if (!u) { done(nil, pe ?: SFError(@"Kein abspielbares Format.")); return; }
                    // Untertitel: PTMD captions[] (class hoh = für Hörgeschädigte), WebVTT für mpv
                    NSMutableArray *subs = [NSMutableArray new];
                    for (NSDictionary *c in arr(dict(p)[@"captions"])) {
                        if (![str(dict(c)[@"format"]) isEqualToString:@"webvtt"] || !str(c[@"uri"])) continue;
                        [subs addObject:@{@"lang": str(c[@"language"]) ?: @"deu", @"url": str(c[@"uri"]), @"kind": @"manual"}];
                    }
                    SFSetMPVSource([NSURL URLWithString:u], @{@"subs": subs, @"alang": @"de"});   // gewählt ist immer die Hauptspur (deutsch)
                    // Geo: /de/-Pfade liefern außerhalb DE 403 -> vorab prüfen statt Fehlstart
                    if ([u rangeOfString:@"/de/"].location != NSNotFound || [str(m[@"geoLocation"]) isEqualToString:@"DE"]) {
                        [SFNet checkRegion:u expect:nil done:^(BOOL ok) {
                            if (ok) done([NSURL URLWithString:u], nil);
                            else done(nil, SFError(@"Nur in Deutschland verfügbar."));
                        }];
                        return;
                    }
                    done([NSURL URLWithString:u], nil);
                }];
            }];
        }];
    });
}
@end
