// SFHLSPlaylist - see the header.
#import "SFHLSPlaylist.h"

const int kSFHLSMaxHeight = 1080;

// a tag's attribute list: KEY=value / KEY="value"
NSDictionary *SFHLSAttributes(NSString *line) {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) return @{};
    NSString *list = [line substringFromIndex:colon.location + 1];
    NSMutableDictionary *a = [NSMutableDictionary new];
    NSScanner *sc = [NSScanner scannerWithString:list];
    sc.charactersToBeSkipped = nil;
    while (!sc.isAtEnd) {
        NSString *k = nil, *v = nil;
        [sc scanUpToString:@"=" intoString:&k];
        if (![sc scanString:@"=" intoString:NULL]) break;
        if ([sc scanString:@"\"" intoString:NULL]) { [sc scanUpToString:@"\"" intoString:&v]; [sc scanString:@"\"" intoString:NULL]; }
        else [sc scanUpToString:@"," intoString:&v];
        [sc scanString:@"," intoString:NULL];
        if (k) a[[k stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]] = v ?: @"";
    }
    return a;
}

// RFC 8216 wants valid URIs; one that is not (a space, a stray character) is percent-escaped as
// players do, and kept as given when even that does not parse - its fetch then fails with an error
// instead of a nil reaching an array (an exception: the whole app gone)
NSString *SFHLSAbsolute(NSString *uri, NSString *base) {
    if (!uri) return nil;
    NSURL *b = base ? [NSURL URLWithString:base] : nil;
    NSURL *u = [NSURL URLWithString:uri relativeToURL:b];
    if (!u) {
        NSString *esc = [uri stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        u = esc ? [NSURL URLWithString:esc relativeToURL:b] : nil;
    }
    return u.absoluteURL.absoluteString ?: uri;
}

// The URIs of a media playlist (segments, keys, init sections), absolute against `base`
NSArray *SFHLSResources(NSString *text, NSString *base) {
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!l.length) continue;
        if (![l hasPrefix:@"#"]) { [out addObject:SFHLSAbsolute(l, base)]; continue; }
        if ([l hasPrefix:@"#EXT-X-KEY"] || [l hasPrefix:@"#EXT-X-MAP"]) {
            NSString *u = SFHLSAttributes(l)[@"URI"];
            if (u.length && ![u hasPrefix:@"data:"] && ![out containsObject:SFHLSAbsolute(u, base)]) [out addObject:SFHLSAbsolute(u, base)];
        }
    }
    return out;
}

// the best variant up to kSFHLSMaxHeight (by bandwidth), and the default audio rendition of its group if
// it has its own playlist: @[variant URL, audio URL?], bandwidth
NSArray *SFHLSChooseVariant(NSString *master, NSString *base, long long *bandwidth) {
    NSArray *lines = [master componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSDictionary *best = nil; NSString *bestURL = nil; long long bestBW = -1; BOOL bestFits = NO;
    NSMutableDictionary *audio = [NSMutableDictionary new];   // group -> URL (DEFAULT=YES wins)
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *l = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([l hasPrefix:@"#EXT-X-MEDIA"]) {
            NSDictionary *a = SFHLSAttributes(l);
            if ([a[@"TYPE"] isEqual:@"AUDIO"] && [a[@"URI"] length] && (!audio[a[@"GROUP-ID"] ?: @""] || [a[@"DEFAULT"] isEqual:@"YES"]))
                audio[a[@"GROUP-ID"] ?: @""] = SFHLSAbsolute(a[@"URI"], base);
        }
        if (![l hasPrefix:@"#EXT-X-STREAM-INF"] || i + 1 >= lines.count) continue;
        NSDictionary *a = SFHLSAttributes(l);
        NSString *uri = [lines[i + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        long long bw = [a[@"BANDWIDTH"] longLongValue];
        int height = [[[a[@"RESOLUTION"] ?: @"" componentsSeparatedByString:@"x"] lastObject] intValue];
        BOOL fits = height == 0 || height <= kSFHLSMaxHeight;
        if ((fits && !bestFits) || (fits == bestFits && bw > bestBW)) { best = a; bestURL = SFHLSAbsolute(uri, base); bestBW = bw; bestFits = fits; }
    }
    if (!bestURL) return nil;
    *bandwidth = bestBW;
    NSString *a = best[@"AUDIO"] ? audio[best[@"AUDIO"]] : nil;
    return a ? @[bestURL, a] : @[bestURL];
}

// The master for the player with only the variant a download takes (ChooseVariant) and that variant's
// audio renditions (an audio description stays choosable): lavf probes the first segments of every
// variant before it plays - 8 variants made an ORF start 13-21 s (2026-11-08) - and it never switches
// variants anyway. What playback keeps is then what a download needs.
NSString *SFHLSOneVariant(NSString *master, NSString *base) {
    long long bw = 0;
    NSString *chosen = [SFHLSChooseVariant(master, base, &bw) firstObject];
    if (!chosen) return master;
    NSArray *lines = [master componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSString *group = nil;
    for (NSUInteger i = 0; i + 1 < lines.count; i++)
        if ([lines[i] hasPrefix:@"#EXT-X-STREAM-INF"]
            && [SFHLSAbsolute([lines[i + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]], base) isEqualToString:chosen])
            group = SFHLSAttributes(lines[i])[@"AUDIO"];
    NSMutableArray *out = [NSMutableArray new];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *l = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([l hasPrefix:@"#EXT-X-I-FRAME-STREAM-INF"]) continue;
        if ([l hasPrefix:@"#EXT-X-MEDIA"]) {
            NSDictionary *a = SFHLSAttributes(l);
            if ([a[@"TYPE"] isEqual:@"AUDIO"] && ![a[@"GROUP-ID"] isEqual:group]) continue;
        }
        if ([l hasPrefix:@"#EXT-X-STREAM-INF"]) {
            NSString *uri = i + 1 < lines.count ? [lines[i + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
            if ([SFHLSAbsolute(uri, base) isEqualToString:chosen]) [out addObjectsFromArray:@[l, uri]];
            i++;   // its URI line: taken or dropped with it
            continue;
        }
        [out addObject:l];
    }
    return [out componentsJoinedByString:@"\n"];
}

