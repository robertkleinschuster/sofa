#import "SFDownloads.h"
#import "SFFollows.h"
#import "SFIconArt.h"
#import "SFProviderARD.h"
#import "SFNet.h"
#import "SFStore.h"

static NSString *const kGW = @"https://api.ardmediathek.de/page-gateway";

static id nn(id v) { return (v == [NSNull null]) ? nil : v; }
static NSString *str(id v) { v = nn(v); return [v isKindOfClass:[NSString class]] ? v : nil; }
static NSArray *arr(id v) { v = nn(v); return [v isKindOfClass:[NSArray class]] ? v : nil; }
static NSDictionary *dict(id v) { v = nn(v); return [v isKindOfClass:[NSDictionary class]] ? v : nil; }

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

static NSString *imageURL(NSDictionary *images, NSString *key, int width) {
    images = dict(images);
    NSDictionary *im = dict(images[key]) ?: dict(images[@"aspect16x9"]) ?: dict(images[@"aspect16x7"]);
    NSString *src = str(im[@"src"]);
    return [src stringByReplacingOccurrencesOfString:@"{width}" withString:[NSString stringWithFormat:@"%d", width]];
}

@implementation SFProviderARD

+ (SFPageLoader)loaderForURL:(NSString *)url title:(NSString *)title {
    return ^(SFPageDone done) {
        [SFNet getJSON:url headers:nil cacheAge:900 done:^(id j, NSError *e) {
            if (![j isKindOfClass:[NSDictionary class]]) { done(nil, e ?: SFError(@"ARD Mediathek nicht erreichbar.")); return; }
            SFPage *p = [self pageFromGateway:j title:title ?: str(j[@"title"])];
            done(p, nil);
        }];
    };
}

+ (SFItem *)itemFromTeaser:(NSDictionary *)t {
    NSString *type = str(t[@"type"]);
    if (!dict(t)) return nil;
    NSDictionary *target = dict(dict(t[@"links"])[@"target"]);
    NSString *tid = str(target[@"id"]) ?: str(t[@"id"]);
    if (!type || !tid || [type isEqualToString:@"external"]) return nil;
    NSString *title = str(t[@"shortTitle"]) ?: str(t[@"longTitle"]) ?: str(t[@"title"]);
    if ([title hasSuffix:@"(Audiodeskription)"] || [title hasSuffix:@"(mit Gebärdensprache)"]) return nil;
    SFItem *i = [SFItem new];
    i.title = title;
    i.source = @"ard";
    i.themeName = @"ard";
    i.image = imageURL(nn(t[@"images"]), @"aspect16x9", 640);
    i.backdrop = imageURL(nn(t[@"images"]), @"aspect16x9", 1280);
    NSString *pub = str(dict(t[@"publicationService"])[@"name"]);
    NSString *show = str(dict(t[@"show"])[@"title"]);
    i.channel = show ?: pub;
    i.date = isoDate(str(t[@"broadcastedOn"]));
    i.duration = [nn(t[@"duration"]) doubleValue];
    i.style = SFTileStyleLandscape;
    if ([type isEqualToString:@"ondemand"] || [type isEqualToString:@"broadcastMainClip"]) {
        i.kind = SFItemVideo;
        i.identifier = [@"ard:" stringByAppendingString:tid];
        i.resolverRef = i.identifier;
        NSMutableArray *sub = [NSMutableArray new];
        if (show && pub) [sub addObject:pub];
        if (i.date) [sub addObject:SFFormatDateShort(i.date)];
        i.subtitle = [sub componentsJoinedByString:@" · "];
        NSDate *until = isoDate(str(t[@"availableTo"]));
        if (until && [until timeIntervalSinceNow] < 3 * 86400) i.badge = @"BALD WEG";
    } else if ([type isEqualToString:@"live"]) {
        i.kind = SFItemLive;
        i.identifier = [@"ardlive:" stringByAppendingString:tid];
        i.resolverRef = [@"ard:" stringByAppendingString:tid];
        i.badge = @"LIVE";
        i.subtitle = pub;
    } else if ([type isEqualToString:@"show"]) {
        i.kind = SFItemFolder;
        i.identifier = [@"ardshow:" stringByAppendingString:tid];
        i.subtitle = pub;
        NSString *showTitle = title;
        i.pageLoader = [self showLoader:tid title:showTitle];
    } else if ([type isEqualToString:@"compilation"] || [type isEqualToString:@"editorialPage"] || [type isEqualToString:@"region"]) {
        NSString *href = str(target[@"href"]);
        if (!href) return nil;
        i.kind = SFItemFolder;
        i.identifier = [@"ardpage:" stringByAppendingString:tid];
        href = [href stringByReplacingOccurrencesOfString:@"embedded=false" withString:@"embedded=true"];
        if ([href rangeOfString:@"embedded="].location == NSNotFound) href = [href stringByAppendingString:[href rangeOfString:@"?"].location != NSNotFound ? @"&embedded=true" : @"?embedded=true"];
        i.pageLoader = [self loaderForURL:href title:title];
    } else {
        return nil;
    }
    return i;
}

