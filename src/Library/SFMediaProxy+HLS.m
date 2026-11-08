// SFMediaProxy (HLS) - HLS sources (ORF) through the media store. Playlists are fetched from the
// source and rewritten so that every URI - variant and rendition playlists, segments, keys, init
// sections - is a local URL; resources are tracks of the item ("hls:<item>:<host+path hash>"), kept
// when their media playlist is VOD (#EXT-X-ENDLIST; a live one passes through). A download takes one
// variant (the best up to 1080p, its default audio rendition if separate) - its playlists go into the
// manifest (kind "hls"), so the complete item plays from the store without the source.
#import "SFMediaProxy+Private.h"
#import "SFCurl.h"

static const int kMaxHeight = 1080;

// a tag's attribute list: KEY=value / KEY="value"
static NSDictionary *Attributes(NSString *line) {
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

static NSString *Absolute(NSString *uri, NSString *base) {
    return [[[NSURL URLWithString:uri relativeToURL:[NSURL URLWithString:base]] absoluteURL] absoluteString];
}

static NSString *KeyOf(NSString *item, NSString *url) {
    NSURL *u = [NSURL URLWithString:url];
    return [NSString stringWithFormat:@"hls:%@:%@", item, SFProxyHash([u.host ?: @"" stringByAppendingString:u.path ?: @""])];
}

// The URIs of a media playlist (segments, keys, init sections), absolute against `base`
static NSArray *ResourcesOf(NSString *text, NSString *base) {
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!l.length) continue;
        if (![l hasPrefix:@"#"]) { [out addObject:Absolute(l, base)]; continue; }
        if ([l hasPrefix:@"#EXT-X-KEY"] || [l hasPrefix:@"#EXT-X-MAP"]) {
            NSString *u = Attributes(l)[@"URI"];
            if (u.length && ![u hasPrefix:@"data:"] && ![out containsObject:Absolute(u, base)]) [out addObject:Absolute(u, base)];
        }
    }
    return out;
}

@implementation SFMediaProxy (HLS)

+ (BOOL)isPlaylist:(NSURL *)url {
    NSString *ext = url.path.pathExtension.lowercaseString;
    return [ext isEqualToString:@"m3u8"] || [ext isEqualToString:@"m3u"];
}

- (SFProxySession *)newHLSSession:(NSString *)item {
    SFProxySession *s = [SFProxySession new];
    s.item = item; s.hls = YES;
    s.playlists = [NSMutableArray new]; s.resources = [NSMutableArray new];
    s.playlistIndex = [NSMutableDictionary new]; s.resourceIndex = [NSMutableDictionary new];
    return s;
}

- (NSURL *)hlsURLFor:(NSURL *)url item:(NSString *)item {
    SFProxySession *s = [self newHLSSession:item];
    s.url = url.absoluteString;
    return [NSURL URLWithString:[[self addSession:s] stringByAppendingString:@"/root.m3u8"]];
}

- (NSURL *)storedHLSFor:(NSString *)item manifest:(NSDictionary *)m subs:(NSArray **)subsOut {
    NSArray *pls = [m[@"playlists"] isKindOfClass:[NSArray class]] ? m[@"playlists"] : nil;
    if (!pls.count) return nil;
    SFProxySession *s = [self newHLSSession:item];
    s.stored = YES; s.vod = YES;
    NSMutableArray *all = [NSMutableArray new];
    if (pls.count > 1) {   // a separate audio rendition: a master naming both (index 1 = video, 2 = audio)
        NSString *master = [NSString stringWithFormat:@"#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"stored:2\"\n"
                            "#EXT-X-STREAM-INF:BANDWIDTH=%@,AUDIO=\"a\"\nstored:1\n", m[@"bandwidth"] ?: @1];
        [all addObject:@{@"text": master, @"base": @"stored:"}];
    }
    [all addObjectsFromArray:pls];
    s.storedPlaylists = all;
    NSString *base = [self addSession:s];
    NSArray *subs = [self storedSubs:m session:s base:base];
    if (subsOut) *subsOut = subs;
    return [NSURL URLWithString:[base stringByAppendingString:@"/root.m3u8"]];
}

#pragma mark Rewriting (on the queue)

