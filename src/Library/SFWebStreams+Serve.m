// SFWebStreams - the media routes of a stream, /m/<stream>/… (on the server's queue):
//   dash:  index.m3u8 · v.m3u8 · a.m3u8 (SFWebHLS) · t/v · t/a (the tracks, Range relayed)
//   hls:   l/<port>/<path> - a local route of the stream (its prefixes only); playlists rewritten
//   file:  media[.ext] - the local route, or the file on disk (Range)
#import "SFWebStreams+Private.h"
#import "SFLoopbackClient.h"

static const NSUInteger kFilePiece = 1 << 20;
static const NSTimeInterval kPlaylistTimeout = 60;

static NSString *const kPlaylistType = @"application/vnd.apple.mpegurl";

static NSString *FileType(NSString *ext) {
    NSDictionary *t = @{@"mp4": @"video/mp4", @"m4v": @"video/mp4", @"m4a": @"audio/mp4", @"mov": @"video/quicktime",
                        @"webm": @"video/webm", @"mp3": @"audio/mpeg", @"ts": @"video/mp2t", @"vtt": @"text/vtt"};
    return t[ext.lowercaseString] ?: @"application/octet-stream";
}

// Every local URL in a playlist -> the stream's l/<port>/ path (absolute on this server)
static NSString *Rewrite(NSString *text, NSString *streamID) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"http://127\\.0\\.0\\.1:([0-9]+)/" options:0 error:nil]; });
    NSString *to = [NSString stringWithFormat:@"/m/%@/l/$1/", streamID];
    return [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:to];
}

@implementation SFWebStreams (Serve)

- (void)serve:(SFHTTPExchange *)x stream:(NSString *)streamID rest:(NSArray *)rest {
    NSString *m = x.request.method;
    if (![m isEqualToString:@"GET"] && ![m isEqualToString:@"HEAD"]) { [x respondJSON:405 object:@{@"error": @"method not allowed"}]; return; }
    SFWebStream *s = [self streamWithID:streamID];
    if (!s) { [x respondJSON:410 object:@{@"error": @"stream ended"}]; return; }
    NSString *what = rest.firstObject ?: @"";
    switch (s.kind) {
        case SFWebStreamDash:
            if (rest.count == 1 && [what isEqualToString:@"index.m3u8"]) { [self text:s.master to:x]; return; }
            if (rest.count == 1 && [what isEqualToString:@"v.m3u8"]) { [self text:s.videoPlaylist to:x]; return; }
            if (rest.count == 1 && [what isEqualToString:@"a.m3u8"]) { [self text:s.audioPlaylist to:x]; return; }
            if (rest.count == 2 && [what isEqualToString:@"t"] && [rest[1] isEqualToString:@"v"]) { [SFLoopbackClient relay:s.video to:x]; return; }
            if (rest.count == 2 && [what isEqualToString:@"t"] && [rest[1] isEqualToString:@"a"]) { [SFLoopbackClient relay:s.audio to:x]; return; }
            break;
        case SFWebStreamHLS:
            if (rest.count >= 3 && [what isEqualToString:@"l"]) { [self local:rest stream:s to:x]; return; }
            break;
        case SFWebStreamFile:
            if (rest.count == 1 && [what hasPrefix:@"media"]) { [SFLoopbackClient relay:s.upstream to:x]; return; }
            break;
        case SFWebStreamLocalFile:
            if (rest.count == 1 && [what hasPrefix:@"media"]) { [self file:s.upstream.path to:x]; return; }
            break;
    }
    [x respondJSON:404 object:@{@"error": @"not found"}];
}

