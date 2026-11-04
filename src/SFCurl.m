#import "SFCurl.h"
#import "SFNet.h"
#import "SFModel.h"
#import "SFRuntime.h"
#include <curl/curl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#pragma mark - Hosts

static NSMutableSet *curlHosts(void) {
    static NSMutableSet *s; static dispatch_once_t o;
    dispatch_once(&o, ^{
        // bekannt: ORF (API, Bilder, Video-CDNs) — nur AES-GCM/TLS 1.3
        s = [NSMutableSet setWithArray:@[@"api-tvthek.orf.at", @"apasfiis.sf.apa.at", @"apasfpd.sf.apa.at",
                                         @"vod-at.mdn.ors.at", @"vod-ww.mdn.ors.at", @"orf1.mdn.ors.at", @"orf2.mdn.ors.at",
                                         @"orf2w.mdn.ors.at", @"orf3.mdn.ors.at", @"orfs.mdn.ors.at"]];
    });
    return s;
}
BOOL SFHostNeedsCurl(NSString *host) {
    if (!host) return NO;
    NSMutableSet *s = curlHosts();
    @synchronized (s) {
        if ([s containsObject:host]) return YES;
        if ([host hasSuffix:@".mdn.ors.at"] || [host hasSuffix:@".sf.apa.at"]) return YES;
    }
    return NO;
}
void SFMarkHostNeedsCurl(NSString *host) {
    if (!host) return;
    NSMutableSet *s = curlHosts();
    @synchronized (s) { if (![s containsObject:host]) { [s addObject:host]; SFLog(@"tls: %@ -> curl", host); } }
}
BOOL SFIsTLSError(NSError *e) {
    if (![e.domain isEqualToString:NSURLErrorDomain]) return NO;
    return (e.code <= -1200 && e.code >= -1206) || e.code == -1205;
}

#pragma mark - Fetch

static void curlInit(void) {
    static dispatch_once_t o;
    dispatch_once(&o, ^{ curl_global_init(CURL_GLOBAL_DEFAULT); });
}

void *SFCurlNew(void) {
    CURL *c = curl_easy_init();
    NSString *ca = SFCABundle();
    if (c && ca) curl_easy_setopt(c, CURLOPT_CAINFO, ca.UTF8String);
    return c;
}

static size_t appendData(char *p, size_t sz, size_t n, void *ud) {
    [(__bridge NSMutableData *)ud appendBytes:p length:sz * n];
    return sz * n;
}

static NSData *fetchFull(NSString *url, NSString *method, NSDictionary *headers, NSData *body,
                         NSInteger *status, NSString **effective, NSError **error) {
    curlInit();
    CURL *c = SFCurlNew();
    if (!c) return nil;
    NSMutableData *out = [NSMutableData new];
    struct curl_slist *hl = NULL;
    for (NSString *k in headers) hl = curl_slist_append(hl, [NSString stringWithFormat:@"%@: %@", k, headers[k]].UTF8String);
    curl_easy_setopt(c, CURLOPT_URL, url.UTF8String);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c, CURLOPT_MAXREDIRS, 8L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 15L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, 60L);
    curl_easy_setopt(c, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(c, CURLOPT_USERAGENT, [SFNet userAgent].UTF8String);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, appendData);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, (__bridge void *)out);
    if (hl) curl_easy_setopt(c, CURLOPT_HTTPHEADER, hl);
    if ([method isEqualToString:@"POST"]) {
        curl_easy_setopt(c, CURLOPT_POST, 1L);
        curl_easy_setopt(c, CURLOPT_POSTFIELDSIZE, (long)body.length);
        curl_easy_setopt(c, CURLOPT_POSTFIELDS, body.bytes);
    } else if ([method isEqualToString:@"HEAD"]) {
        curl_easy_setopt(c, CURLOPT_NOBODY, 1L);
    }
    CURLcode rc = curl_easy_perform(c);
    long code = 0; char *eff = NULL;
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
    curl_easy_getinfo(c, CURLINFO_EFFECTIVE_URL, &eff);
    if (status) *status = code;
    if (effective) *effective = eff ? @(eff) : url;
    if (rc != CURLE_OK && error) *error = [NSError errorWithDomain:@"curl" code:rc userInfo:@{NSLocalizedDescriptionKey: @(curl_easy_strerror(rc))}];
    if (hl) curl_slist_free_all(hl);
    curl_easy_cleanup(c);
    return rc == CURLE_OK ? out : nil;
}

