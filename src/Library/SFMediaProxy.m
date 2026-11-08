#import "SFMediaProxy+Private.h"
#import "SFLocalHTTP.h"
#import "SFCurl.h"
#import "SFDownloads.h"
#import "SFMediaStore.h"
#import <CommonCrypto/CommonDigest.h>

static const NSUInteger kPiece = 1 << 20;        // bytes per store read
static const NSUInteger kFlush = 256 * 1024;     // source bytes gathered before they go to the reader and the store

@implementation SFProxySession
@end

NSString *SFProxyHash(NSString *s) {
    unsigned char d[CC_SHA1_DIGEST_LENGTH];
    NSData *b = [s dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA1(b.bytes, (CC_LONG)b.length, d);
    NSMutableString *h = [NSMutableString new];
    for (int i = 0; i < 8; i++) [h appendFormat:@"%02x", d[i]];
    return h;
}

@implementation SFMediaProxy {
    SFLocalHTTP *_server;
    dispatch_queue_t _q;                 // the server's: sessions and exchanges
    NSMutableDictionary *_sessions;      // sid -> SFProxySession (on _q)
}

+ (instancetype)shared {
    static SFMediaProxy *p; static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [SFMediaProxy new]; });
    return p;
}

+ (BOOL)canServe:(NSURL *)url {
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    // a loopback source is local already (the YouTube engine's routes, test servers) - tests that
    // exercise the proxy with a local server say so (SOFA_PROXY_LOOPBACK=1)
    return ![url.host isEqualToString:@"127.0.0.1"] || SFDevEnv(@"SOFA_PROXY_LOOPBACK") != nil;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("sofa.media-proxy", DISPATCH_QUEUE_SERIAL);
        _sessions = [NSMutableDictionary new];
        __weak SFMediaProxy *ws = self;
        _server = [[SFLocalHTTP alloc] initWithName:@"media-proxy" queue:_q maxBody:0 handler:^(SFHTTPExchange *x) { [ws serve:x]; }];
        if (![_server startPreferringPort:0]) SFLog(@"media-proxy: could not listen");
    }
    return self;
}

- (dispatch_queue_t)queue { return _q; }
- (uint16_t)port { return _server.port; }

- (NSString *)addSession:(SFProxySession *)s {
    s.sid = [[[NSUUID UUID] UUIDString] substringToIndex:12].lowercaseString;
    dispatch_sync(_q, ^{ self->_sessions[s.sid] = s; });
    return [NSString stringWithFormat:@"http://127.0.0.1:%u/%@/%@", _server.port, s.hls ? @"h" : @"f", s.sid];
}

- (NSURL *)localURLFor:(NSURL *)url item:(NSString *)item {
    if (!_server.port || !item.length || ![SFMediaProxy canServe:url]) return url;
    if ([SFMediaProxy isPlaylist:url]) return [self hlsURLFor:url item:item];
    SFProxySession *s = [SFProxySession new];
    s.item = item; s.url = url.absoluteString;
    NSString *ext = url.path.pathExtension;   // players look at it
    return [NSURL URLWithString:[[self addSession:s] stringByAppendingFormat:@"/media%@", ext.length ? [@"." stringByAppendingString:ext] : @""]];
}

- (NSURL *)storedURLFor:(NSString *)item subs:(NSArray **)subsOut {
    NSDictionary *m = [SFProxyStore() manifestOf:item];
    if (!_server.port || ![SFProxyStore() itemIsComplete:item]) return nil;
    if ([m[@"kind"] isEqual:@"hls"]) return [self storedHLSFor:item manifest:m subs:subsOut];
    if (![m[@"kind"] isEqual:@"file"]) return nil;
    SFProxySession *s = [SFProxySession new];
    s.item = item; s.stored = YES; s.key = [m[@"required"] firstObject]; s.total = [m[@"total"] longLongValue]; s.mime = m[@"mime"];
    NSString *base = [self addSession:s];
    NSArray *subs = [self storedSubs:m session:s base:base];
    if (subsOut) *subsOut = subs;
    NSString *ext = [m[@"url"] isKindOfClass:[NSString class]] ? [[NSURL URLWithString:m[@"url"]] path].pathExtension : @"";
    return [NSURL URLWithString:[base stringByAppendingFormat:@"/media%@", ext.length ? [@"." stringByAppendingString:ext] : @""]];
}

