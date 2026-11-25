#import "SFLoopbackClient.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static const NSUInteger kChunk = 256 * 1024;
static const NSUInteger kMaxHead = 32 * 1024;
static const int kReadTimeout = 150;   // the engine's reads wait up to 120 s for SABR (SFYTEngine+Media.m)

@interface SFLoopbackResponse ()
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSDictionary *headers;
@property (nonatomic, copy) NSData *body;
@end
@implementation SFLoopbackResponse
@end

static BOOL IsLoopback(NSURL *u) {
    return [u.scheme isEqualToString:@"http"] && [u.host isEqualToString:@"127.0.0.1"] && u.port.intValue > 0 && u.port.intValue < 65536;
}

static int Connect(NSURL *u, int timeout) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    struct timeval tv = {timeout, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    struct sockaddr_in sa = {0};
    sa.sin_len = sizeof sa; sa.sin_family = AF_INET; sa.sin_port = htons((uint16_t)u.port.intValue);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) { close(fd); return -1; }
    return fd;
}

static BOOL Send(int fd, NSString *method, NSURL *u, NSString *range) {
    NSString *target = u.path.length ? CFBridgingRelease(CFURLCopyPath((__bridge CFURLRef)u)) : @"/";   // still percent-encoded
    if (u.query.length) target = [target stringByAppendingFormat:@"?%@", u.query];
    NSMutableString *r = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: 127.0.0.1:%@\r\n", method, target, u.port];
    if (range.length) [r appendFormat:@"Range: %@\r\n", range];
    [r appendString:@"Connection: close\r\n\r\n"];
    NSData *d = [r dataUsingEncoding:NSISOLatin1StringEncoding];
    const uint8_t *p = d.bytes; size_t left = d.length;
    while (left) {
        ssize_t w = send(fd, p, left, 0);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return NO;
        p += w; left -= (size_t)w;
    }
    return YES;
}

// The answer's head (status, lower-case headers); `rest` = body bytes read with it. NO: none.
static BOOL ReadHead(int fd, NSInteger *status, NSDictionary **headers, NSMutableData **rest) {
    NSMutableData *buf = [NSMutableData new];
    uint8_t chunk[16384];
    NSData *sep = [NSData dataWithBytes:"\r\n\r\n" length:4];
    NSRange end = {NSNotFound, 0};
    while (end.location == NSNotFound) {
        if (buf.length > kMaxHead) return NO;
        ssize_t n = recv(fd, chunk, sizeof chunk, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        [buf appendBytes:chunk length:(NSUInteger)n];
        end = [buf rangeOfData:sep options:0 range:NSMakeRange(0, buf.length)];
    }
    NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, end.location)] encoding:NSISOLatin1StringEncoding];
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray *first = [lines.firstObject componentsSeparatedByString:@" "];
    if (first.count < 2 || ![first[0] hasPrefix:@"HTTP/1."]) return NO;
    *status = [first[1] integerValue];
    NSMutableDictionary *h = [NSMutableDictionary new];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange c = [lines[i] rangeOfString:@":"];
        if (c.location == NSNotFound) continue;
        h[[[lines[i] substringToIndex:c.location] lowercaseString]] = [[lines[i] substringFromIndex:c.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    *headers = h;
    *rest = [[buf subdataWithRange:NSMakeRange(NSMaxRange(end), buf.length - NSMaxRange(end))] mutableCopy];
    return YES;
}

@implementation SFLoopbackClient

+ (SFLoopbackResponse *)get:(NSURL *)url range:(NSString *)range timeout:(NSTimeInterval)timeout {
    SFLoopbackResponse *r = [SFLoopbackResponse new];
    if (!IsLoopback(url)) return r;
    int fd = Connect(url, (int)MAX(1, timeout));
    if (fd < 0) return r;
    NSInteger status = 0; NSDictionary *headers = nil; NSMutableData *body = nil;
    if (Send(fd, @"GET", url, range) && ReadHead(fd, &status, &headers, &body)) {
        uint8_t chunk[65536];
        ssize_t n;
        while ((n = recv(fd, chunk, sizeof chunk, 0)) > 0 || (n < 0 && errno == EINTR)) if (n > 0) [body appendBytes:chunk length:(NSUInteger)n];
        long long want = [headers[@"content-length"] longLongValue];
        if (!headers[@"content-length"] || (long long)body.length == want) { r.status = status; r.headers = headers; r.body = body; }
    }
    close(fd);
    return r;
}

+ (void)relay:(NSURL *)url to:(SFHTTPExchange *)x {
    NSString *method = [x.request.method isEqualToString:@"HEAD"] ? @"HEAD" : @"GET";
    NSString *range = [x.request header:@"range"];
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    // the exchange's callbacks run on its server's queue; this block reads the upstream on its own
    // thread and waits for each piece to be on the wire before reading the next
    __block int fd = -1;
    __block BOOL gone = NO;
    NSObject *lock = [NSObject new];
    x.onClose = ^{ @synchronized (lock) { gone = YES; if (fd >= 0) shutdown(fd, SHUT_RDWR); } };   // unblocks the read
    dispatch_async(q, ^{
        int s = IsLoopback(url) ? Connect(url, kReadTimeout) : -1;
        @synchronized (lock) { fd = s; if (gone && s >= 0) shutdown(s, SHUT_RDWR); }
        NSInteger status = 0; NSDictionary *headers = nil; NSMutableData *first = nil;
        BOOL ok = s >= 0 && Send(s, method, url, range) && ReadHead(s, &status, &headers, &first);
        if (!ok) {
            if (s >= 0) close(s);
            SFLog(@"loopback: no answer from %@:%@%@", url.host, url.port, url.path);
            dispatch_async(x.queue, ^{ [x respondJSON:502 object:@{@"error": @"local service did not answer"}]; });
            return;
        }
        NSMutableDictionary *h = [NSMutableDictionary new];
        for (NSString *k in @[@"content-type", @"content-length", @"content-range", @"accept-ranges"])
            if (headers[k]) h[[k capitalizedString]] = headers[k];
        dispatch_async(x.queue, ^{ [x begin:status headers:h]; });
        if ([method isEqualToString:@"HEAD"] || ([headers[@"content-length"] isEqual:@"0"])) { close(s); dispatch_async(x.queue, ^{ [x finish]; }); return; }
        NSData *piece = first.length ? first : nil;
        uint8_t *chunk = malloc(kChunk);
        for (;;) {
            if (!piece) {
                ssize_t n = recv(s, chunk, kChunk, 0);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) break;   // the end (Connection: close), or the reader went away
                piece = [NSData dataWithBytes:chunk length:(NSUInteger)n];
            }
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL written = NO;
            NSData *p = piece;
            dispatch_async(x.queue, ^{ [x write:p done:^(BOOL w) { written = w; dispatch_semaphore_signal(sem); }]; });
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            piece = nil;
            if (!written) break;
        }
        free(chunk);
        @synchronized (lock) { fd = -1; }
        close(s);
        dispatch_async(x.queue, ^{ [x finish]; });   // a short body when the upstream ended early: the reader sees it and retries
    });
}
@end
