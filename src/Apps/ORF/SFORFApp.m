#import "SFDownloads.h"
#import "SFFollows.h"
#import "SFIconArt.h"
#import "SFORFApp.h"
#import "SFORFParser.h"
#import "SFJSON.h"
#import "SFEngine.h"
#import "SFNet.h"
#import "SFCurl.h"
#import "SFStore.h"

static NSString *const kAPI = @"https://api-tvthek.orf.at/api/v4.3";
// Publicly known app key (MServer OrfOnConstants.AUTH / yt-dlp).
static NSString *const kAuth = @"Basic b3JmX29uX3Y0MzpqRlJzYk5QRmlQU3h1d25MYllEZkNMVU41WU5aMjhtdA==";


@implementation SFORFApp

// ORF's API, images and video CDNs speak AES-GCM/TLS 1.3 only, which 10.9's TLS stack can't
+ (void)start {
    for (NSString *d in @[@"api-tvthek.orf.at", @".sf.apa.at", @".mdn.ors.at"]) {
        if ([d hasPrefix:@"."]) SFMarkDomainNeedsCurl(d); else SFMarkHostNeedsCurl(d);
    }
}

// Sofa's own entry points (no source image): icon tile instead of an empty area
+ (SFItem *)navFolder:(NSString *)title ident:(NSString *)ident icon:(NSString *)icon loader:(SFPageLoader)loader {
    SFItem *f = [self folder:title ident:ident loader:loader];
    f.image = SFIconArt(icon, @"orf");
    return f;
}

+ (void)get:(NSString *)pathOrURL cache:(NSTimeInterval)age done:(SFJSONDone)done {
    NSString *u = [pathOrURL hasPrefix:@"http"] ? pathOrURL : [kAPI stringByAppendingString:pathOrURL];
    [SFNet getJSON:u headers:@{@"Authorization": kAuth} cacheAge:age done:done];
}

static NSString *href(id link) {
    if ([link isKindOfClass:[NSString class]]) return link;
    return str(dict(link)[@"href"]);
}

static NSArray *listItems(id j) {   // profiles/genres lists (episodes: SFORFParser)
    NSDictionary *d = dict(j);
    return arr(d[@"_items"]) ?: arr(dict(d[@"_embedded"])[@"items"]) ?: arr(j) ?: @[];
}

#pragma mark Pages

+ (SFItem *)folder:(NSString *)title ident:(NSString *)ident loader:(SFPageLoader)l {
    SFItem *f = [SFItem new];
    f.kind = SFItemFolder; f.title = title; f.identifier = ident;
    f.themeName = @"orf"; f.source = @"orf"; f.style = SFTileStyleWide;
    f.pageLoader = l;
    return f;
}

+ (SFPageLoader)profileLoader:(NSString *)pid title:(NSString *)knownTitle {
    return ^(SFPageDone done) {
        // no title given (show found via a lookup, where `channel` was only the genre): the profile names itself
        void (^withTitle)(void (^)(NSString *)) = ^(void (^next)(NSString *)) {
            if (knownTitle.length) { next(knownTitle); return; }
            [self get:[@"/profile/" stringByAppendingString:pid] cache:86400 done:^(id j, NSError *e) { next(str(dict(j)[@"title"])); }];
        };
        withTitle(^(NSString *title) {
        [self get:[NSString stringWithFormat:@"/profile/%@/episodes?limit=100", pid] cache:900 done:^(id j, NSError *e) {
            NSArray *eps = [SFORFParser episodeItems:j];
            if (!j) { done(nil, e); return; }
            SFPage *p = [SFPage page:title theme:@"orf" shelves:@[[SFShelf grid:[NSString stringWithFormat:@"%lu %@", (unsigned long)eps.count, eps.count == 1 ? @"Folge" : @"Folgen"] style:SFTileStyleLandscape items:eps]]];
            if (!eps.count) p.emptyText = @"Aktuell sind keine Folgen verfügbar.";
            done(p, nil);
        }];
        });
    };
}

+ (NSArray *)profileItems:(id)json {
    NSMutableArray *a = [NSMutableArray new];
    for (NSDictionary *p in listItems(json)) {
        if (!dict(p) || !nn(p[@"id"])) continue;
        NSString *pid = [nn(p[@"id"]) description];
        NSString *t = str(p[@"title"]);
        SFItem *f = [self folder:t ident:[@"orfprofile:" stringByAppendingString:pid] loader:[self profileLoader:pid title:t]];
        f.style = SFTileStyleLandscape;
        f.image = [SFORFParser image:p big:NO];
        f.backdrop = [SFORFParser image:p big:YES];
        f.plot = str(p[@"description"]);
        [a addObject:f];
    }
    return a;
}