// the manifest's complete subtitles: their keys into the session (served at <base>/subs/<n>.vtt), as
// player source entries
- (NSArray *)storedSubs:(NSDictionary *)m session:(SFProxySession *)s base:(NSString *)base {
    NSMutableArray *keys = [NSMutableArray new], *entries = [NSMutableArray new];
    for (NSDictionary *t in [m[@"subs"] isKindOfClass:[NSArray class]] ? m[@"subs"] : @[])
        if ([SFProxyStore() hasComplete:@[t[@"key"] ?: @""]]) [keys addObject:t];
    s.subs = [keys valueForKey:@"key"];
    [keys enumerateObjectsUsingBlock:^(NSDictionary *t, NSUInteger i, BOOL *stop) {
        [entries addObject:@{@"lang": t[@"lang"] ?: @"", @"kind": t[@"kind"] ?: @"", @"name": t[@"name"] ?: @"",
                             @"url": [NSString stringWithFormat:@"%@/subs/%lu.vtt", base, (unsigned long)i]}];
    }];
    return entries;
}

#pragma mark Identity

// the source told the length: the file is a track from now on (its manifest names it)
- (void)learn:(SFProxySession *)s total:(long long)total mime:(NSString *)mime {
    if (s.key || total <= 0) return;
    NSURL *u = [NSURL URLWithString:s.url];
    s.total = total; s.mime = mime.length ? mime : @"video/mp4";
    // the item's own track (removal and eviction go by item): its file by host + path (a token query
    // does not change it) and length
    s.key = [NSString stringWithFormat:@"file:%@:%@:%lld", s.item, SFProxyHash([u.host stringByAppendingString:u.path ?: @""]), total];
    NSDictionary *old = [SFProxyStore() manifestOf:s.item];
    NSMutableDictionary *m = [@{@"kind": @"file", @"required": @[s.key], @"total": @(total), @"mime": s.mime, @"url": s.url} mutableCopy];
    if ([old[@"required"] isEqual:m[@"required"]] && old[@"subs"]) m[@"subs"] = old[@"subs"];   // (kept by a download)
    [SFProxyStore() setManifest:m forItem:s.item];
    SFLog(@"media-proxy: %@ is %@ (%.1f MB, %@)", s.item, s.key, total / 1048576.0, s.mime);
}

#pragma mark Serving (on _q)

- (void)serve:(SFHTTPExchange *)x {
    NSArray *p = x.request.pathParts;   // f|h, sid, media[.ext] | subs, <n>.vtt | (HLS) root.m3u8, p/<n>.m3u8, r/<n>.<ext>
    SFProxySession *s = p.count >= 3 ? _sessions[p[1]] : nil;
    if (!s || ![p[0] isEqual:s.hls ? @"h" : @"f"]) { [x respondJSON:404 object:@{@"error": @"not found"}]; return; }
    if (p.count == 4 && [p[2] isEqual:@"subs"]) {
        NSUInteger i = (NSUInteger)[p[3] integerValue];
        NSString *key = i < s.subs.count ? s.subs[i] : nil;
        long long n = key ? [SFProxyStore() extentsOf:key].bytes : 0;
        NSData *d = n ? [SFProxyStore() read:key start:0 length:(NSUInteger)n] : nil;
        if (d) [x respond:200 type:@"text/vtt; charset=utf-8" body:d]; else [x respondJSON:404 object:@{@"error": @"not stored"}];
        return;
    }
    if (s.hls) { [self serveHLS:x session:s]; return; }
    if (s.total > 0) { [self answer:x session:s]; return; }
    if (!s.url) { [x respondJSON:404 object:@{@"error": @"not stored"}]; return; }
    // the length is not known yet: one byte from the source tells it (and the type)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        __block long long total = 0; __block NSString *mime;
        SFCurlStream(s.url, 0, 1, 0, ^BOOL(NSInteger status, long long t, NSString *m) { if (status < 400) { total = t; mime = m; } return NO; },
                     ^BOOL(NSData *b) { return NO; }, NULL);
        dispatch_async(self->_q, ^{
            if (total > 0) [self learn:s total:total mime:mime];
            if (s.total > 0) [self answer:x session:s];
            else [x respondJSON:502 object:@{@"error": @"the source told no length"}];
        });
    });
}