+ (SFPage *)pageFromGateway:(NSDictionary *)j title:(NSString *)title {
    NSMutableArray *shelves = [NSMutableArray new];
    for (NSDictionary *w in arr(j[@"widgets"])) {
        if (!dict(w)) continue;
        NSMutableArray *items = [NSMutableArray new];
        for (NSDictionary *t in arr(w[@"teasers"])) {
            SFItem *it = [self itemFromTeaser:t];
            if (it) [items addObject:it];
        }
        if (!items.count) continue;
        NSString *wt = str(w[@"title"]);
        NSString *type = str(w[@"type"]);
        BOOL folders = YES;
        for (SFItem *it in items) if (it.kind != SFItemFolder) { folders = NO; break; }
        SFTileStyle st = folders && ![type isEqualToString:@"gridlist"] ? SFTileStyleWide : SFTileStyleLandscape;
        SFShelf *sh = [type isEqualToString:@"gridlist"] && items.count > 8
            ? [SFShelf grid:wt style:SFTileStyleLandscape items:items]
            : [SFShelf shelf:wt style:st items:items];
        [shelves addObject:sh];
    }
    SFPage *p = [SFPage page:title theme:@"ard" shelves:shelves];
    if (!shelves.count) p.emptyText = @"Hier gibt es gerade keine Inhalte.";
    return p;
}

+ (SFPageLoader)showLoader:(NSString *)showId title:(NSString *)title {
    return ^(SFPageDone done) {
        NSString *u = [NSString stringWithFormat:@"%@/widgets/ard/asset/%@?pageNumber=0&pageSize=96&embedded=true", kGW, showId];
        [SFNet getJSON:u headers:nil cacheAge:900 done:^(id j, NSError *e) {
            if (!dict(j)) { done(nil, e); return; }
            NSMutableArray *items = [NSMutableArray new];
            for (NSDictionary *t in arr(j[@"teasers"])) { SFItem *it = [self itemFromTeaser:t]; if (it) [items addObject:it]; }
            NSInteger total = [nn(dict(j[@"pagination"])[@"totalElements"]) integerValue];
            NSString *h = total > (NSInteger)items.count ? [NSString stringWithFormat:@"Neueste %lu von %ld Folgen", (unsigned long)items.count, (long)total]
                                                         : [NSString stringWithFormat:@"%lu %@", (unsigned long)items.count, items.count == 1 ? @"Folge" : @"Folgen"];
            SFPage *p = [SFPage page:title ?: str(j[@"title"]) theme:@"ard" shelves:@[[SFShelf grid:h style:SFTileStyleLandscape items:items]]];
            if (!items.count) p.emptyText = @"Aktuell sind keine Folgen verfügbar.";
            done(p, nil);
        }];
    };
}

+ (SFItem *)folder:(NSString *)title url:(NSString *)url image:(NSString *)img {
    SFItem *i = [SFItem new];
    i.kind = SFItemFolder; i.title = title; i.themeName = @"ard"; i.source = @"ard";
    i.identifier = [@"ardnav:" stringByAppendingString:title];
    i.pageLoader = [self loaderForURL:url title:title];
    i.image = img ?: SFIconArt([title rangeOfString:@"A–Z"].location != NSNotFound ? @"az" : @"grid", @"ard");   // Navigationskacheln ohne Quellbild
    i.style = SFTileStyleWide;
    return i;
}