+ (SFPageLoader)genresLoader {
    return ^(SFPageDone done) {
        [self get:@"/page/start/genres" cache:6 * 3600 done:^(id j, NSError *e) {
            NSMutableArray *gs = [NSMutableArray new];
            for (NSDictionary *g in listItems(j)) {
                if (!dict(g) || !nn(g[@"id"])) continue;
                NSString *gid = [nn(g[@"id"]) description], *t = str(g[@"title"]);
                [gs addObject:[self folder:t ident:[@"orfgenre:" stringByAppendingString:gid] loader:^(SFPageDone d2) {
                    [self get:[NSString stringWithFormat:@"/genre/%@/profiles?limit=100", gid] cache:3600 done:^(id pj, NSError *pe) {
                        NSArray *ps = [self profileItems:pj];
                        if (!pj) { d2(nil, pe); return; }
                        d2([SFPage page:t theme:@"orf" shelves:@[[SFShelf grid:[NSString stringWithFormat:@"%lu Sendungen", (unsigned long)ps.count] style:SFTileStyleLandscape items:ps]]], nil);
                    }];
                }]];
            }
            if (!j) { done(nil, e); return; }
            done([SFPage page:@"Kategorien" theme:@"orf" shelves:@[[SFShelf grid:nil style:SFTileStyleWide items:gs]]], nil);
        }];
    };
}

+ (SFPageLoader)azLoader {
    return ^(SFPageDone done) {
        NSMutableArray *letters = [NSMutableArray new];
        for (NSString *L in [@"A B C D E F G H I J K L M N O P Q R S T U V W X Y Z 0" componentsSeparatedByString:@" "]) {
            NSString *title = [L isEqualToString:@"0"] ? @"0–9" : L;
            [letters addObject:[self folder:title ident:[@"orfaz:" stringByAppendingString:L] loader:^(SFPageDone d2) {
                [self get:[NSString stringWithFormat:@"/profiles/lettergroup/%@?limit=200", L] cache:6 * 3600 done:^(id j, NSError *e) {
                    NSArray *ps = [self profileItems:j];
                    if (!j) { d2(nil, e); return; }
                    d2([SFPage page:[@"Sendungen " stringByAppendingString:title] theme:@"orf" shelves:@[[SFShelf grid:nil style:SFTileStyleLandscape items:ps]]], nil);
                }];
            }]];
        }
        done([SFPage page:@"Sendungen A–Z" theme:@"orf" shelves:@[[SFShelf grid:nil style:SFTileStyleWide items:letters]]], nil);
    };
}

+ (void)liveItems:(void (^)(NSArray *items))done {
    [self get:@"/livestreams" cache:60 done:^(id j, NSError *e) {
        done([SFORFParser liveItemsIn:j at:[NSDate date]]);   // nil = request failed (not: no channels)
    }];
}

