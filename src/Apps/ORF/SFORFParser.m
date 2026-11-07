#import "SFORFParser.h"
#import "SFJSON.h"

static NSArray *listItems(id j) {
    NSDictionary *d = dict(j);
    return arr(d[@"_items"]) ?: arr(dict(d[@"_embedded"])[@"items"]) ?: arr(j) ?: @[];
}

@implementation SFORFParser

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
    // a segment is one report out of a broadcast (the news lane: "ZIB 1", "Aktuell nach fünf"):
    // its own id space (/segment/<id>), dated by its broadcast, the broadcast as channel
    BOOL segment = [str(e[@"video_type"]) isEqualToString:@"segment"];
    i.identifier = [(segment ? @"orfseg:" : @"orf:") stringByAppendingString:eid];
    i.resolverRef = i.identifier;
    i.title = str(e[@"title"]) ?: str(e[@"headline"]);
    i.plot = str(e[@"description"]) ?: str(e[@"teaser_text"]);
    i.image = [self image:e big:NO];
    i.backdrop = [self image:e big:YES];
    // the show (a segment: its broadcast) - never the genre: lists without a profile title left
    // "Serie" as the show name ("Zur Sendung „Serie“", user 2026-11-07); the genre is in the subtitle
    i.channel = segment ? str(e[@"sub_headline"]) : str(e[@"profile_title"]);
    // the show: list entries carry no profile id field, only the HAL link ".../profile/<id>"
    NSString *ph = str(dict(dict(e[@"_links"])[@"profile"])[@"href"]);
    if (ph.length && str(e[@"profile_title"])) i.showRef = [@"orfprofile:" stringByAppendingString:ph.lastPathComponent];
    i.date = SFDateFromISO8601(str(e[@"date"])) ?: SFDateFromISO8601(str(e[@"episode_date"]));
    i.duration = [nn(e[@"duration_seconds"]) doubleValue];
    i.source = @"orf"; i.themeName = @"orf";
    i.style = SFTileStyleLandscape;
    i.drm = [nn(e[@"is_drm_protected"]) boolValue];
    if (i.drm) i.badge = @"DRM";
    // every episode/segment names its playback right: "austria" (geo-blocked) or "worldwide"
    if ([str(e[@"right"]) isEqualToString:@"austria"]) i.geoRegion = @"AT";
    NSMutableArray *sub = [NSMutableArray new];
    NSString *lead = segment ? i.channel : str(e[@"genre_title"]);
    if (lead.length) [sub addObject:lead];
    if (i.date) [sub addObject:SFFormatDateShort(i.date)];
    i.subtitle = [sub componentsJoinedByString:@" · "];
    return i;
}

+ (NSArray *)episodeItems:(id)json {
    NSMutableArray *a = [NSMutableArray new];
    for (id e in listItems(json)) { SFItem *it = [self episodeItem:e]; if (it) [a addObject:it]; }
    return a;
}

// The broadcast on air at `now`: the one whose start..end contains it, else the next to begin
// (a gap between two broadcasts). Not the list's first entry: a cached answer starts in the past.
+ (NSDictionary *)broadcastAt:(NSDate *)now in:(NSArray *)broadcasts {
    NSDictionary *next = nil; NSDate *nextStart = nil;
    for (NSDictionary *b in broadcasts) {
        if (!dict(b) || !nn(b[@"id"])) continue;
        NSDate *s = SFDateFromISO8601(str(b[@"start"])), *e = SFDateFromISO8601(str(b[@"end"]));
        if (!s || !e) continue;
        if ([s compare:now] != NSOrderedDescending && [now compare:e] == NSOrderedAscending) return b;
        if ([s compare:now] == NSOrderedDescending && (!nextStart || [s compare:nextStart] == NSOrderedAscending)) { next = b; nextStart = s; }
    }
    return next;
}

