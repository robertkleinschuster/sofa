#import "SFLocalHTTP.h"
#import "SFHTTPBudget.h"
#import "SFWebSocket+Server.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static const NSUInteger kMaxHead = 16 * 1024;         // request line + headers
static const int kReadTimeoutS = 15;                  // a request that does not arrive in time is dropped

static NSString *decode(NSString *s, BOOL plusIsSpace) {
    if (plusIsSpace) s = [s stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return [s stringByRemovingPercentEncoding] ?: s;
}

static NSString *reason(NSInteger status) {
    switch (status) {
        case 200: return @"OK"; case 204: return @"No Content"; case 206: return @"Partial Content";
        case 400: return @"Bad Request"; case 403: return @"Forbidden"; case 404: return @"Not Found";
        case 405: return @"Method Not Allowed"; case 413: return @"Payload Too Large";
        case 416: return @"Range Not Satisfiable"; case 500: return @"Internal Server Error";
        case 502: return @"Bad Gateway"; case 503: return @"Service Unavailable"; case 504: return @"Gateway Timeout";
        default: return @"Status";
    }
}

static BOOL writeAll(int fd, const uint8_t *p, size_t len) {
    while (len > 0) {
        ssize_t w = write(fd, p, len);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return NO;
        p += w; len -= (size_t)w;
    }
    return YES;
}

#pragma mark - Request

@interface SFHTTPRequest ()
@property (nonatomic) NSString *method;
@property (nonatomic) NSArray *pathParts;
@property (nonatomic) NSDictionary *query;
@property (nonatomic) NSData *body;
@property (nonatomic) NSDictionary *headers;   // lower-case names
@end

@implementation SFHTTPRequest
- (NSString *)header:(NSString *)name { return self.headers[name.lowercaseString]; }

// "GET /a/b?x=1 HTTP/1.1\r\nName: value\r\n..." -> request; nil when malformed
+ (instancetype)parseHead:(NSData *)head {
    NSString *s = [[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding];
    NSArray *lines = [s componentsSeparatedByString:@"\r\n"];
    NSArray *first = [lines.firstObject componentsSeparatedByString:@" "];
    if (first.count != 3 || ![first[2] hasPrefix:@"HTTP/1."]) return nil;
    SFHTTPRequest *r = [SFHTTPRequest new];
    r.method = first[0];
    NSString *target = first[1];
    NSRange q = [target rangeOfString:@"?"];
    NSString *path = q.location == NSNotFound ? target : [target substringToIndex:q.location];
    NSMutableArray *parts = [NSMutableArray new];
    for (NSString *p in [path componentsSeparatedByString:@"/"]) if (p.length) [parts addObject:decode(p, NO)];
    r.pathParts = parts;
    NSMutableDictionary *query = [NSMutableDictionary new];
    if (q.location != NSNotFound) {
        for (NSString *kv in [[target substringFromIndex:q.location + 1] componentsSeparatedByString:@"&"]) {
            if (!kv.length) continue;
            NSRange eq = [kv rangeOfString:@"="];
            NSString *k = eq.location == NSNotFound ? kv : [kv substringToIndex:eq.location];
            query[decode(k, YES)] = eq.location == NSNotFound ? @"" : decode([kv substringFromIndex:eq.location + 1], YES);
        }
    }
    r.query = query;
    NSMutableDictionary *headers = [NSMutableDictionary new];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange c = [lines[i] rangeOfString:@":"];
        if (c.location == NSNotFound) continue;
        headers[[[lines[i] substringToIndex:c.location] lowercaseString]] =
            [[lines[i] substringFromIndex:c.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    r.headers = headers;
    r.body = [NSData data];
    return r;
}
@end

#pragma mark - Exchange

// The connection's socket, touched only on the connection's queue (`_io`). Closed exactly once:
// fd -1 afterwards, so a write or shutdown queued later goes nowhere. (The bare fd number was closed
// by the watch when the reader hung up, then reused by the next accepted connection - the pending
// answer and the second close hit that one: test-units websocket flake 2026-11-08.) `handedOver`:
// the WebSocket owns the fd now.
@interface SFHTTPSocket : NSObject
@property (nonatomic) int fd;
@property (nonatomic) BOOL handedOver;
@end
@implementation SFHTTPSocket
- (void)close { if (_fd >= 0 && !_handedOver) close(_fd); _fd = -1; }
@end

// State lives on the server's queue (`_queue`); the socket is only touched on the connection's own
// serial queue (`_io`), so a blocking write to a slow reader holds up nobody else.
@implementation SFHTTPExchange {
    int _fd;                    // for the read source and the handover; I/O goes through _sock
    SFHTTPSocket *_sock;
    dispatch_queue_t _queue, _io;
    dispatch_source_t _watch;   // readable after the request = the reader closed (or sent garbage)
    BOOL _begun, _finished;
}

- (instancetype)initWithFD:(int)fd request:(SFHTTPRequest *)r queue:(dispatch_queue_t)queue io:(dispatch_queue_t)io {
    if ((self = [super init])) { _fd = fd; _request = r; _queue = queue; _io = io; _sock = [SFHTTPSocket new]; _sock.fd = fd; }
    return self;
}

// Runs on _io once the request is read: notices a reader that goes away before the answer is done.
- (void)watch {
    _watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_fd, 0, _io);
    int fd = _fd;
    SFHTTPSocket *sock = _sock;
    __weak SFHTTPExchange *ws = self;
    dispatch_source_set_event_handler(_watch, ^{
        char buf[512];
        ssize_t n = recv(fd, buf, sizeof buf, 0);   // more bytes after a request are dropped
        if (n > 0 || (n < 0 && errno == EINTR)) return;
        SFHTTPExchange *x = ws;
        if (!x) return;
        dispatch_source_cancel(x->_watch);
        dispatch_async(x->_queue, ^{ [x readerGone]; });
    });
    dispatch_source_set_cancel_handler(_watch, ^{ [sock close]; });
    dispatch_resume(_watch);
}

- (void)readerGone {
    if (_finished || _closed) return;
    _closed = YES;
    void (^f)(void) = self.onClose;
    self.onClose = nil;
    if (f) f();
}

- (void)begin:(NSInteger)status headers:(NSDictionary *)headers {
    if (_begun || _finished) return;
    _begun = YES;
    NSMutableString *h = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, reason(status)];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [h appendFormat:@"%@: %@\r\n", k, v]; }];
    [h appendString:@"Cache-Control: no-store\r\nConnection: close\r\n\r\n"];
    [self send:[h dataUsingEncoding:NSISOLatin1StringEncoding] done:nil];
}