+ (SFPageLoader)homeLoader {
    return ^(SFPageDone done) {
        [self get:@"/page/start" cache:900 done:^(id j, NSError *e) {
            NSArray *lanes = arr(j);
            if (!lanes) { done(nil, e ?: SFError(@"ORF ON nicht erreichbar.")); return; }
            NSMutableArray *wanted = [NSMutableArray new];
            for (NSDictionary *l in lanes) {
                if (!dict(l)) continue;
                NSString *t = str(l[@"type"]);
                if (!([t isEqualToString:@"lane"] || [t isEqualToString:@"mostviewed"] || [t isEqualToString:@"hero"])) continue;
                NSString *h = href(dict(l[@"_links"])[@"self"]);
                if (!h) continue;
                [wanted addObject:@[h, str(l[@"title"]) ?: ([t isEqualToString:@"hero"] ? @"Highlights" : @""), str(l[@"layout"]) ?: @""]];
                if (wanted.count >= 16) break;
            }
            NSMutableArray *results = [NSMutableArray new];
            for (NSUInteger k = 0; k < wanted.count; k++) [results addObject:[NSNull null]];
            dispatch_group_t g = dispatch_group_create();
            for (NSUInteger k = 0; k < wanted.count; k++) {
                dispatch_group_enter(g);
                NSString *h = wanted[k][0];
                NSString *u = [h stringByAppendingString:[h rangeOfString:@"?"].location == NSNotFound ? @"?limit=20" : @"&limit=20"];
                [self get:u cache:900 done:^(id lj, NSError *le) {
                    NSArray *items = [SFORFParser episodeItems:lj];
                    if (items.count) results[k] = items;
                    dispatch_group_leave(g);
                }];
            }
            __block NSArray *live = @[];
            dispatch_group_enter(g);
            [self liveItems:^(NSArray *items) { live = items; dispatch_group_leave(g); }];
            dispatch_group_notify(g, dispatch_get_main_queue(), ^{
                NSMutableArray *shelves = [NSMutableArray new];
                NSArray *cont = [[SFStore shared] continueWatching:20 source:@"orf"];
                if (cont.count) [shelves addObject:[SFShelf shelf:@"Weiterschauen" style:SFTileStyleLandscape items:cont]];
                for (NSUInteger k = 0; k < wanted.count; k++) {
                    if (results[k] == [NSNull null]) continue;
                    [shelves addObject:[SFShelf shelf:wanted[k][1] style:SFTileStyleLandscape items:results[k]]];
                    if (k == 0) {
                        if (live.count) [shelves addObject:[SFShelf shelf:@"Live" style:SFTileStyleLandscape items:live]];
                        [shelves addObject:[SFShelf shelf:@"Entdecken" style:SFTileStyleWide items:@[
                            [self navFolder:@"Sendungen A–Z" ident:@"orfnav:az" icon:@"az" loader:[self azLoader]],
                            [self navFolder:@"Kategorien" ident:@"orfnav:genres" icon:@"grid" loader:[self genresLoader]]]]];
                    }
                }
                done([SFPage page:nil theme:@"orf" shelves:shelves], nil);
            });
        }];
    };
}

#pragma mark Search

// /search/{q}: shows (episodes), two pages of 30. Segments/archive are left out.
+ (SFPageLoader)searchLoader:(NSString *)query {
    return ^(SFPageDone done) {
        [self get:[NSString stringWithFormat:@"/search/%@?limit=30", [SFNet escape:query]] cache:600 done:^(id j, NSError *e) {
            NSDictionary *eps = dict(dict(dict(j)[@"search"])[@"episodes"]);
            if (!eps && !dict(j)) { done(nil, e ?: SFError(@"ORF-Suche nicht erreichbar.")); return; }
            void (^finish)(NSArray *) = ^(NSArray *items) {
                NSInteger total = [nn(eps[@"total"]) integerValue];
                NSString *h = total > (NSInteger)items.count ? [NSString stringWithFormat:@"Sendungen · %lu von %ld", (unsigned long)items.count, (long)total]
                                                             : [NSString stringWithFormat:@"%lu Sendungen", (unsigned long)items.count];
                SFPage *p = [SFPage page:[NSString stringWithFormat:@"„%@“", query] theme:@"orf"
                                 shelves:items.count ? @[[SFShelf grid:h style:SFTileStyleLandscape items:items]] : @[]];
                if (!items.count) p.emptyText = [NSString stringWithFormat:@"Keine Treffer für „%@“.", query];
                done(p, nil);
            };
            NSMutableArray *items = [[SFORFParser episodeItems:@{@"_items": arr(eps[@"items"]) ?: @[]}] mutableCopy];
            NSString *next = str(eps[@"next"]);
            if (!next) { finish(items); return; }
            [self get:next cache:600 done:^(id j2, NSError *e2) {
                NSMutableSet *seen = [NSMutableSet new];
                for (SFItem *i in items) [seen addObject:i.identifier];
                id more = dict(dict(j2)[@"episodes"]) ?: dict(dict(dict(j2)[@"search"])[@"episodes"]) ?: j2;
                for (SFItem *i in [SFORFParser episodeItems:@{@"_items": arr(dict(more)[@"items"]) ?: listItems(more)}])
                    if (![seen containsObject:i.identifier]) [items addObject:i];
                finish(items);
            }];
        }];
    };
}

#pragma mark SFApp