- (void)text:(NSString *)text to:(SFHTTPExchange *)x {
    [x respond:200 type:kPlaylistType body:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

// l/<port>/<path...>: only what belongs to the stream's own local routes
- (void)local:(NSArray *)rest stream:(SFWebStream *)s to:(SFHTTPExchange *)x {
    NSInteger port = [rest[1] integerValue];
    NSMutableArray *parts = [NSMutableArray new];
    for (NSString *p in [rest subarrayWithRange:NSMakeRange(2, rest.count - 2)])
        [parts addObject:[p stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: @""];
    NSString *query = @"";
    if (x.request.query.count) {
        NSMutableArray *q = [NSMutableArray new];
        [x.request.query enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
            NSCharacterSet *ok = [NSCharacterSet URLQueryAllowedCharacterSet];
            [q addObject:[NSString stringWithFormat:@"%@=%@", [k stringByAddingPercentEncodingWithAllowedCharacters:ok], [v stringByAddingPercentEncodingWithAllowedCharacters:ok]]];
        }];
        query = [@"?" stringByAppendingString:[q componentsJoinedByString:@"&"]];
    }
    NSString *target = [NSString stringWithFormat:@"http://127.0.0.1:%ld/%@%@", (long)port, [parts componentsJoinedByString:@"/"], query];
    BOOL allowed = NO;
    for (NSString *prefix in s.prefixes) if ([target hasPrefix:prefix]) allowed = YES;
    NSURL *u = allowed && port > 0 && port < 65536 ? [NSURL URLWithString:target] : nil;
    if (!u) { [x respondJSON:403 object:@{@"error": @"not this stream's"}]; return; }
    NSString *ext = u.path.pathExtension.lowercaseString;
    if (![ext isEqualToString:@"m3u8"] && ![ext isEqualToString:@"m3u"]) { [SFLoopbackClient relay:u to:x]; return; }
    NSString *sid = s.identifier;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        SFLoopbackResponse *r = [SFLoopbackClient get:u range:nil timeout:kPlaylistTimeout];
        NSString *text = r.status == 200 ? [[NSString alloc] initWithData:r.body encoding:NSUTF8StringEncoding] : nil;
        dispatch_async(x.queue, ^{
            if (!text) { [x respondJSON:r.status >= 400 ? r.status : 502 object:@{@"error": @"playlist unavailable"}]; return; }
            [self text:Rewrite(text, sid) to:x];
        });
    });
}

// A file on this disk with Range, read off the server's queue piece by piece at the reader's pace
- (void)file:(NSString *)path to:(SFHTTPExchange *)x {
    long long total = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
    NSFileHandle *fh = total > 0 ? [NSFileHandle fileHandleForReadingAtPath:path] : nil;
    if (!fh) { [x respondJSON:404 object:@{@"error": @"file gone"}]; return; }
    long long start, end; BOOL partial;
    if (!SFHTTPParseRange([x.request header:@"range"], total, &start, &end, &partial)) {
        [x begin:416 headers:@{@"Content-Range": [NSString stringWithFormat:@"bytes */%lld", total], @"Content-Length": @"0"}];
        [x finish];
        return;
    }
    NSMutableDictionary *h = [@{@"Content-Type": FileType(path.pathExtension), @"Accept-Ranges": @"bytes",
                                @"Content-Length": [NSString stringWithFormat:@"%lld", end - start]} mutableCopy];
    if (partial) h[@"Content-Range"] = [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end - 1, total];
    [x begin:partial ? 206 : 200 headers:h];
    if ([x.request.method isEqualToString:@"HEAD"]) { [x finish]; return; }
    [self pumpFile:fh from:start to:end into:x];
}

- (void)pumpFile:(NSFileHandle *)fh from:(long long)from to:(long long)to into:(SFHTTPExchange *)x {
    if (from >= to || x.closed) { [fh closeFile]; [x finish]; return; }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *d = nil;
        @try { [fh seekToFileOffset:(unsigned long long)from]; d = [fh readDataOfLength:(NSUInteger)MIN((long long)kFilePiece, to - from)]; }
        @catch (NSException *e) { d = nil; }
        dispatch_async(x.queue, ^{
            if (!d.length) { [fh closeFile]; [x finish]; return; }
            [x write:d done:^(BOOL ok) {
                if (ok) [self pumpFile:fh from:from + (long long)d.length to:to into:x]; else { [fh closeFile]; [x finish]; }
            }];
        });
    });
}
@end