- (void)write:(NSData *)piece done:(void (^)(BOOL))done {
    if (!_begun || _finished || _closed) { if (done) dispatch_async(_queue, ^{ done(NO); }); return; }
    if (SFDevEnv(@"SOFA_PREBUFFER_TEST") && [_request header:@"x-sofa-read-budget"])
        SFLog(@"prebuffer-http: %@ %@ bytes=%lu remaining=%lu", [_request.pathParts componentsJoinedByString:@"/"], [_request header:@"range"], (unsigned long)piece.length, (unsigned long)[SFHTTPBudget remaining:[_request header:@"x-sofa-read-budget"]]);
    if (![SFHTTPBudget take:piece.length token:[_request header:@"x-sofa-read-budget"]]) {
        [self readerGone]; [self finish];
        if (done) dispatch_async(_queue, ^{ done(NO); });
        return;
    }
    [self send:piece done:done];
}

- (void)send:(NSData *)d done:(void (^)(BOOL))done {
    SFHTTPSocket *sock = _sock;
    dispatch_queue_t q = _queue;
    __weak SFHTTPExchange *ws = self;
    dispatch_async(_io, ^{
        BOOL ok = sock.fd >= 0 && writeAll(sock.fd, d.bytes, d.length);
        dispatch_async(q, ^{
            if (!ok) [ws readerGone];
            if (done) done(ok);
        });
    });
}

- (void)finish {
    if (_finished) return;
    if (!_begun) [self begin:500 headers:@{@"Content-Length": @"0"}];
    _finished = YES;
    self.onClose = nil;
    dispatch_source_t w = _watch;
    SFHTTPSocket *sock = _sock;
    // after the queued writes: shut down the socket; the watch's cancel handler closes it
    dispatch_async(_io, ^{
        if (sock.fd >= 0) shutdown(sock.fd, SHUT_WR);
        if (w) dispatch_source_cancel(w); else [sock close];
    });
}

