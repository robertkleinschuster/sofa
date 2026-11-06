#import "SFZDFParser.h"
#import "SFJSON.h"

NSString *SFZDFRegion(NSString *geo) {
    return geo.length && ![geo isEqualToString:@"NONE"] ? geo : nil;
}

@implementation SFZDFParser

+ (NSString *)image:(NSDictionary *)teaser big:(BOOL)big {
    NSDictionary *l = dict(dict(dict(teaser)[@"imageWithoutLogo"])[@"layouts"]);
    return big ? (str(l[@"dim1280X720"]) ?: str(l[@"dim768X432"])) : (str(l[@"dim768X432"]) ?: str(l[@"dim1280X720"]));
}

+ (NSDictionary *)mainMedia:(NSDictionary *)v {
    for (NSDictionary *m in arr(dict(dict(v)[@"currentMedia"])[@"nodes"])) {
        if (!dict(m)) continue;
        if ([str(m[@"__typename"]) isEqualToString:@"LiveMedia"]) return m;
        if ([str(m[@"vodMediaType"]) isEqualToString:@"DEFAULT"]) return m;
    }
    return nil;
}

+ (SFItem *)videoItem:(NSDictionary *)v {
    NSString *can = str(dict(v)[@"canonical"]);
    if (!can) return nil;
    SFItem *i = [SFItem new];
    i.kind = SFItemVideo;
    i.identifier = [@"zdf:" stringByAppendingString:can];
    i.resolverRef = i.identifier;
    i.title = str(v[@"title"]);
    i.plot = str(dict(v[@"teaser"])[@"description"]);
    i.image = [self image:dict(v[@"teaser"]) big:NO];
    i.backdrop = [self image:dict(v[@"teaser"]) big:YES];
    i.channel = str(dict(v[@"smartCollection"])[@"title"]);
    NSString *sc = str(dict(v[@"smartCollection"])[@"canonical"]);
    if (sc.length) i.showRef = [@"zdfshow:" stringByAppendingString:sc];
    i.date = SFDateFromISO8601(str(v[@"editorialDate"]));
    i.source = @"zdf"; i.themeName = @"zdf";
    i.style = SFTileStyleLandscape;
    NSDictionary *m = [self mainMedia:v];
    BOOL live = [str(m[@"__typename"]) isEqualToString:@"LiveMedia"];
    i.duration = [nn(m[@"duration"]) doubleValue];
    i.geoRegion = SFZDFRegion(str(m[@"geoLocation"]));
    if (i.geoRegion) i.badge = i.geoRegion;
    if (live) {
        i.kind = SFItemLive; i.badge = @"LIVE";
        // the channel: tvService "ZDF", "ZDFneo", "3sat", "phoenix", "arte", "KI.KA" -> Sofa's station ids
        // (lowercase letters and digits: "kika" - the ids ARD's EPG uses for the same channels)
        NSString *tv = str(m[@"tvService"]).lowercaseString;
        i.station = tv ? [[tv componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""] : nil;
    }
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
    i.image = [self image:dict(c[@"teaser"]) big:NO];
    i.backdrop = [self image:dict(c[@"teaser"]) big:YES];
    i.source = @"zdf"; i.themeName = @"zdf";
    i.style = SFTileStyleLandscape;
    if ([type isEqualToString:@"MetaCollection"]) {
        i.identifier = [@"zdfmeta:" stringByAppendingString:can];
        i.externalID = str(c[@"id"]);   // what metaCollectionContent takes
        i.style = SFTileStyleWide;
    } else if ([type isEqualToString:@"CuratedCollection"]) {
        i.identifier = [@"zdfpage:" stringByAppendingString:can];
    } else {
        i.identifier = [@"zdfshow:" stringByAppendingString:can];
        if ([type isEqualToString:@"MovieSmartCollection"]) i.subtitle = @"Film";
    }
    return i;
}

+ (SFItem *)itemFromNode:(NSDictionary *)n {
    NSString *t = str(dict(n)[@"__typename"]);
    if ([t isEqualToString:@"Video"]) return [self videoItem:n];
    if ([t hasSuffix:@"SmartCollection"] || [t isEqualToString:@"MetaCollection"] || [t isEqualToString:@"CuratedCollection"])
        return [self collectionItem:n type:t];
    return nil;   // ExternalLink, ZappingChannel, Catalog
}

+ (NSArray *)clustersIn:(NSDictionary *)cc {
    NSMutableArray *out = [NSMutableArray new];
    for (NSDictionary *m in arr(dict(dict(cc)[@"modules"])[@"nodes"])) {
        if (![str(dict(m)[@"__typename"]) isEqualToString:@"StaticHorizontalCluster"]) continue;
        NSMutableArray *items = [NSMutableArray new];
        for (NSDictionary *n in arr(dict(m[@"items"])[@"nodes"])) { SFItem *it = [self itemFromNode:n]; if (it) [items addObject:it]; }
        if (items.count) [out addObject:@{@"title": str(m[@"title"]) ?: @"", @"items": items}];
    }
    return out;
}

+ (NSString *)seasonName:(NSDictionary *)s {
    NSString *t = str(dict(s)[@"title"]);
    if (t.length) return t;
    return nn(s[@"number"]) ? [NSString stringWithFormat:@"Staffel %@", s[@"number"]] : nil;
}

+ (NSDictionary *)streamIn:(NSDictionary *)p {
    NSString *best = nil, *hls = nil; int bestScore = -1;
    for (NSDictionary *pl in arr(dict(p)[@"priorityList"])) {
        for (NSDictionary *f in arr(dict(pl)[@"formitaeten"])) {
            NSString *mime = str(dict(f)[@"mimeType"]);
            for (NSDictionary *qq in arr(f[@"qualities"])) {
                NSString *u = nil;
                for (NSDictionary *t in arr(dict(dict(qq)[@"audio"])[@"tracks"]))
                    if ([str(dict(t)[@"class"]) isEqualToString:@"main"] || !t[@"class"]) { u = str(t[@"uri"]); break; }
                if (!u) continue;
                if ([mime isEqualToString:@"application/x-mpegURL"]) { if (!hls) hls = u; continue; }
                if (![mime isEqualToString:@"video/mp4"]) continue;
                // 720p first, then smaller ones by size, larger ones last
                int h = [nn(qq[@"highestVerticalResolution"]) intValue];
                int sc = h == 720 ? 1000 : (h < 720 ? h : 700 - (h - 720) / 10);
                if (sc > bestScore) { bestScore = sc; best = u; }
            }
        }
    }
    NSString *u = best ?: hls;
    if (!u) return @{};
    // subtitles: PTMD captions[] (class hoh = hearing impaired), WebVTT for mpv
    NSMutableArray *subs = [NSMutableArray new];
    for (NSDictionary *c in arr(dict(p)[@"captions"])) {
        if (![str(dict(c)[@"format"]) isEqualToString:@"webvtt"] || !str(c[@"uri"])) continue;
        [subs addObject:@{@"lang": str(c[@"language"]) ?: @"deu", @"url": str(c[@"uri"]), @"kind": @"manual"}];
    }
    return @{@"url": u, @"subs": subs};
}
@end