// tools/test-parse: list (episodes/segments/highlights), live (/livestreams), stream (an
// episode/segment). ORF dates are absolute. `live` is parsed at a moment inside the recorded
// answer's programme (tests/fixtures/orf/live-livestreams: 2026-11-06 morning).
+ (NSArray *)parseFixture:(id)j kind:(NSString *)kind {
    NSMutableArray *o = [NSMutableArray new];
    NSArray *items;
    if ([kind isEqualToString:@"list"]) items = [SFORFParser episodeItems:j];
    else if ([kind isEqualToString:@"live"]) items = [SFORFParser liveItemsIn:j at:SFDateFromISO8601(@"2026-11-06T07:20:00+01:00")];
    else if ([kind isEqualToString:@"stream"]) {
        NSDictionary *st = [SFORFParser streamIn:dict(j)];
        [o addObject:[NSString stringWithFormat:@"stream %@ drm=%@", st[@"url"] ?: @"-", st[@"drm"] ? @"yes" : @"no"]];
        for (NSDictionary *sub in st[@"subs"]) [o addObject:[NSString stringWithFormat:@"sub %@ %@ %@", sub[@"lang"], sub[@"kind"], sub[@"url"]]];
        return o;
    } else return nil;
    for (SFItem *i in items) [o addObject:[@"item " stringByAppendingString:SFCanonicalItem(i, NO)]];
    return o;
}

+ (NSString *)appIdentifier { return @"orf"; }
+ (NSString *)appName { return @"ORF"; }
+ (NSString *)appSummary { return @"ORF ON, Sendungen und Live"; }
+ (NSArray *)refPrefixes { return @[@"orf", @"orfseg", @"orflive", @"orfprofile", @"orfaz", @"orfgenre"]; }
+ (NSArray *)showRefPrefixes { return @[@"orfprofile"]; }
+ (NSColor *)homeTileColor { return SFHex(0xffffff); }
+ (NSInteger)homeTileLogoVariant { return 0; }
+ (NSString *)searchPlaceholder { return @"Sendungen und Videos suchen"; }
+ (void)configureTheme:(SFTheme *)t {
    // Light: white/light grey, red as accent.
    t.wordmark = @"ORF"; t.logo = @"orf"; t.logoVariant = 0;
    t.light = YES;
    t.background = SFHex(0xeeeff1);
    t.backgroundTop = SFHex(0xffffff);
    t.surface = SFHex(0xdadce0);
    t.text = SFHex(0x141414);
    t.textDim = SFHexA(0x141414, 0.74);   // readable on light grey at TV distance (0.6 was too weak)
    t.accent = SFHex(0xd8001b);
    t.accentText = SFHex(0xffffff);
    t.focus = SFHex(0xd8001b);
    t.fontWordmark = @"HelveticaNeue-CondensedBlack";
    t.corner = 6;
    t.headerMark = SFHeaderMarkBar;
}

// page of a show ref (orfprofile:…)
+ (SFPageLoader)showPageLoader:(NSString *)fullRef title:(NSString *)title {
    if (![SFRefPrefix(fullRef) isEqualToString:@"orfprofile"]) return nil;
    NSString *ref = SFRefID(fullRef);
    return [self profileLoader:ref title:title];
}

// newest episodes of a show ("Neue Folgen", automatic downloads)
+ (void)feed:(NSString *)fullRef done:(void (^)(NSArray *, NSError *))done {
    NSString *ref = SFRefID(fullRef), *title = nil;
    SFFeedFromPage([SFRefPrefix(fullRef) isEqualToString:@"orfprofile"] ? [self profileLoader:ref title:nil] : nil, done);
}

// Lists (highlights, genres) send a short episode object without profile_title, so those items
// have no showRef - the full episode names its show (profile_title + _links.profile; seen
// 2026-11-05 with "Vienna Killing (1/3)")
+ (void)showRefForItem:(SFItem *)item done:(void (^)(NSString *))done {

    NSString *eid = [item.identifier hasPrefix:@"orf:"] ? [item.identifier substringFromIndex:4] : nil;
    if (!eid.length) { done(nil); return; }
    [self get:[@"/episode/" stringByAppendingString:eid] cache:3600 done:^(id j, NSError *e) {
        NSDictionary *ep = dict(j);
        NSString *ph = str(dict(dict(ep[@"_links"])[@"profile"])[@"href"]);
        NSString *ref = ph.length && str(ep[@"profile_title"]) ? [@"orfprofile:" stringByAppendingString:ph.lastPathComponent] : nil;
        SFMain(^{ done(ref); });
    }];
}