- (void)answer:(SFHTTPExchange *)x session:(SFProxySession *)s {
    long long start, end; BOOL partial;
    NSString *range = [x.request header:@"range"];
    if (!SFHTTPParseRange(range, s.total, &start, &end, &partial)) {
        [x begin:416 headers:@{@"Content-Range": [NSString stringWithFormat:@"bytes */%lld", s.total], @"Content-Length": @"0"}];
        [x finish];
        return;
    }
    NSMutableDictionary *h = [@{@"Content-Type": s.mime ?: @"video/mp4", @"Accept-Ranges": @"bytes",
                                @"Content-Length": [NSString stringWithFormat:@"%lld", end - start]} mutableCopy];
    if (partial) h[@"Content-Range"] = [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end - 1, s.total];
    [x begin:partial ? 206 : 200 headers:h];
    if ([x.request.method isEqualToString:@"HEAD"]) { [x finish]; return; }
    [self pump:s from:start to:end into:x];
}

// [from, to) to the reader: stored pieces from disk, each gap from the source in one streamed request
- (void)pump:(SFProxySession *)s from:(long long)from to:(long long)to into:(SFHTTPExchange *)x {
    if (from >= to || x.closed) { [x finish]; return; }
    NSData *disk = [SFProxyStore() readAvailable:s.key start:from max:(NSUInteger)MIN((long long)kPiece, to - from)];
    if (disk) {
        [x write:disk done:^(BOOL ok) { if (ok) [self pump:s from:from + (long long)disk.length to:to into:x]; else [x finish]; }];
        return;
    }
    if (!s.url) { [x finish]; return; }   // stored session, a gap: a short body
    NSArray *gap = [[SFProxyStore() extentsOf:s.key] missingFrom:from to:to].firstObject;
    long long gapEnd = gap ? [gap[1] longLongValue] : to;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        __block long long at = from;
        BOOL ok = [self stream:s from:from to:gapEnd rate:0 each:^BOOL(NSData *piece) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL written = NO;
            dispatch_async(self->_q, ^{ [x write:piece done:^(BOOL w) { written = w; dispatch_semaphore_signal(sem); }]; });
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);   // backpressure: the reader's pace
            at += (long long)piece.length;
            return written;
        }];
        dispatch_async(self->_q, ^{
            if (ok && at == gapEnd) [self pump:s from:at to:to into:x];
            else [x finish];   // the source failed or the reader left: a short body, the reader reconnects
        });
    });
}

// Background: the source's bytes [from, to) of the session's file, gathered to kFlush pieces, each
// written to the store and handed to `each` (NO: stop). YES when all arrived.
- (BOOL)stream:(SFProxySession *)s from:(long long)from to:(long long)to rate:(long long)rate each:(BOOL (^)(NSData *))each {
    __block long long at = from;
    __block BOOL stop = NO;
    NSMutableData *buf = [NSMutableData new];
    BOOL (^flush)(void) = ^BOOL {
        if (!buf.length) return YES;
        NSData *piece = [buf copy];
        [SFProxyStore() write:piece key:s.key item:s.item kind:@"file" total:s.total at:at];
        at += (long long)piece.length;
        [buf setLength:0];
        return each(piece);
    };
    NSError *e = nil;
    BOOL ok = SFCurlStream(s.url, from, to, rate, ^BOOL(NSInteger status, long long total, NSString *mime) {
        if (status >= 400 || (s.total && total > 0 && total != s.total)) { stop = YES; return NO; }   // gone, or another file now
        if (from > 0 && status != 206) { stop = YES; SFLog(@"media-proxy: %@ - the source ignores ranges", s.item); return NO; }   // (its bytes would land at the wrong place)
        return YES;
    }, ^BOOL(NSData *bytes) {
        [buf appendData:bytes];
        if (buf.length >= kFlush && !flush()) { stop = YES; return NO; }
        return YES;
    }, &e);
    if (!stop && !flush()) stop = YES;
    if (!ok) SFLog(@"media-proxy: %@ [%lld, %lld) failed at %lld: %@", s.item, from, to, at, e.localizedDescription);
    return ok && !stop && at == to;
}

