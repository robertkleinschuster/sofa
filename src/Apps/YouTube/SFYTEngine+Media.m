// The engine's sessions as local URLs for mpv and the downloads' fill (the URLs open() answers, under the
// loopback server's base):
//   GET|HEAD /s/<sid>/video   /s/<sid>/audio   /s/<sid>/audio/<key>    (Range, 206)
//   GET /s/<sid>/live.m3u8    (lives / post-live DVR: the HLS media playlist, naming...)
//   GET /s/<sid>/seg/<n>.<ext> (...its segments, fetched by the engine from googlevideo)
//   GET /s/<sid>/subs/<key>.vtt   (kept in the store: SFYTEngine+Store.m)
//   GET /s/<sid>/status       (diagnostics)
// Media bytes come from the page in pieces (engine read(): waits for SABR like a reader) and go out
// as they arrive; a reader that goes away (a seek) stops the reading. Every piece passes the media
// store (docs/media-store.md): what is on disk is served from there without asking the engine (a
// resume, a phone's lounge video watched before, a download of a watched video), what the engine
// delivers goes to disk on the way. A stored session (SFYTEngine+Store.m) has no engine session
// behind it: the disk or nothing.
#import "SFModel.h"
#import "SFYTEngine+Private.h"
#import "SFJSON.h"
#import "SFDownloads.h"
#import "SFMediaStore.h"

static const NSUInteger kPiece = 1 << 20;              // bytes per engine read
static const NSTimeInterval kReadTimeout = 120;        // a read waits for SABR; longer = the page is gone

static NSString *ErrorJSON(NSError *e) {
    return [NSString stringWithFormat:@"engine: %@", e.localizedDescription];
}

@implementation SFYTEngine (Media)

- (void)serveSession:(SFHTTPExchange *)x {
    NSArray *p = x.request.pathParts;   // s, sid, what[, sub]
    NSString *m = x.request.method;
    if (![m isEqualToString:@"GET"] && ![m isEqualToString:@"HEAD"]) { [x respondJSON:405 object:@{@"error": @"method not allowed"}]; return; }
    if (p.count < 3 || p.count > 4) { [x respondJSON:404 object:@{@"error": @"not found"}]; return; }
    NSString *sid = p[1], *what = p[2], *sub = p.count == 4 ? p[3] : nil;
    if (!sub && ([what isEqualToString:@"video"] || [what isEqualToString:@"audio"])) { [self serveTrack:what sid:sid to:x]; return; }
    if (sub && [what isEqualToString:@"audio"]) { [self serveTrack:sub sid:sid to:x]; return; }
    if (!sub && [what isEqualToString:@"live.m3u8"]) {
        [self text:@"playlist" args:@[sid] type:@"application/vnd.apple.mpegurl" to:x]; return;
    }
    if (sub && [what isEqualToString:@"seg"]) { [self serveSegment:sub.integerValue sid:sid to:x]; return; }
    if (sub && [what isEqualToString:@"subs"] && [sub hasSuffix:@".vtt"]) {
        [self subtitles:[sub substringToIndex:sub.length - 4] session:sid done:^(NSString *vtt, NSError *e) {
            if (!vtt) { [x respondJSON:e.code ?: 502 object:@{@"error": ErrorJSON(e)}]; return; }
            [x respond:200 type:@"text/vtt; charset=utf-8" body:[vtt dataUsingEncoding:NSUTF8StringEncoding]];
        }];
        return;
    }
    if (!sub && [what isEqualToString:@"status"]) {
        [self request:@"status" args:@[sid] timeout:5 done:^(id v, NSError *e) {
            if (e) [x respondJSON:e.code ?: 500 object:@{@"error": ErrorJSON(e)}]; else [x respondJSON:200 object:v ?: @{}];
        }];
        return;
    }
    [x respondJSON:404 object:@{@"error": @"not found"}];
}

- (void)text:(NSString *)method args:(NSArray *)args type:(NSString *)type to:(SFHTTPExchange *)x {
    [self request:method args:args timeout:30 done:^(id v, NSError *e) {
        if (e || !str(v)) { [x respondJSON:e.code ?: 502 object:@{@"error": e ? ErrorJSON(e) : @"no text"}]; return; }
        [x respond:200 type:type body:[(NSString *)v dataUsingEncoding:NSUTF8StringEncoding]];
    }];
}

