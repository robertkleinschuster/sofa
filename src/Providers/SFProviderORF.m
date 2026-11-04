#import "SFDownloads.h"
#import "SFFollows.h"
#import "SFIconArt.h"
#import "SFProviderORF.h"
#import "SFJSON.h"
#import "SFEngine.h"
#import "SFNet.h"
#import "SFStore.h"

static NSString *const kAPI = @"https://api-tvthek.orf.at/api/v4.3";
// Öffentlich bekannter App-Schlüssel (MServer OrfOnConstants.AUTH / yt-dlp).
static NSString *const kAuth = @"Basic b3JmX29uX3Y0MzpqRlJzYk5QRmlQU3h1d25MYllEZkNMVU41WU5aMjhtdA==";


static NSDate *isoDate(NSString *s) {
    if (s.length < 19) return nil;
    static NSDateFormatter *df; static dispatch_once_t o;
    dispatch_once(&o, ^{
        df = [NSDateFormatter new];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    });
    @synchronized (df) { return [df dateFromString:s]; }
}

@implementation SFProviderORF

// Sofa-eigene Einstiege (ohne Quellbild): Symbol-Kachel statt leerer Fläche
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
    if ([nn(e[@"is_drm_protected"]) boolValue]) i.badge = @"DRM";
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

#pragma mark Seiten

+ (SFItem *)folder:(NSString *)title ident:(NSString *)ident loader:(SFPageLoader)l {
    SFItem *f = [SFItem new];
    f.kind = SFItemFolder; f.title = title; f.identifier = ident;
    f.themeName = @"orf"; f.source = @"orf"; f.style = SFTileStyleWide;
    f.pageLoader = l;
    return f;
}

+ (SFPageLoader)profileLoader:(NSString *)pid title:(NSString *)title {
    return ^(SFPageDone done) {
        [self get:[NSString stringWithFormat:@"/profile/%@/episodes?limit=100", pid] cache:900 done:^(id j, NSError *e) {
            NSArray *eps = [self episodeItems:j];
            if (!j) { done(nil, e); return; }
            SFPage *p = [SFPage page:title theme:@"orf" shelves:@[[SFShelf grid:[NSString stringWithFormat:@"%lu %@", (unsigned long)eps.count, eps.count == 1 ? @"Folge" : @"Folgen"] style:SFTileStyleLandscape items:eps]]];
            if (!eps.count) p.emptyText = @"Aktuell sind keine Folgen verfügbar.";
            done(p, nil);
        }];
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
            BOOL drm = [nn(it[@"is_drm_protected"]) boolValue];
            i.badge = drm ? @"DRM" : @"LIVE";
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

#pragma mark Suche

// /search/{q}: Sendungen (episodes), zwei Seiten à 30. Segmente/Archiv bleiben außen vor.
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
        // Nur adaptives QXA: Einzelqualitäten liefern inzwischen einen "nicht verfügbar"-Clip
        if ([q isEqualToString:@"QXA"] && src) return src;
        if ([nn(s[@"is_adaptive_stream"]) boolValue] && !any) any = src;
    }
    return any;
}

+ (void)registerResolver {
    // Abo-Feed ("Neue Folgen automatisch laden")
    SFRegisterFeedFromLoader(@"orfprofile", ^SFPageLoader(NSString *ref) { return [self profileLoader:ref title:nil]; });
    SFRegisterShowPage(@"orfprofile", ^SFPageLoader(NSString *ref, NSString *title) { return [self profileLoader:ref title:title]; });
    SFRegisterResolver(@"orf", ^(NSString *eid, SFURLDone done) {
        [self get:[@"/episode/" stringByAppendingString:eid] cache:300 done:^(id j, NSError *e) {
            NSDictionary *ep = dict(j);
            if (!ep) { done(nil, e); return; }
            BOOL drm = NO;
            NSDictionary *src = ep;
            NSString *u = [self hlsFrom:ep drm:&drm];
            if (!u) {   // segmentierte Sendung: ersten Teil spielen
                NSDictionary *seg = dict(arr(dict(ep[@"_embedded"])[@"segments"]).firstObject);
                if (seg) { u = [self hlsFrom:seg drm:&drm]; src = seg; }
            }
            if (!u) { done(nil, SFError(drm ? @"Kopiergeschützt (DRM) – auf diesem Mac nicht abspielbar." : @"Kein abspielbarer Stream.")); return; }
            // Untertitel: _embedded.subtitle.vtt_url (des tatsächlich gespielten Objekts);
            // ai_subtitles = maschinell erzeugt -> als „automatisch“ kennzeichnen
            NSString *vtt = str(dict(dict(src[@"_embedded"])[@"subtitle"])[@"vtt_url"]);
            NSArray *subs = vtt ? @[@{@"lang": @"de", @"url": vtt, @"kind": [nn(src[@"ai_subtitles"]) boolValue] ? @"auto" : @"manual"}] : @[];
            SFSetMPVSource([NSURL URLWithString:u], @{@"subs": subs, @"alang": @"de"});
            done([NSURL URLWithString:u], nil);
        }];
    });
    SFRegisterResolver(@"orflive", ^(NSString *lid, SFURLDone done) {
        [self get:[@"/livestream/" stringByAppendingString:lid] cache:0 done:^(id j, NSError *e) {
            BOOL drm = NO;
            NSString *u = dict(j) ? [self hlsFrom:j drm:&drm] : nil;
            if (!u) { done(nil, e ?: SFError(drm ? @"Dieser Sender ist kopiergeschützt (DRM) und auf diesem Mac nicht abspielbar." : @"Livestream nicht verfügbar.")); return; }
            done([NSURL URLWithString:u], nil);
        }];
    });
}
@end
