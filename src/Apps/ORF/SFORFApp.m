#import "SFDownloads.h"
#import "SFFollows.h"
#import "SFIconArt.h"
#import "SFORFApp.h"
#import "SFJSON.h"
#import "SFEngine.h"
#import "SFNet.h"
#import "SFStore.h"

static NSString *const kAPI = @"https://api-tvthek.orf.at/api/v4.3";
// Publicly known app key (MServer OrfOnConstants.AUTH / yt-dlp).
static NSString *const kAuth = @"Basic b3JmX29uX3Y0MzpqRlJzYk5QRmlQU3h1d25MYllEZkNMVU41WU5aMjhtdA==";


static NSDate *isoDate(NSString *s) { return SFDateFromISO8601(s); }   // offset honoured (SFCore)

@implementation SFORFApp

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

static NSArray *listItems(id j) {
    NSDictionary *d = dict(j);
    return arr(d[@"_items"]) ?: arr(dict(d[@"_embedded"])[@"items"]) ?: arr(j) ?: @[];
}

+ (NSString *)image:(NSDictionary *)it big:(BOOL)big {
    NSDictionary *pu = dict(dict(dict(dict(it[@"_embedded"])[@"image"]))[@"public_urls"]);
    NSString *k1 = big ? @"highlight_teaser" : @"player";
    return str(dict(pu[k1])[@"url"]) ?: str(dict(pu[@"highlight_teaser"])[@"url"]) ?: str(dict(pu[@"reference"])[@"url"]);
}

+ (SFItem *)episodeItem:(NSDictionary *)e {
    // Highlights: {id, position, _embedded:{video_item:{_embedded:{item:{…Episode…}}}}}
    NSDictionary *inner = dict(dict(dict(dict(dict(e)[@"_embedded"])[@"video_item"])[@"_embedded"])[@"item"]);
    if (inner) e = inner;
    if (!dict(e) || !nn(e[@"id"])) return nil;
    SFItem *i = [SFItem new];
    NSString *eid = [nn(e[@"id"]) description];
    i.kind = SFItemVideo;
    i.identifier = [@"orf:" stringByAppendingString:eid];
    i.resolverRef = i.identifier;
    i.title = str(e[@"title"]) ?: str(e[@"headline"]);
    i.plot = str(e[@"description"]) ?: str(e[@"teaser_text"]);
    i.image = [self image:e big:NO];
    i.backdrop = [self image:e big:YES];
    i.channel = str(e[@"profile_title"]) ?: str(e[@"genre_title"]);
    NSString *ph = str(dict(dict(e[@"_links"])[@"profile"])[@"href"]);
    if (ph.length && str(e[@"profile_title"])) i.showRef = [@"orfprofile:" stringByAppendingString:ph.lastPathComponent];
    i.date = isoDate(str(e[@"date"]));
    i.duration = [nn(e[@"duration_seconds"]) doubleValue];
    i.source = @"orf"; i.themeName = @"orf";
    i.style = SFTileStyleLandscape;
    i.drm = [nn(e[@"is_drm_protected"]) boolValue];
    if (i.drm) i.badge = @"DRM";
    NSMutableArray *sub = [NSMutableArray new];
    if (str(e[@"genre_title"])) [sub addObject:str(e[@"genre_title"])];
    if (i.date) [sub addObject:SFFormatDateShort(i.date)];
    i.subtitle = [sub componentsJoinedByString:@" · "];
    return i;
}

+ (NSArray *)episodeItems:(id)json {
    NSMutableArray *a = [NSMutableArray new];
    for (id e in listItems(json)) { SFItem *it = [self episodeItem:e]; if (it) [a addObject:it]; }
    return a;
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
            NSArray *eps = [self episodeItems:j];
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
        f.image = [self image:p big:NO];
        f.backdrop = [self image:p big:YES];
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
        NSMutableArray *a = [NSMutableArray new];
        NSDictionary *names = @{@"orf1": @"ORF 1", @"orf2": @"ORF 2", @"orf3": @"ORF III", @"orfs": @"ORF SPORT +", @"live_special": @"ORF Spezial"};
        for (NSString *k in @[@"orf1", @"orf2", @"orf3", @"orfs", @"live_special"]) {
            NSDictionary *it = dict(arr(dict(dict(j)[k])[@"items"]).firstObject);
            if (!it || !nn(it[@"id"])) continue;
            SFItem *i = [SFItem new];
            NSString *lid = [nn(it[@"id"]) description];
            i.kind = SFItemLive;
            i.identifier = [@"orflive:" stringByAppendingString:k];
            i.resolverRef = [@"orflive:" stringByAppendingString:lid];
            i.title = names[k];
            i.subtitle = str(it[@"title"]);
            i.plot = str(it[@"description"]);
            i.image = [self image:it big:NO];
            i.backdrop = [self image:it big:YES];
            i.source = @"orf"; i.themeName = @"orf"; i.style = SFTileStyleLandscape;
            i.drm = [nn(it[@"is_drm_protected"]) boolValue];
            i.badge = i.drm ? @"DRM" : @"LIVE";
            [a addObject:i];
        }
        done(a);
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
                    NSArray *items = [self episodeItems:lj];
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
            NSMutableArray *items = [[self episodeItems:@{@"_items": arr(eps[@"items"]) ?: @[]}] mutableCopy];
            NSString *next = str(eps[@"next"]);
            if (!next) { finish(items); return; }
            [self get:next cache:600 done:^(id j2, NSError *e2) {
                NSMutableSet *seen = [NSMutableSet new];
                for (SFItem *i in items) [seen addObject:i.identifier];
                id more = dict(dict(j2)[@"episodes"]) ?: dict(dict(dict(j2)[@"search"])[@"episodes"]) ?: j2;
                for (SFItem *i in [self episodeItems:@{@"_items": arr(dict(more)[@"items"]) ?: listItems(more)}])
                    if (![seen containsObject:i.identifier]) [items addObject:i];
                finish(items);
            }];
        }];
    };
}