NSData *SFCurlFetch(NSString *url, NSString *method, NSDictionary *headers, NSData *body, NSInteger *status, NSError **error) {
    if (SFSimulatedOffline()) { if (error) *error = SFError(@"Keine Internetverbindung."); return nil; }
    return fetchFull(url, method ?: @"GET", headers, body, status, NULL, error);
}

static size_t writeFile(char *p, size_t sz, size_t n, void *ud) {
    return fwrite(p, sz, n, (FILE *)ud) * sz;
}

BOOL SFCurlDownload(NSString *url, NSString *path, NSError **error) {
    curlInit();
    FILE *f = fopen(path.fileSystemRepresentation, "wb");
    if (!f) { if (error) *error = SFError(@"Datei nicht schreibbar."); return NO; }
    CURL *c = SFCurlNew();
    curl_easy_setopt(c, CURLOPT_URL, url.UTF8String);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);          // GitHub-Assets leiten auf ihr CDN um
    curl_easy_setopt(c, CURLOPT_MAXREDIRS, 8L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 20L);
    curl_easy_setopt(c, CURLOPT_LOW_SPEED_LIMIT, 1024L);      // < 1 KB/s für 60 s -> abbrechen
    curl_easy_setopt(c, CURLOPT_LOW_SPEED_TIME, 60L);
    curl_easy_setopt(c, CURLOPT_FAILONERROR, 1L);
    curl_easy_setopt(c, CURLOPT_USERAGENT, [SFNet userAgent].UTF8String);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, writeFile);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, f);
    CURLcode rc = curl_easy_perform(c);
    curl_easy_cleanup(c);
    BOOL ok = fclose(f) == 0 && rc == CURLE_OK;
    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if (error) *error = [NSError errorWithDomain:@"curl" code:rc userInfo:@{NSLocalizedDescriptionKey: @(curl_easy_strerror(rc))}];
    }
    return ok;
}

#pragma mark - Stream-Proxy

@implementation SFStreamProxy {
    int _fd;
    uint16_t _port;
    dispatch_source_t _src;
}

+ (instancetype)shared {
    static SFStreamProxy *p; static dispatch_once_t o;
    dispatch_once(&o, ^{ p = [SFStreamProxy new]; [p start]; });
    return p;
}

- (void)start {
    _fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in sa = {0};
    sa.sin_len = sizeof sa; sa.sin_family = AF_INET; sa.sin_port = 0;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(_fd, (struct sockaddr *)&sa, sizeof sa) != 0 || listen(_fd, 16) != 0) { SFLog(@"proxy: bind failed"); return; }
    socklen_t len = sizeof sa;
    getsockname(_fd, (struct sockaddr *)&sa, &len);
    _port = ntohs(sa.sin_port);
    _src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _fd, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    int lfd = _fd;
    dispatch_source_set_event_handler(_src, ^{
        int c = accept(lfd, NULL, NULL);
        if (c < 0) return;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{ [self serve:c]; });
    });
    dispatch_resume(_src);
    SFLog(@"proxy: 127.0.0.1:%d", _port);
}

- (NSString *)proxyStringFor:(NSString *)abs {
    NSString *enc = [abs stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
    // Endung erhalten: AVFoundation erkennt HLS u.a. an ".m3u8"
    NSString *ext = [[[NSURL URLWithString:abs] path] pathExtension];
    return [NSString stringWithFormat:@"http://127.0.0.1:%d/p/%@%@", _port, enc, ext.length ? [@"." stringByAppendingString:ext] : @""];
}

- (NSURL *)playableURLFor:(NSURL *)url {
    if (![url.scheme isEqualToString:@"https"] || !SFHostNeedsCurl(url.host) || !_port) return url;
    return [NSURL URLWithString:[self proxyStringFor:url.absoluteString]];
}

static BOOL writeAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t w = write(fd, p, len);
        if (w <= 0) { if (errno == EINTR) continue; return NO; }
        p += w; len -= (size_t)w;
    }
    return YES;
}