+ (SFPageLoader)homeLoader {
    return ^(SFPageDone done) {
        [SFNet getJSON:[kGW stringByAppendingString:@"/pages/ard/home?embedded=true"] headers:nil cacheAge:600 done:^(id j, NSError *e) {
            if (![j isKindOfClass:[NSDictionary class]]) { done(nil, e ?: SFError(@"ARD Mediathek nicht erreichbar.")); return; }
            SFPage *p = [self pageFromGateway:j title:nil];
            NSMutableArray *shelves = [p.shelves mutableCopy];
            // Lokale Abos + Weiterschauen vorne, Navigation (Rubriken / A–Z) als eigene Reihe
            NSArray *cont = [[SFStore shared] continueWatching:20 source:@"ard"];
            NSMutableArray *front = [NSMutableArray new];
            if (cont.count) [front addObject:[SFShelf shelf:@"Weiterschauen" style:SFTileStyleLandscape items:cont]];
            NSArray *nav = @[
                [self folder:@"Sendungen A–Z" url:[kGW stringByAppendingString:@"/pages/ard/editorial/experiment-a-z?embedded=true"] image:nil],
                [self folder:@"Filme" url:[kGW stringByAppendingString:@"/pages/ard/editorial/filme?embedded=true"] image:nil],
                [self folder:@"Serien" url:[kGW stringByAppendingString:@"/pages/ard/editorial/serien?embedded=true"] image:nil],
                [self folder:@"Dokus" url:[kGW stringByAppendingString:@"/pages/ard/editorial/dokus?embedded=true"] image:nil],
                [self folder:@"Shows & Comedy" url:[kGW stringByAppendingString:@"/pages/ard/editorial/shows_comedy?embedded=true"] image:nil],
                [self folder:@"Nachrichten" url:[kGW stringByAppendingString:@"/pages/ard/editorial/tagesschau?embedded=true"] image:nil],
                [self folder:@"Kultur" url:[kGW stringByAppendingString:@"/pages/ard/editorial/kultur?embedded=true"] image:nil],
                [self folder:@"Kinder & Familie" url:[kGW stringByAppendingString:@"/pages/ard/editorial/kinderfamilie?embedded=true"] image:nil],
            ];
            [front addObject:[SFShelf shelf:@"Entdecken" style:SFTileStyleWide items:nav]];
            [shelves insertObjects:front atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(MIN(1, shelves.count), front.count)]];
            p.shelves = shelves;
            done(p, nil);
        }];
    };
}

// Suche: Sendungen (search/grouping) + Videos (search/vod)
+ (SFPageLoader)searchLoader:(NSString *)query {
    return ^(SFPageDone done) {
        NSString *q = [SFNet escape:query];
        __block id shows = nil, vods = nil;
        __block NSError *err = nil;
        dispatch_group_t g = dispatch_group_create();
        dispatch_group_enter(g);
        [SFNet getJSON:[NSString stringWithFormat:@"%@/widgets/ard/search/grouping?searchString=%@&pageNumber=0&pageSize=24", kGW, q] headers:nil cacheAge:600 done:^(id j, NSError *e) {
            shows = dict(j); if (!j) err = e; dispatch_group_leave(g);
        }];
        dispatch_group_enter(g);
        [SFNet getJSON:[NSString stringWithFormat:@"%@/widgets/ard/search/vod?searchString=%@&pageNumber=0&pageSize=60", kGW, q] headers:nil cacheAge:600 done:^(id j, NSError *e) {
            vods = dict(j); if (!j) err = e; dispatch_group_leave(g);
        }];
        dispatch_group_notify(g, dispatch_get_main_queue(), ^{
            if (!shows && !vods) { done(nil, err ?: SFError(@"ARD-Suche nicht erreichbar.")); return; }
            NSMutableArray *shelves = [NSMutableArray new];
            NSMutableArray *a = [NSMutableArray new], *b = [NSMutableArray new];
            for (NSDictionary *t in arr(dict(shows)[@"teasers"])) { SFItem *it = [self itemFromTeaser:t]; if (it) [a addObject:it]; }
            for (NSDictionary *t in arr(dict(vods)[@"teasers"])) { SFItem *it = [self itemFromTeaser:t]; if (it) [b addObject:it]; }
            for (SFItem *it in a) it.style = SFTileStyleLandscape;
            if (a.count) [shelves addObject:[SFShelf shelf:@"Sendungen" style:SFTileStyleLandscape items:a]];
            NSInteger total = [nn(dict(dict(vods)[@"pagination"])[@"totalElements"]) integerValue];
            NSString *h = total > (NSInteger)b.count ? [NSString stringWithFormat:@"Videos · beste %lu von %ld", (unsigned long)b.count, (long)total] : @"Videos";
            if (b.count) [shelves addObject:[SFShelf grid:h style:SFTileStyleLandscape items:b]];
            SFPage *p = [SFPage page:[NSString stringWithFormat:@"„%@“", query] theme:@"ard" shelves:shelves];
            if (!shelves.count) p.emptyText = [NSString stringWithFormat:@"Keine Treffer für „%@“.", query];
            done(p, nil);
        });
    };
}