- (NSString *)local:(NSString *)abs playlist:(BOOL)pl session:(SFProxySession *)s {
    NSMutableArray *list = pl ? s.playlists : s.resources;
    NSMutableDictionary *index = pl ? s.playlistIndex : s.resourceIndex;
    NSNumber *n = index[abs];
    if (!n) { n = @(list.count); [list addObject:abs]; index[abs] = n; }
    NSString *base = [NSString stringWithFormat:@"http://127.0.0.1:%u/h/%@", self.port, s.sid];
    if (pl) return [NSString stringWithFormat:@"%@/p/%@.m3u8", base, n];
    NSString *ext = [[NSURL URLWithString:abs] path].pathExtension;
    return [NSString stringWithFormat:@"%@/r/%@%@", base, n, ext.length ? [@"." stringByAppendingString:ext] : @""];
}

- (NSString *)rewrite:(NSString *)text base:(NSString *)base session:(SFProxySession *)s {
    BOOL master = [text rangeOfString:@"#EXT-X-STREAM-INF"].location != NSNotFound;
    if (!master && [text rangeOfString:@"#EXT-X-ENDLIST"].location != NSNotFound) s.vod = YES;
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!l.length) continue;
        if (![l hasPrefix:@"#"]) { [out addObject:[self local:Absolute(l, base) playlist:master session:s]]; continue; }
        NSRange q = [l rangeOfString:@"URI=\""];
        if (q.location != NSNotFound) {
            NSUInteger from = NSMaxRange(q);
            NSRange end = [l rangeOfString:@"\"" options:0 range:NSMakeRange(from, l.length - from)];
            NSString *uri = end.location != NSNotFound ? [l substringWithRange:NSMakeRange(from, end.location - from)] : nil;
            if (uri.length && ![uri hasPrefix:@"data:"]) {
                BOOL pl = [l hasPrefix:@"#EXT-X-MEDIA"] || [l hasPrefix:@"#EXT-X-I-FRAME-STREAM-INF"];
                l = [l stringByReplacingCharactersInRange:NSMakeRange(from, end.location - from)
                                               withString:[self local:Absolute(uri, base) playlist:pl session:s]];
            }
        }
        [out addObject:l];
    }
    return [[out componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

#pragma mark Serving (on the queue)

- (void)serveHLS:(SFHTTPExchange *)x session:(SFProxySession *)s {
    NSArray *p = x.request.pathParts;
    NSString *last = p.lastObject;
    if (p.count == 3 && [last isEqual:@"root.m3u8"]) { [self playlist:-1 to:x session:s]; return; }
    if (p.count == 4 && [p[2] isEqual:@"p"]) { [self playlist:[last integerValue] to:x session:s]; return; }
    if (p.count == 4 && [p[2] isEqual:@"r"]) { [self resource:[last integerValue] to:x session:s]; return; }
    [x respondJSON:404 object:@{@"error": @"not found"}];
}

// -1: the root (the source's URL, or the stored root); else playlist n
- (void)playlist:(NSInteger)n to:(SFHTTPExchange *)x session:(SFProxySession *)s {
    if (s.stored) {   // stored playlists are named "stored:<i>" inside the stored master
        NSInteger i = n < 0 ? 0 : [[s.playlists[(NSUInteger)n] substringFromIndex:7] integerValue];
        if (n >= (NSInteger)s.playlists.count || i >= (NSInteger)s.storedPlaylists.count) { [x respondJSON:404 object:@{@"error": @"not found"}]; return; }
        NSDictionary *pl = s.storedPlaylists[(NSUInteger)i];
        NSString *body = [self rewrite:pl[@"text"] base:pl[@"base"] session:s];
        [x respond:200 type:@"application/vnd.apple.mpegurl" body:[body dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    if (n >= (NSInteger)s.playlists.count) { [x respondJSON:404 object:@{@"error": @"not found"}]; return; }
    NSString *url = n < 0 ? s.url : s.playlists[(NSUInteger)n];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSInteger st = 0; NSString *eff = nil; NSError *e = nil;
        NSData *d = SFCurlFetchFinal(url, &st, &eff, &e);
        NSString *text = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
        dispatch_async(self.queue, ^{
            if (!text || st >= 400) { [x respondJSON:st >= 400 ? st : 502 object:@{@"error": e.localizedDescription ?: @"playlist"}]; return; }
            NSString *body = [self rewrite:text base:eff ?: url session:s];
            [x respond:200 type:@"application/vnd.apple.mpegurl" body:[body dataUsingEncoding:NSUTF8StringEncoding]];
        });
    });
}

- (void)resource:(NSInteger)n to:(SFHTTPExchange *)x session:(SFProxySession *)s {
    if (n < 0 || n >= (NSInteger)s.resources.count) { [x respondJSON:404 object:@{@"error": @"not found"}]; return; }
    NSString *url = s.resources[(NSUInteger)n], *key = KeyOf(s.item, url);
    NSString *range = [x.request header:@"range"];
    void (^send)(NSData *) = ^(NSData *d) {
        long long a, b; BOOL partial;
        if (!SFHTTPParseRange(range, (long long)d.length, &a, &b, &partial)) {
            [x begin:416 headers:@{@"Content-Range": [NSString stringWithFormat:@"bytes */%lu", (unsigned long)d.length], @"Content-Length": @"0"}];
            [x finish]; return;
        }
        NSMutableDictionary *h = [@{@"Content-Type": @"application/octet-stream", @"Accept-Ranges": @"bytes",
                                    @"Content-Length": [NSString stringWithFormat:@"%lld", b - a]} mutableCopy];
        if (partial) h[@"Content-Range"] = [NSString stringWithFormat:@"bytes %lld-%lld/%lu", a, b - 1, (unsigned long)d.length];
        [x begin:partial ? 206 : 200 headers:h];
        if ([x.request.method isEqualToString:@"HEAD"]) { [x finish]; return; }
        [x write:[d subdataWithRange:NSMakeRange((NSUInteger)a, (NSUInteger)(b - a))] done:^(BOOL ok) { [x finish]; }];
    };
    SFExtentSet *have = [SFProxyStore() extentsOf:key];
    NSData *disk = have.bytes && [SFProxyStore() hasComplete:@[key]] ? [SFProxyStore() read:key start:0 length:(NSUInteger)have.bytes] : nil;
    if (disk) { send(disk); return; }
    if (s.stored) { [x respondJSON:404 object:@{@"error": @"not stored"}]; return; }
    BOOL keep = s.vod;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSInteger st = 0; NSError *e = nil;
        NSData *d = SFCurlFetch(url, @"GET", nil, nil, &st, &e);
        if (d.length && st < 400 && keep) [SFProxyStore() write:d key:key item:s.item kind:@"hls" total:(long long)d.length at:0];
        dispatch_async(self.queue, ^{
            if (!d || st >= 400) { [x respondJSON:st >= 400 ? st : 502 object:@{@"error": e.localizedDescription ?: @"resource"}]; return; }
            send(d);
        });
    });
}

#pragma mark Filling

// the best variant up to kMaxHeight (by bandwidth), and the default audio rendition of its group if
// it has its own playlist: @[variant URL, audio URL?], bandwidth
static NSArray *ChooseVariant(NSString *master, NSString *base, long long *bandwidth) {
    NSArray *lines = [master componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSDictionary *best = nil; NSString *bestURL = nil; long long bestBW = -1; BOOL bestFits = NO;
    NSMutableDictionary *audio = [NSMutableDictionary new];   // group -> URL (DEFAULT=YES wins)
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *l = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([l hasPrefix:@"#EXT-X-MEDIA"]) {
            NSDictionary *a = Attributes(l);
            if ([a[@"TYPE"] isEqual:@"AUDIO"] && [a[@"URI"] length] && (!audio[a[@"GROUP-ID"] ?: @""] || [a[@"DEFAULT"] isEqual:@"YES"]))
                audio[a[@"GROUP-ID"] ?: @""] = Absolute(a[@"URI"], base);
        }
        if (![l hasPrefix:@"#EXT-X-STREAM-INF"] || i + 1 >= lines.count) continue;
        NSDictionary *a = Attributes(l);
        NSString *uri = [lines[i + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        long long bw = [a[@"BANDWIDTH"] longLongValue];
        int height = [[[a[@"RESOLUTION"] ?: @"" componentsSeparatedByString:@"x"] lastObject] intValue];
        BOOL fits = height == 0 || height <= kMaxHeight;
        if ((fits && !bestFits) || (fits == bestFits && bw > bestBW)) { best = a; bestURL = Absolute(uri, base); bestBW = bw; bestFits = fits; }
    }
    if (!bestURL) return nil;
    *bandwidth = bestBW;
    NSString *a = best[@"AUDIO"] ? audio[best[@"AUDIO"]] : nil;
    return a ? @[bestURL, a] : @[bestURL];
}

- (dispatch_block_t)fillHLS:(NSURL *)url item:(NSString *)item subs:(NSArray *)subs
                   progress:(void (^)(double))progress done:(void (^)(NSError *))done {
    __block BOOL cancelled = NO;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void (^fail)(NSString *) = ^(NSString *why) { SFMain(^{ if (!cancelled) done(SFError(why)); }); };
        NSInteger st = 0; NSString *eff = nil;
        NSData *d = SFCurlFetchFinal(url.absoluteString, &st, &eff, NULL);
        NSString *root = d && st < 400 ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
        if (!root) { fail(@"Wiedergabeliste nicht erreichbar"); return; }
        long long bandwidth = 0;
        NSArray *media = [root rangeOfString:@"#EXT-X-STREAM-INF"].location != NSNotFound
            ? ChooseVariant(root, eff ?: url.absoluteString, &bandwidth) : @[eff ?: url.absoluteString];
        if (!media.count) { fail(@"Keine Variante"); return; }
        NSMutableArray *playlists = [NSMutableArray new], *resources = [NSMutableArray new];
        for (NSString *mu in media) {
            NSString *text = nil, *meff = nil;
            if ([mu isEqualToString:eff] && [root rangeOfString:@"#EXT-X-STREAM-INF"].location == NSNotFound) { text = root; meff = eff; }
            else {
                NSData *md = SFCurlFetchFinal(mu, &st, &meff, NULL);
                text = md && st < 400 ? [[NSString alloc] initWithData:md encoding:NSUTF8StringEncoding] : nil;
            }
            if (!text || [text rangeOfString:@"#EXT-X-ENDLIST"].location == NSNotFound) { fail(@"Kein abgeschlossenes Video (live?)"); return; }
            [playlists addObject:@{@"text": text, @"base": meff ?: mu}];
            [resources addObjectsFromArray:ResourcesOf(text, meff ?: mu)];
        }
        NSMutableArray *keys = [NSMutableArray new];
        for (NSString *r in resources) [keys addObject:KeyOf(item, r)];
        NSMutableDictionary *m = [@{@"kind": @"hls", @"required": keys, @"playlists": playlists, @"bandwidth": @(bandwidth), @"url": url.absoluteString} mutableCopy];
        NSDictionary *old = [SFProxyStore() manifestOf:item];
        if (old[@"subs"]) m[@"subs"] = old[@"subs"];
        [SFProxyStore() setManifest:m forItem:item];
        // 3x the variant's bit rate (as ffmpeg's -readrate 3 was): background loading never crowds out streaming
        double rate = bandwidth > 0 ? 3 * bandwidth / 8.0 : 0;
        NSDate *t0 = [NSDate date];
        long long fetched = 0; NSUInteger have = 0;
        for (NSString *k in keys) if ([SFProxyStore() hasComplete:@[k]]) have++;
        SFLog(@"media-proxy: filling %@ (HLS, %lu resources, %lu on disk already)", item, (unsigned long)keys.count, (unsigned long)have);
        for (NSUInteger i = 0; i < resources.count && !cancelled; i++) {
            if ([SFProxyStore() hasComplete:@[keys[i]]]) continue;
            NSData *r = SFCurlFetch(resources[i], @"GET", nil, nil, &st, NULL);
            if (!r.length || st >= 400) { fail(@"Segment nicht erreichbar"); return; }
            [SFProxyStore() write:r key:keys[i] item:item kind:@"hls" total:(long long)r.length at:0];
            fetched += (long long)r.length; have++;
            double p = MIN(0.99, (double)have / keys.count);
            SFMain(^{ if (!cancelled) progress(p); });
            double wait = rate > 0 ? fetched / rate + [t0 timeIntervalSinceNow] : 0;
            if (wait > 0) [NSThread sleepForTimeInterval:wait];
        }
        if (cancelled) return;
        NSArray *storedSubs = [self fillSubs:subs item:item prefix:[@"hls:" stringByAppendingString:item] cancelled:^BOOL { return cancelled; }];
        if (storedSubs.count) { m[@"subs"] = storedSubs; [SFProxyStore() setManifest:m forItem:item]; }
        [SFProxyStore() sync];
        BOOL complete = [SFProxyStore() itemIsComplete:item];
        SFMain(^{
            if (cancelled) return;
            if (complete) { progress(1); done(nil); } else done(SFError(@"Unvollständig geladen – wird erneut versucht"));
        });
    });
    return ^{ cancelled = YES; };
}
@end