+ (void)resolve:(NSString *)ref done:(SFURLDone)done {
    NSString *p = SFRefPrefix(ref), *rid = SFRefID(ref);
    if ([p isEqualToString:@"orf"]) [self resolve_orf:rid done:done];
    else if ([p isEqualToString:@"orfseg"]) [self resolve_path:[@"/segment/" stringByAppendingString:rid] done:done];
    else if ([p isEqualToString:@"orflive"]) [self resolve_orflive:rid done:done];
    else done(nil, SFError(@"Quelle nicht verfügbar"));
}

+ (void)resolve_orf:(NSString *)eid done:(SFURLDone)done { [self resolve_path:[@"/episode/" stringByAppendingString:eid] done:done]; }

// an episode or a segment: both carry sources + _embedded.subtitle
+ (void)resolve_path:(NSString *)path done:(SFURLDone)done {
    [self get:path cache:300 done:^(id j, NSError *e) {
        NSDictionary *ep = dict(j);
        if (!ep) { done(nil, e); return; }
        NSDictionary *st = [SFORFParser streamIn:ep];
        // a show split into parts without own sources: play the first part (the old API's shape;
        // no recorded v4.3 answer has it - every episode seen carries its own sources)
        if (!st[@"url"] && !st[@"drm"]) st = [SFORFParser streamIn:dict(arr(dict(ep[@"_embedded"])[@"segments"]).firstObject)];
        NSURL *u = str(st[@"url"]) ? [NSURL URLWithString:st[@"url"]] : nil;
        if (!u) { done(nil, SFError(st[@"drm"] ? @"Kopiergeschützt (DRM) – auf diesem Mac nicht abspielbar." : @"Kein abspielbarer Stream.")); return; }
        SFSetMPVSource(u, @{@"subs": st[@"subs"], @"alang": @"de"});
        done(u, nil);
    }];
}

+ (void)resolve_orflive:(NSString *)lid done:(SFURLDone)done {

    [self get:[@"/livestream/" stringByAppendingString:lid] cache:0 done:^(id j, NSError *e) {
        NSDictionary *st = [SFORFParser streamIn:dict(j)];
        NSString *u = str(st[@"url"]);
        if (!u) { done(nil, e ?: SFError(st[@"drm"] ? @"Dieser Sender ist kopiergeschützt (DRM) und auf diesem Mac nicht abspielbar." : @"Livestream nicht verfügbar.")); return; }
        done([NSURL URLWithString:u], nil);
    }];
}

// Home: the start page's "hero" lane (ORF marks its lead placement in the data) + the live channels
+ (void)homeFeatures:(void (^)(NSDictionary *))done {
    [self get:@"/page/start" cache:900 done:^(id j, NSError *e) {
        NSString *hero = nil, *news = nil;
        for (NSDictionary *l in arr(j)) {
            NSString *link = href(dict(dict(l)[@"_links"])[@"self"]);
            if (!hero && [str(dict(l)[@"type"]) isEqualToString:@"hero"]) hero = link;
            // the start page's news lane ("News - Aktuelle Meldungen aus Österreich und aller Welt");
            // ORF marks it only by its title
            NSString *t = str(dict(l)[@"title"]);
            if (!news && t.length && ([t caseInsensitiveCompare:@"News"] == NSOrderedSame || [t caseInsensitiveCompare:@"Nachrichten"] == NSOrderedSame)) news = link;   // t.length: [nil compare:] is 0 = "same"
        }
        // a topic left out (request failed) keeps what ORF featured before; an empty list clears it
        NSMutableDictionary *r = [NSMutableDictionary new];
        void (^lane)(NSString *, NSString *, NSInteger, dispatch_block_t) = ^(NSString *url, NSString *topic, NSInteger limit, dispatch_block_t next) {
            if (!url) { next(); return; }
            NSString *u = [url stringByAppendingFormat:@"%@limit=%ld", [url rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&", (long)limit];
            [self get:u cache:600 done:^(id lj, NSError *le) {
                if (lj && !le) r[topic] = [SFORFParser episodeItems:lj] ?: @[];
                next();
            }];
        };
        [self liveItems:^(NSArray *live) {
            if (live) r[SFHomeTopicLive] = live;
            lane(hero, SFHomeTopicHighlights, 20, ^{ lane(news, SFHomeTopicNews, 12, ^{ done(r); }); });
        }];
    }];
}
@end