+ (NSArray *)liveItemsIn:(id)json at:(NSDate *)now {
    NSDictionary *j = dict(json);
    if (!j) return nil;
    NSMutableArray *a = [NSMutableArray new];
    // /livestreams is keyed by channel; ORF names them only in its own UI
    NSDictionary *names = @{@"orf1": @"ORF 1", @"orf2": @"ORF 2", @"orf3": @"ORF III", @"orfs": @"ORF SPORT +", @"live_special": @"ORF Spezial"};
    for (NSString *k in @[@"orf1", @"orf2", @"orf3", @"orfs", @"live_special"]) {
        NSArray *broadcasts = arr(dict(j[k])[@"items"]);
        NSDictionary *it = [self broadcastAt:now in:broadcasts];
        if (!it) continue;
        SFItem *i = [SFItem new];
        i.kind = SFItemLive;
        i.identifier = [@"orflive:" stringByAppendingString:k];
        i.resolverRef = [@"orflive:" stringByAppendingString:[nn(it[@"id"]) description]];   // the broadcast's stream
        i.title = names[k];
        i.subtitle = str(it[@"title"]);
        i.plot = str(it[@"description"]);
        i.image = [self image:it big:NO];
        i.backdrop = [self image:it big:YES];
        i.source = @"orf"; i.themeName = @"orf"; i.style = SFTileStyleLandscape;
        i.drm = [nn(it[@"is_drm_protected"]) boolValue];
        i.badge = i.drm ? @"DRM" : @"LIVE";
        i.station = k;
        if ([str(it[@"right"]) isEqualToString:@"austria"]) i.geoRegion = @"AT";   // else "worldwide"
        NSMutableArray *sched = [NSMutableArray new];
        for (NSDictionary *b in broadcasts) {
            SFBroadcast *x = [SFBroadcast title:str(dict(b)[@"title"]) start:SFDateFromISO8601(str(b[@"start"])) end:SFDateFromISO8601(str(b[@"end"]))];
            if (!x) continue;
            NSString *sub = str(b[@"sub_headline"]);
            if (![sub isEqualToString:x.title]) x.subtitle = sub;
            x.plot = str(b[@"description"]);
            [sched addObject:x];
        }
        i.schedule = sched;
        [a addObject:i];
    }
    return a;
}

+ (NSString *)hlsIn:(NSDictionary *)obj drm:(BOOL *)drm {
    NSString *any = nil;
    for (NSDictionary *s in arr(dict(obj[@"sources"])[@"hls"])) {
        if (!dict(s)) continue;
        // is_drm_protected is the field; the "...DRM" quality key predates it in this code and no
        // recorded DRM answer shows whether ORF still sends one without the other - kept for both
        if ([nn(s[@"is_drm_protected"]) boolValue] || [str(s[@"quality_key"]) hasSuffix:@"DRM"]) { *drm = YES; continue; }
        NSString *q = str(s[@"quality_key"]), *src = str(s[@"src"]);
        // adaptive QXA only: single qualities now deliver a "not available" clip
        if ([q isEqualToString:@"QXA"] && src) return src;
        if ([nn(s[@"is_adaptive_stream"]) boolValue] && !any) any = src;
    }
    return any;
}

+ (NSDictionary *)streamIn:(NSDictionary *)obj {
    if (!dict(obj)) return @{};
    BOOL drm = NO;
    NSString *u = [self hlsIn:obj drm:&drm];
    if (!u) return drm ? @{@"drm": @YES} : @{};
    // subtitles: _embedded.subtitle.vtt_url; ai_subtitles = machine-generated -> "automatic"
    NSString *vtt = str(dict(dict(obj[@"_embedded"])[@"subtitle"])[@"vtt_url"]);
    NSArray *subs = vtt ? @[@{@"lang": @"de", @"url": vtt, @"kind": [nn(obj[@"ai_subtitles"]) boolValue] ? @"auto" : @"manual"}] : @[];
    return @{@"url": u, @"subs": subs};
}
@end