static NSString *headerValue(NSString *req, NSString *name) {
    for (NSString *line in [req componentsSeparatedByString:@"\r\n"]) {
        NSRange c = [line rangeOfString:@":"];
        if (c.location == NSNotFound) continue;
        if ([[line substringToIndex:c.location] caseInsensitiveCompare:name] == NSOrderedSame)
            return [[line substringFromIndex:c.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return nil;
}

static const int kMaxHLSVersion = 6;

- (NSString *)rewritePlaylist:(NSString *)pl base:(NSString *)base {
    NSURL *b = [NSURL URLWithString:base];
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *raw in [pl componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!line.length) { [out addObject:line]; continue; }
        if (![line hasPrefix:@"#"]) {
            NSString *abs = [[NSURL URLWithString:line relativeToURL:b] absoluteString];
            [out addObject:abs ? [self proxyStringFor:abs] : line];
            continue;
        }
        // CoreMedia von 10.9 lehnt neuere Playlist-Versionen ab ("Unsupported version: 7"),
        // obwohl TS-Streams keine v7-Features brauchen -> Version deckeln.
        if ([line hasPrefix:@"#EXT-X-VERSION:"]) {
            if ([[line substringFromIndex:15] integerValue] > kMaxHLSVersion)
                line = [NSString stringWithFormat:@"#EXT-X-VERSION:%d", kMaxHLSVersion];
            [out addObject:line];
            continue;
        }
        NSRange u = [line rangeOfString:@"URI=\""];
        if (u.location != NSNotFound) {
            NSUInteger s = NSMaxRange(u);
            NSRange e = [line rangeOfString:@"\"" options:0 range:NSMakeRange(s, line.length - s)];
            if (e.location != NSNotFound) {
                NSString *ref = [line substringWithRange:NSMakeRange(s, e.location - s)];
                NSString *abs = [[NSURL URLWithString:ref relativeToURL:b] absoluteString];
                if (abs && ![ref hasPrefix:@"skd:"]) line = [line stringByReplacingCharactersInRange:NSMakeRange(s, e.location - s) withString:[self proxyStringFor:abs]];
            }
        }
        [out addObject:line];
    }
    return [out componentsJoinedByString:@"\n"];
}

typedef struct {
    int fd;
    BOOL headersSent, failed;
    long status;
    __unsafe_unretained NSMutableDictionary *hdrs;
} StreamCtx;

static size_t hdrCB(char *p, size_t sz, size_t n, void *ud) {
    StreamCtx *c = ud;
    NSString *line = [[NSString alloc] initWithBytes:p length:sz * n encoding:NSISOLatin1StringEncoding];
    if ([line hasPrefix:@"HTTP/"]) {
        [c->hdrs removeAllObjects];   // Redirect-Zwischenantworten verwerfen
        NSArray *parts = [line componentsSeparatedByString:@" "];
        c->status = parts.count > 1 ? [parts[1] integerValue] : 502;
    } else {
        NSRange col = [line rangeOfString:@":"];
        if (col.location != NSNotFound) {
            NSString *k = [[line substringToIndex:col.location] lowercaseString];
            NSString *v = [[line substringFromIndex:col.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([@[@"content-type", @"content-length", @"content-range", @"accept-ranges"] containsObject:k]) c->hdrs[k] = v;
        }
    }
    return sz * n;
}

static void sendHeaders(StreamCtx *c) {
    if (c->headersSent) return;
    c->headersSent = YES;
    long st = c->status ?: 200;
    NSMutableString *h = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", st, st == 206 ? @"Partial Content" : (st < 400 ? @"OK" : @"Error")];
    NSDictionary *names = @{@"content-type": @"Content-Type", @"content-length": @"Content-Length", @"content-range": @"Content-Range", @"accept-ranges": @"Accept-Ranges"};
    for (NSString *k in c->hdrs) [h appendFormat:@"%@: %@\r\n", names[k], c->hdrs[k]];
    [h appendString:@"Connection: close\r\n\r\n"];
    NSData *d = [h dataUsingEncoding:NSUTF8StringEncoding];
    if (!writeAll(c->fd, d.bytes, d.length)) c->failed = YES;
}

static size_t bodyCB(char *p, size_t sz, size_t n, void *ud) {
    StreamCtx *c = ud;
    sendHeaders(c);
    if (c->failed || !writeAll(c->fd, p, sz * n)) { c->failed = YES; return 0; }   // Abbruch, wenn AVPlayer schließt
    return sz * n;
}

- (void)serve:(int)fd {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    struct timeval tv = {10, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    NSMutableData *buf = [NSMutableData new];
    char tmp[4096];
    while (buf.length < 32768) {
        ssize_t r = read(fd, tmp, sizeof tmp);
        if (r <= 0) break;
        [buf appendBytes:tmp length:r];
        if ([[[NSString alloc] initWithData:buf encoding:NSISOLatin1StringEncoding] rangeOfString:@"\r\n\r\n"].location != NSNotFound) break;
    }
    NSString *req = [[NSString alloc] initWithData:buf encoding:NSISOLatin1StringEncoding];
    NSArray *first = [[req componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
    NSString *method = first.count > 0 ? first[0] : @"GET";
    NSString *path = first.count > 1 ? first[1] : @"";
    if (![path hasPrefix:@"/p/"]) { close(fd); return; }
    NSString *enc = [path substringFromIndex:3];
    NSRange dot = [enc rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound) enc = [enc substringToIndex:dot.location];   // angehängte Endung entfernen
    NSString *target = [enc stringByRemovingPercentEncoding];
    if (!target) { close(fd); return; }

    NSString *ext = [[NSURL URLWithString:target] path].pathExtension.lowercaseString;
    if ([ext isEqualToString:@"m3u8"] || [ext isEqualToString:@"m3u"]) {
        NSInteger st = 0; NSString *eff = nil; NSError *e = nil;
        NSData *d = fetchFull(target, @"GET", nil, nil, &st, &eff, &e);
        NSString *pl = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
        if (!pl || st >= 400) {
            SFLog(@"proxy: playlist %ld %@", (long)st, e.localizedDescription ?: @"");
            NSString *h = [NSString stringWithFormat:@"HTTP/1.1 %ld Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", (long)(st ?: 502)];
            writeAll(fd, h.UTF8String, strlen(h.UTF8String)); close(fd); return;
        }
        NSData *body = [[self rewritePlaylist:pl base:eff ?: target] dataUsingEncoding:NSUTF8StringEncoding];
        NSString *h = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: %lu\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n", (unsigned long)body.length];
        writeAll(fd, h.UTF8String, strlen(h.UTF8String));
        if (![method isEqualToString:@"HEAD"]) writeAll(fd, body.bytes, body.length);
        close(fd);
        return;
    }

    // Segmente / Dateien: durchreichen (inkl. Range), ohne alles zu puffern
    curlInit();
    CURL *c = SFCurlNew();
    NSMutableDictionary *hdrs = [NSMutableDictionary new];
    StreamCtx ctx = {fd, NO, NO, 0, hdrs};
    struct curl_slist *hl = NULL;
    NSString *range = headerValue(req, @"Range");
    if (range) hl = curl_slist_append(hl, [@"Range: " stringByAppendingString:range].UTF8String);
    curl_easy_setopt(c, CURLOPT_URL, target.UTF8String);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 15L);
    curl_easy_setopt(c, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(c, CURLOPT_LOW_SPEED_TIME, 30L);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_USERAGENT, [SFNet userAgent].UTF8String);
    curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, hdrCB);
    curl_easy_setopt(c, CURLOPT_HEADERDATA, &ctx);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, bodyCB);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &ctx);
    if ([method isEqualToString:@"HEAD"]) curl_easy_setopt(c, CURLOPT_NOBODY, 1L);
    if (hl) curl_easy_setopt(c, CURLOPT_HTTPHEADER, hl);
    CURLcode rc = curl_easy_perform(c);
    if (!ctx.headersSent && !ctx.failed) {
        if (rc != CURLE_OK && !ctx.status) ctx.status = 502;
        sendHeaders(&ctx);
    }
    if (rc != CURLE_OK && rc != CURLE_WRITE_ERROR) SFLog(@"proxy: %@ -> %s", ((NSURL *)[NSURL URLWithString:target]).host, curl_easy_strerror(rc));
    if (hl) curl_slist_free_all(hl);
    curl_easy_cleanup(c);
    close(fd);
}
@end