#pragma mark Filling

// a download's subtitles: small tracks of their own (`prefix`:<n>), returned as manifest entries; one
// that fails is not offered. Background.
- (NSArray *)fillSubs:(NSArray *)subs item:(NSString *)item prefix:(NSString *)prefix cancelled:(BOOL (^)(void))cancelled {
    NSMutableArray *stored = [NSMutableArray new];
    [subs enumerateObjectsUsingBlock:^(NSDictionary *t, NSUInteger i, BOOL *stop) {
        if (cancelled() || ![t[@"url"] isKindOfClass:[NSString class]]) return;
        NSInteger st = 0;
        NSData *vtt = SFCurlFetch(t[@"url"], @"GET", nil, nil, &st, NULL);
        if (!vtt.length || st >= 400) return;
        NSString *key = [NSString stringWithFormat:@"%@:subs:%lu", prefix, (unsigned long)i];
        [SFProxyStore() write:vtt key:key item:item kind:@"subs" total:(long long)vtt.length at:0];
        [stored addObject:@{@"key": key, @"lang": t[@"lang"] ?: @"", @"kind": t[@"kind"] ?: @"", @"name": t[@"name"] ?: @""}];
    }];
    return stored;
}

- (dispatch_block_t)fill:(NSURL *)url item:(NSString *)item subs:(NSArray *)subs duration:(double)duration
                progress:(void (^)(double))progress done:(void (^)(NSError *))done {
    if ([SFMediaProxy isPlaylist:url]) return [self fillHLS:url item:item subs:subs progress:progress done:done];
    __block BOOL cancelled = NO;
    SFProxySession *s = [SFProxySession new];
    s.item = item; s.url = url.absoluteString;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *err = nil;
        // the length first (one byte), then every gap
        __block long long total = 0; __block NSString *mime;
        SFCurlStream(s.url, 0, 1, 0, ^BOOL(NSInteger st, long long t, NSString *m) { if (st < 400) { total = t; mime = m; } return NO; },
                     ^BOOL(NSData *b) { return NO; }, &err);
        if (total > 0) dispatch_sync(self->_q, ^{ [self learn:s total:total mime:mime]; });
        if (!s.key) { SFMain(^{ if (!cancelled) done(err ?: SFError(@"Die Quelle nennt keine Länge.")); }); return; }
        long long have = [SFProxyStore() extentsOf:s.key].bytes;
        // 3x the playback rate (as ffmpeg's -readrate 3 was): background loading never crowds out streaming
        long long rate = duration > 0 ? MAX(256 * 1024, (long long)(3 * total / duration)) : 0;
        SFLog(@"media-proxy: filling %@ - %.0f of %.0f MB on disk already", item, have / 1048576.0, total / 1048576.0);
        __block long long done_ = have;
        for (NSArray *gap in [[SFProxyStore() extentsOf:s.key] missingFrom:0 to:total]) {
            BOOL ok = [self stream:s from:[gap[0] longLongValue] to:[gap[1] longLongValue] rate:rate each:^BOOL(NSData *piece) {
                done_ += (long long)piece.length;
                double p = MIN(0.99, (double)done_ / total);
                SFMain(^{ if (!cancelled) progress(p); });
                return !cancelled;
            }];
            if (!ok || cancelled) break;
        }
        NSArray *stored = [self fillSubs:subs item:item prefix:s.key cancelled:^BOOL { return cancelled; }];
        NSMutableDictionary *m = [[SFProxyStore() manifestOf:item] mutableCopy];
        if (m && stored.count) { m[@"subs"] = stored; [SFProxyStore() setManifest:m forItem:item]; }
        [SFProxyStore() sync];
        BOOL complete = [SFProxyStore() itemIsComplete:item];
        SFMain(^{
            if (cancelled) return;
            if (complete) { progress(1); done(nil); }
            else done(SFError(@"Unvollständig geladen – wird erneut versucht"));
        });
    });
    return ^{ cancelled = YES; };
}
@end