- (void)respond:(NSInteger)status type:(NSString *)type body:(NSData *)body {
    if (_begun) return;
    body = body ?: [NSData data];
    NSMutableDictionary *h = [@{@"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} mutableCopy];
    if (type) h[@"Content-Type"] = type;
    [self begin:status headers:h];
    if (body.length && ![_request.method isEqualToString:@"HEAD"] &&
        [SFHTTPBudget take:body.length token:[_request header:@"x-sofa-read-budget"]]) [self send:body done:nil];
    [self finish];
}

- (SFWebSocket *)acceptWebSocket:(NSUInteger)max {
    SFHTTPRequest *r = _request;
    NSString *key = [r header:@"sec-websocket-key"];
    BOOL upgrade = [r.method isEqualToString:@"GET"] && [[r header:@"upgrade"] caseInsensitiveCompare:@"websocket"] == NSOrderedSame
        && [[[r header:@"connection"] lowercaseString] rangeOfString:@"upgrade"].location != NSNotFound
        && [[r header:@"sec-websocket-version"] isEqualToString:@"13"] && key.length;
    if (!upgrade || _begun) { [self respond:400 type:nil body:nil]; return nil; }
    _begun = _finished = YES;   // no HTTP answer after this
    self.onClose = nil;
    SFWebSocket *ws = [[SFWebSocket alloc] initWithFD:_fd queue:_queue io:_io maxMessage:max];
    NSString *head = [NSString stringWithFormat:@"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %@\r\n\r\n", SFWSAccept(key)];
    NSData *d = [head dataUsingEncoding:NSISOLatin1StringEncoding];
    dispatch_source_t w = _watch;
    SFHTTPSocket *sock = _sock;
    dispatch_async(_io, ^{
        if (sock.fd < 0) { [ws ended]; return; }   // the reader hung up before the handover: onClose
        sock.handedOver = YES;
        if (w) dispatch_source_cancel(w);   // the socket reads its frames from here on
        writeAll(sock.fd, d.bytes, d.length);
        [ws startReading];   // a failed write: the read source sees the broken connection and ends it
    });
    return ws;
}

- (void)respondJSON:(NSInteger)status object:(id)object {
    NSData *d = object ? [NSJSONSerialization dataWithJSONObject:object options:0 error:nil] : nil;
    if (object && !d) { status = 500; d = [@"{\"error\":\"answer is not JSON\"}" dataUsingEncoding:NSUTF8StringEncoding]; }
    [self respond:status type:@"application/json" body:d];
}
@end

#pragma mark - Server

@implementation SFLocalHTTP {
    NSString *_name;
    dispatch_queue_t _queue;
    NSUInteger _maxBody;
    SFHTTPHandler _handler;
    dispatch_source_t _accept;
}

- (instancetype)initWithName:(NSString *)name queue:(dispatch_queue_t)queue maxBody:(NSUInteger)maxBody handler:(SFHTTPHandler)handler {
    if ((self = [super init])) { _name = name; _queue = queue; _maxBody = maxBody; _handler = [handler copy]; }
    return self;
}

// A listening socket on 127.0.0.1:port (0: a free one), or -1.
- (int)listenOn:(uint16_t)port {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in sa = {0};
    sa.sin_len = sizeof sa; sa.sin_family = AF_INET; sa.sin_port = htons(port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0 || listen(fd, 64) != 0) {
        SFLog(@"%@: cannot listen on 127.0.0.1:%u (%s)", _name, port, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

- (BOOL)startPreferringPort:(uint16_t)preferred {
    if (_accept) return YES;
    int fd = [self listenOn:preferred];
    if (fd < 0 && preferred) fd = [self listenOn:0];
    if (fd < 0) return NO;
    struct sockaddr_in sa = {0};
    socklen_t len = sizeof sa;
    getsockname(fd, (struct sockaddr *)&sa, &len);
    _port = ntohs(sa.sin_port);
    _accept = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    __weak SFLocalHTTP *ws = self;
    dispatch_source_set_event_handler(_accept, ^{
        int c = accept(fd, NULL, NULL);
        if (c < 0) return;
        SFLocalHTTP *s = ws;
        if (!s) { close(c); return; }
        [s serve:c];
    });
    dispatch_source_set_cancel_handler(_accept, ^{ close(fd); });
    dispatch_resume(_accept);
    return YES;
}

- (void)stop {
    if (_accept) dispatch_source_cancel(_accept);
    _accept = nil;
    _port = 0;
}

- (void)dealloc { [self stop]; }

// Reads one request on the connection's own queue, then hands it to the handler.
- (void)serve:(int)fd {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    struct timeval tv = {kReadTimeoutS, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    dispatch_queue_t io = dispatch_queue_create("sofa.http.conn", DISPATCH_QUEUE_SERIAL);
    dispatch_async(io, ^{
        NSInteger refusal = 0;
        SFHTTPRequest *r = [self readRequest:fd refusal:&refusal];
        if (!r) {
            if (refusal) {
                NSString *h = [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", (long)refusal, reason(refusal)];
                NSData *d = [h dataUsingEncoding:NSISOLatin1StringEncoding];
                writeAll(fd, d.bytes, d.length);
            }
            close(fd);
            return;
        }
        struct timeval none = {0, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, sizeof none);
        SFHTTPExchange *x = [[SFHTTPExchange alloc] initWithFD:fd request:r queue:self->_queue io:io];
        [x watch];
        SFHTTPHandler h = self->_handler;
        dispatch_async(self->_queue, ^{
            NSString *budget=[r header:@"x-sofa-read-budget"];
            if (budget && ![SFHTTPBudget remaining:budget]) { [x respond:503 type:nil body:nil]; return; }
            h(x);
        });
    });
}

// nil: nothing usable (refusal = the status to answer, 0 = just drop the connection)
- (SFHTTPRequest *)readRequest:(int)fd refusal:(NSInteger *)refusal {
    NSMutableData *buf = [NSMutableData new];
    uint8_t chunk[16384];
    NSRange end = {NSNotFound, 0};
    NSData *sep = [NSData dataWithBytes:"\r\n\r\n" length:4];
    while (end.location == NSNotFound) {
        if (buf.length > kMaxHead) { *refusal = 400; return nil; }
        ssize_t n = recv(fd, chunk, sizeof chunk, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return nil;
        [buf appendBytes:chunk length:(NSUInteger)n];
        end = [buf rangeOfData:sep options:0 range:NSMakeRange(0, buf.length)];
    }
    SFHTTPRequest *r = [SFHTTPRequest parseHead:[buf subdataWithRange:NSMakeRange(0, end.location)]];
    if (!r) { *refusal = 400; return nil; }
    NSUInteger want = (NSUInteger)MAX(0, [[r header:@"content-length"] longLongValue]);
    if (want > _maxBody) { *refusal = 413; return nil; }
    NSMutableData *body = [[buf subdataWithRange:NSMakeRange(NSMaxRange(end), buf.length - NSMaxRange(end))] mutableCopy];
    while (body.length < want) {
        ssize_t n = recv(fd, chunk, MIN(sizeof chunk, want - body.length), 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return nil;
        [body appendBytes:chunk length:(NSUInteger)n];
    }
    if (body.length > want) [body setLength:want];
    r.body = body;
    return r;
}
@end

BOOL SFHTTPParseRange(NSString *h, long long total, long long *start, long long *end, BOOL *partial) {
    *start = 0; *end = total; *partial = NO;
    h = [h stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (![h hasPrefix:@"bytes="] || [h rangeOfString:@","].location != NSNotFound) return YES;
    NSArray *p = [[h substringFromIndex:6] componentsSeparatedByString:@"-"];
    if (p.count != 2) return YES;
    NSString *a = p[0], *b = p[1];
    if (!a.length && !b.length) return YES;
    if (!a.length) {   // suffix: the last N bytes
        long long n = b.longLongValue;
        if (n <= 0) return NO;
        *start = MAX(0, total - n);
    } else {
        *start = a.longLongValue;
        if (b.length) *end = MIN(total, b.longLongValue + 1);
    }
    *partial = YES;
    return *start < total && *end > *start;
}