// A live segment, whole (a few MB at most): the reader's request, made by the engine.
- (void)serveSegment:(NSInteger)n sid:(NSString *)sid to:(SFHTTPExchange *)x {
    [self request:@"segment" args:@[sid, @(n)] timeout:kReadTimeout done:^(id v, NSError *e) {
        NSDictionary *r = dict(v);
        NSData *bytes = bin(r[@"data"]);
        if (e || !bytes) { [x respondJSON:(e.code >= 400 && e.code < 600) ? e.code : 502 object:@{@"error": e ? ErrorJSON(e) : @"malformed segment"}]; return; }
        [x respond:200 type:str(r[@"mimeType"]) ?: @"video/mp2t" body:bytes];
    }];
}

// One piece of a track: done(bytes, total, mimeType) or an error. Engine queue.
- (void)read:(NSString *)sid track:(NSString *)key at:(long long)offset max:(NSUInteger)max
        done:(void (^)(NSData *bytes, long long total, NSString *mime, NSError *e))done {
    [self read:sid track:key at:offset max:max superseded:nil done:done];
}

// The same; what is not on disk is asked of the engine only while `superseded` says NO (else error
// 409): a reader the player has left behind starts no SABR run.
- (void)read:(NSString *)sid track:(NSString *)key at:(long long)offset max:(NSUInteger)max superseded:(BOOL (^)(void))superseded
        done:(void (^)(NSData *bytes, long long total, NSString *mime, NSError *e))done {
    SFMediaStore *store = [SFDownloads shared].mediaStore;
    NSDictionary *t = [self trackInfo:key session:sid];
    BOOL stored = [self isStoredSession:sid];   // no engine session behind it: the disk or nothing
    NSString *tid = str(t[@"id"]);
    long long total = [num(t[@"total"]) longLongValue];
    if (tid.length && offset < total) {   // from disk, off the engine queue (a disk read may take a moment)
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *disk = [store readAvailable:tid start:offset max:(NSUInteger)MIN((long long)max, total - offset)];
            dispatch_async(self.queue, ^{
                if (disk) done(disk, total, str(t[@"mimeType"]) ?: @"application/octet-stream", nil);
                else if (stored) done(nil, 0, nil, [NSError errorWithDomain:@"SFYTEngine" code:404 userInfo:@{NSLocalizedDescriptionKey: @"not in the media store"}]);
                else if (superseded && superseded()) done(nil, 0, nil, [NSError errorWithDomain:@"SFYTEngine" code:409 userInfo:@{NSLocalizedDescriptionKey: @"superseded by a newer request on the track"}]);
                else [self readFromEngine:sid track:key at:offset max:max done:done];
            });
        });
        return;
    }
    if (stored) { done(nil, 0, nil, [NSError errorWithDomain:@"SFYTEngine" code:offset >= total && total ? 416 : 404 userInfo:@{NSLocalizedDescriptionKey: @"not in the media store"}]); return; }
    if (superseded && superseded()) { done(nil, 0, nil, [NSError errorWithDomain:@"SFYTEngine" code:409 userInfo:@{NSLocalizedDescriptionKey: @"superseded by a newer request on the track"}]); return; }
    [self readFromEngine:sid track:key at:offset max:max done:done];
}

- (void)readFromEngine:(NSString *)sid track:(NSString *)key at:(long long)offset max:(NSUInteger)max
                  done:(void (^)(NSData *bytes, long long total, NSString *mime, NSError *e))done {
    [self request:@"read" args:@[sid, key, @(offset), @(max)] timeout:kReadTimeout done:^(id v, NSError *e) {
        NSDictionary *r = dict(v);
        NSData *bytes = bin(r[@"data"]);
        if (e || !bytes || ![r[@"total"] isKindOfClass:[NSNumber class]]) { done(nil, 0, nil, e ?: SFError(@"engine: malformed read")); return; }
        long long total = [r[@"total"] longLongValue];
        NSString *mime = str(r[@"mimeType"]) ?: @"application/octet-stream", *tid = str(r[@"id"]);
        NSString *vid = [self videoOfSession:sid];
        if (tid.length && bytes.length && vid) {   // to disk on the way (and known for the next read)
            [self noteSession:sid video:nil stored:NO tracks:@{key: @{@"id": tid, @"total": @(total), @"mimeType": mime}}];
            [[SFDownloads shared].mediaStore write:bytes key:tid item:[@"yt:" stringByAppendingString:vid] kind:key total:total at:offset];
        }
        done(bytes, total, mime, nil);
    }];
}