+ (void)registerResolver {
    // Abo-Feed ("Neue Folgen automatisch laden")
    SFRegisterFeedFromLoader(@"ardshow", ^SFPageLoader(NSString *ref) { return [self showLoader:ref title:nil]; });
    SFRegisterShowPage(@"ardshow", ^SFPageLoader(NSString *ref, NSString *title) { return [self showLoader:ref title:title]; });
    SFRegisterResolver(@"ard", ^(NSString *itemId, SFURLDone done) {
        NSString *u = [NSString stringWithFormat:@"%@/pages/ard/item/%@?embedded=true&mcV6=true", kGW, itemId];
        [SFNet getJSON:u headers:nil cacheAge:300 done:^(id j, NSError *e) {
            if (![j isKindOfClass:[NSDictionary class]]) { done(nil, e); return; }
            NSDictionary *mc = nil;
            for (NSDictionary *w in arr(dict(j)[@"widgets"])) {
                if (!dict(w)) continue;
                NSString *t = str(w[@"type"]);
                if ([t hasPrefix:@"player_"]) { mc = dict(dict(w[@"mediaCollection"])[@"embedded"]); if (mc) break; }
            }
            if (!mc) { done(nil, SFError(@"Dieser Beitrag ist (noch) nicht abspielbar.")); return; }
            NSDictionary *best = nil; int bestScore = -1; NSString *hls = nil;
            for (NSDictionary *s in arr(mc[@"streams"])) {
                if (!dict(s)) continue;
                if (![str(s[@"kind"]) isEqualToString:@"main"]) continue;
                for (NSDictionary *m in arr(s[@"media"])) {
                    if (!dict(m)) continue;
                    NSArray *auds = arr(m[@"audios"]);
                    NSString *ak = auds.count ? str(dict(auds[0])[@"kind"]) : @"standard";
                    if (![ak isEqualToString:@"standard"]) continue;
                    NSString *mime = str(m[@"mimeType"]);
                    if ([mime isEqualToString:@"application/vnd.apple.mpegurl"]) { if (!hls) hls = str(m[@"url"]); continue; }
                    if (![mime isEqualToString:@"video/mp4"]) continue;
                    if (![str(m[@"videoCodec"]) isEqualToString:@"H.264"]) continue;   // H.265 kann 10.9 nicht
                    int v = [nn(m[@"maxVResolutionPx"]) intValue];
                    int sc = v == 720 ? 1000 : (v < 720 ? v : 700 - (v - 720) / 10);
                    if (sc > bestScore) { bestScore = sc; best = m; }
                }
            }
            NSString *url = best ? str(best[@"url"]) : hls;
            if ([url hasPrefix:@"//"]) url = [@"https:" stringByAppendingString:url];
            if (!url) { done(nil, SFError(@"Kein abspielbares Format (nur H.265/DRM).")); return; }
            // Geo: gesperrte Inhalte liefern sonst einen 30-s-Platzhalterclip
            NSDictionary *geo = dict(mc[@"geoBlocking"]);
            NSString *check = str(geo[@"regionCheckUrl"]);
            if (!check) { done([NSURL URLWithString:url], nil); return; }
            NSString *region = str(geo[@"regionName"]) ?: @"bestimmten Ländern";
            [SFNet checkRegion:check expect:str(geo[@"expectedResponse"]) ?: @"1" done:^(BOOL allowed) {
                if (allowed) done([NSURL URLWithString:url], nil);
                else done(nil, SFError([NSString stringWithFormat:@"Nur in %@ verfügbar.", region]));
            }];
        }];
    });
}
@end