#pragma mark Stream

+ (NSString *)hlsFrom:(NSDictionary *)obj drm:(BOOL *)drm {
    NSArray *hls = arr(dict(obj[@"sources"])[@"hls"]);
    NSString *any = nil;
    for (NSDictionary *s in hls) {
        if (!dict(s)) continue;
        if ([nn(s[@"is_drm_protected"]) boolValue] || [str(s[@"quality_key"]) hasSuffix:@"DRM"]) { if (drm) *drm = YES; continue; }
        NSString *q = str(s[@"quality_key"]), *src = str(s[@"src"]);
        // adaptive QXA only: single qualities now deliver a "not available" clip
        if ([q isEqualToString:@"QXA"] && src) return src;
        if ([nn(s[@"is_adaptive_stream"]) boolValue] && !any) any = src;
    }
    return any;
}

#pragma mark SFApp

+ (NSString *)appIdentifier { return @"orf"; }
+ (NSString *)appName { return @"ORF"; }
+ (NSString *)appSummary { return @"ORF ON, Sendungen und Live"; }
+ (NSArray *)refPrefixes { return @[@"orf", @"orflive", @"orfprofile", @"orfaz", @"orfgenre"]; }
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
    else if ([p isEqualToString:@"orflive"]) [self resolve_orflive:rid done:done];
    else done(nil, SFError(@"Quelle nicht verfügbar"));
}

+ (void)resolve_orf:(NSString *)eid done:(SFURLDone)done {

    [self get:[@"/episode/" stringByAppendingString:eid] cache:300 done:^(id j, NSError *e) {
        NSDictionary *ep = dict(j);
        if (!ep) { done(nil, e); return; }
        BOOL drm = NO;
        NSDictionary *src = ep;
        NSString *u = [self hlsFrom:ep drm:&drm];
        if (!u) {   // segmented show: play the first part
            NSDictionary *seg = dict(arr(dict(ep[@"_embedded"])[@"segments"]).firstObject);
            if (seg) { u = [self hlsFrom:seg drm:&drm]; src = seg; }
        }
        if (!u) { done(nil, SFError(drm ? @"Kopiergeschützt (DRM) – auf diesem Mac nicht abspielbar." : @"Kein abspielbarer Stream.")); return; }
        // subtitles: _embedded.subtitle.vtt_url (of the object actually played);
        // ai_subtitles = machine-generated -> mark as "automatic"
        NSString *vtt = str(dict(dict(src[@"_embedded"])[@"subtitle"])[@"vtt_url"]);
        NSArray *subs = vtt ? @[@{@"lang": @"de", @"url": vtt, @"kind": [nn(src[@"ai_subtitles"]) boolValue] ? @"auto" : @"manual"}] : @[];
        SFSetMPVSource([NSURL URLWithString:u], @{@"subs": subs, @"alang": @"de"});
        done([NSURL URLWithString:u], nil);
    }];
}

+ (void)resolve_orflive:(NSString *)lid done:(SFURLDone)done {

    [self get:[@"/livestream/" stringByAppendingString:lid] cache:0 done:^(id j, NSError *e) {
        BOOL drm = NO;
        NSString *u = dict(j) ? [self hlsFrom:j drm:&drm] : nil;
        if (!u) { done(nil, e ?: SFError(drm ? @"Dieser Sender ist kopiergeschützt (DRM) und auf diesem Mac nicht abspielbar." : @"Livestream nicht verfügbar.")); return; }
        done([NSURL URLWithString:u], nil);
    }];
}

@end