// The first piece tells the track's size and type; the answer's head follows from it.
- (void)serveTrack:(NSString *)key sid:(NSString *)sid to:(SFHTTPExchange *)x {
    NSString *range = [x.request header:@"range"];
    // where the first read starts: the range's start; a suffix range or none starts at 0 (its total decides)
    long long first = 0, want = kPiece;
    if ([range hasPrefix:@"bytes="]) {
        NSArray *ab = [[range substringFromIndex:6] componentsSeparatedByString:@"-"];
        NSString *a = ab.firstObject, *b = ab.count == 2 ? ab[1] : nil;
        if (a.length) first = MAX(0, a.longLongValue);
        // never read past an explicit end: bytes beyond a header probe are a reader there for the
        // engine, which then starts a SABR run at that position (a request to YouTube)
        if (a.length && b.length) want = MAX(1, MIN((long long)kPiece, b.longLongValue + 1 - first));
    }
    BOOL head = [x.request.method isEqualToString:@"HEAD"];
    // mpv leaves its header parse's connection open (reading ahead) after seeking to the resume
    // position: once the newer request exists, the old one gets the disk's bytes but nothing from
    // the engine - else its read past the stored start was a second SABR run (2026-11-09: a resume
    // served from the store, the engine never saw the newer request)
    NSUInteger n = head ? 0 : [self beginRequestOn:key session:sid];
    NSDate *asked = [NSDate date];
    [self read:sid track:key at:first max:head ? 1 : (NSUInteger)want done:^(NSData *bytes, long long total, NSString *mime, NSError *e) {
        // where a start's seconds go: a reader that waited for its first bytes (SABR fetching them)
        NSTimeInterval waited = -[asked timeIntervalSinceNow];
        if (waited > 0.3) SFLog(@"yt-engine: %@/%@ at %lld (%@) waited %.1f s for its first bytes", sid, key, first, range ?: @"no range", waited);
        if (e) {
            NSInteger st = e.code == 416 ? 416 : (e.code >= 400 && e.code < 600 ? e.code : 502);
            [x respondJSON:st object:@{@"error": ErrorJSON(e)}];
            return;
        }
        long long start, end; BOOL partial;
        if (!SFHTTPParseRange(range, total, &start, &end, &partial)) {
            [x begin:416 headers:@{@"Content-Range": [NSString stringWithFormat:@"bytes */%lld", total], @"Content-Length": @"0"}];
            [x finish];
            return;
        }
        NSMutableDictionary *h = [@{@"Content-Type": mime, @"Accept-Ranges": @"bytes",
                                    @"Content-Length": [NSString stringWithFormat:@"%lld", end - start]} mutableCopy];
        if (partial) h[@"Content-Range"] = [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end - 1, total];
        [x begin:partial ? 206 : 200 headers:h];
        if (head) { [x finish]; return; }
        if (start != first) { [self pump:key sid:sid request:n from:start to:end into:x]; return; }   // suffix range: read again from its start
        NSData *piece = (long long)bytes.length > end - start ? [bytes subdataWithRange:NSMakeRange(0, (NSUInteger)(end - start))] : bytes;
        [x write:piece done:^(BOOL ok) {
            if (ok) [self pump:key sid:sid request:n from:start + (long long)piece.length to:end into:x]; else [x finish];
        }];
    }];
}

// Pieces [from, to) to the reader (request n on the track), one read at a time, until done, the reader
// is gone or - for what is not on disk - a newer request on the track has begun.
- (void)pump:(NSString *)key sid:(NSString *)sid request:(NSUInteger)n from:(long long)from to:(long long)to into:(SFHTTPExchange *)x {
    if (from >= to || x.closed) { [x finish]; return; }
    BOOL (^superseded)(void) = ^BOOL { return [self request:n supersededOn:key session:sid]; };
    [self read:sid track:key at:from max:(NSUInteger)MIN((long long)kPiece, to - from) superseded:superseded
          done:^(NSData *bytes, long long total, NSString *mime, NSError *e) {
        if (e || !bytes.length) {   // short body: the reader sees the premature end and reconnects
            if (e.code == 409) SFLog(@"yt-engine: %@/%@ a newer request took over - this one ends at %lld (no engine read)", sid, key, from);
            else if (e) SFLog(@"yt-engine: read %@/%@ at %lld failed: %@", sid, key, from, e.localizedDescription);
            [x finish];
            return;
        }
        NSData *piece = (long long)bytes.length > to - from ? [bytes subdataWithRange:NSMakeRange(0, (NSUInteger)(to - from))] : bytes;
        [x write:piece done:^(BOOL ok) {
            if (ok) [self pump:key sid:sid request:n from:from + (long long)piece.length to:to into:x]; else [x finish];
        }];
    }];
}
@end
