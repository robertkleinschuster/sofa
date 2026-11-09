// sources: src/Core/SFHTTPBudget.m src/Core/SFLocalHTTP.m src/Core/SFWebSocket.m
// SFLocalHTTP: request parsing (path, query, headers, body), 413 above the body limit, streamed
// answers, a reader that goes away (onClose, failed writes). The WebSocket upgrade and the engine
// channel on it: tests/units/websocket.m.
#import "SFLocalHTTP.h"
#import "SFHTTPBudget.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

BOOL SFDevMode = NO;   // main.m's, for SFCore.m

static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL %s (%s:%d)\n", msg, __FILE__, __LINE__); fails++; } } while (0)

static int connectTo(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa = {0};
    sa.sin_len = sizeof sa; sa.sin_family = AF_INET; sa.sin_port = htons(port); sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) { close(fd); return -1; }
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    return fd;
}

// One raw request; the whole answer (the server closes after it).
static NSString *roundTrip(uint16_t port, NSString *req, NSData *body) {
    int fd = connectTo(port);
    if (fd < 0) return nil;
    NSMutableData *out = [[req dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (body) [out appendData:body];
    write(fd, out.bytes, out.length);
    NSMutableData *in = [NSMutableData new];
    char buf[65536];
    ssize_t n;
    while ((n = read(fd, buf, sizeof buf)) > 0) [in appendBytes:buf length:(NSUInteger)n];
    close(fd);
    return [[NSString alloc] initWithData:in encoding:NSISOLatin1StringEncoding];
}

static NSString *bodyOf(NSString *resp) {
    NSRange r = [resp rangeOfString:@"\r\n\r\n"];
    return r.location == NSNotFound ? nil : [resp substringFromIndex:NSMaxRange(r)];
}

static BOOL waitFor(BOOL (^cond)(void), double secs) {
    for (int i = 0; i < secs * 100; i++) { if (cond()) return YES; usleep(10000); }
    return cond();
}

static void testServer(void) {
    dispatch_queue_t q = dispatch_queue_create("test.http", DISPATCH_QUEUE_SERIAL);
    __block BOOL closedSeen = NO, lateWriteFailed = NO;
    SFLocalHTTP *s = [[SFLocalHTTP alloc] initWithName:@"test" queue:q maxBody:1024 handler:^(SFHTTPExchange *x) {
        SFHTTPRequest *r = x.request;
        NSString *what = r.pathParts.firstObject;
        if ([what isEqualToString:@"echo"]) {
            [x respondJSON:200 object:@{@"method": r.method, @"parts": r.pathParts, @"query": r.query,
                                        @"range": [r header:@"RANGE"] ?: @"", @"body": [[NSString alloc] initWithData:r.body encoding:NSUTF8StringEncoding]}];
        } else if ([what isEqualToString:@"stream"]) {
            [x begin:200 headers:@{@"Content-Length": @"6", @"Content-Type": @"text/plain"}];
            [x write:[@"abc" dataUsingEncoding:NSUTF8StringEncoding] done:^(BOOL ok) {
                [x write:[@"def" dataUsingEncoding:NSUTF8StringEncoding] done:^(BOOL ok2) { [x finish]; }];
            }];
        } else if ([what isEqualToString:@"hold"]) {   // never answered: the reader goes away
            x.onClose = ^{
                closedSeen = YES;
                [x begin:200 headers:@{}];
                [x write:[@"late" dataUsingEncoding:NSUTF8StringEncoding] done:^(BOOL ok) { lateWriteFailed = !ok; }];
            };
        } else [x respond:404 type:nil body:nil];
    }];
    CHECK([s startPreferringPort:0] && s.port > 0, "server starts on a free port");
    uint16_t port = s.port;
    // the engine's channel keeps its port across starts (the extension's config stays the same)
    SFLocalHTTP *again = [[SFLocalHTTP alloc] initWithName:@"test2" queue:q maxBody:1 handler:^(SFHTTPExchange *x) { [x respond:404 type:nil body:nil]; }];
    CHECK([again startPreferringPort:port] && again.port && again.port != port, "a taken preferred port: a free one instead");
    [again stop];
    // a port that was in use and is free again (the previous Sofa's: its process ended)
    int held = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in hs = { .sin_len = sizeof hs, .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    socklen_t hl = sizeof hs;
    bind(held, (struct sockaddr *)&hs, sizeof hs); listen(held, 1); getsockname(held, (struct sockaddr *)&hs, &hl);
    uint16_t freed = ntohs(hs.sin_port);
    close(held);
    SFLocalHTTP *third = [[SFLocalHTTP alloc] initWithName:@"test3" queue:q maxBody:1 handler:^(SFHTTPExchange *x) { [x respond:404 type:nil body:nil]; }];
    CHECK([third startPreferringPort:freed] && third.port == freed, "a free preferred port is taken again");
    [third stop];

    NSString *resp = roundTrip(port, @"GET /echo/a%20b/c?x=1&y=h%C3%A4+p&flag HTTP/1.1\r\nHost: x\r\nRange: bytes=5-\r\n\r\n", nil);
    CHECK([resp hasPrefix:@"HTTP/1.1 200 OK\r\n"], "200");
    CHECK([resp rangeOfString:@"Connection: close"].location != NSNotFound, "Connection: close");
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[bodyOf(resp) dataUsingEncoding:NSISOLatin1StringEncoding] options:0 error:nil];
    CHECK([j[@"parts"] isEqual:(@[@"echo", @"a b", @"c"])], "decoded path parts");
    CHECK([j[@"query"] isEqual:(@{@"x": @"1", @"y": @"hä p", @"flag": @""})], "decoded query");
    CHECK([j[@"range"] isEqual:@"bytes=5-"], "headers case-insensitive");

    resp = roundTrip(port, @"POST /echo HTTP/1.1\r\nContent-Length: 11\r\n\r\n", [@"hello world" dataUsingEncoding:NSUTF8StringEncoding]);
    j = [NSJSONSerialization JSONObjectWithData:[bodyOf(resp) dataUsingEncoding:NSISOLatin1StringEncoding] options:0 error:nil];
    CHECK([j[@"body"] isEqual:@"hello world"] && [j[@"method"] isEqual:@"POST"], "POST body");

    resp = roundTrip(port, @"POST /echo HTTP/1.1\r\nContent-Length: 4096\r\n\r\n", nil);
    CHECK([resp hasPrefix:@"HTTP/1.1 413 "], "413 above maxBody");

    resp = roundTrip(port, @"HEAD /echo HTTP/1.1\r\n\r\n", nil);
    CHECK([resp hasPrefix:@"HTTP/1.1 200 "] && [bodyOf(resp) length] == 0, "HEAD: headers only");

    resp = roundTrip(port, @"GET /stream HTTP/1.1\r\n\r\n", nil);
    CHECK([bodyOf(resp) isEqual:@"abcdef"], "streamed pieces in order");

    NSString *budget=[SFHTTPBudget open:4];
    NSString *limited=[NSString stringWithFormat:@"GET /stream HTTP/1.1\r\nX-Sofa-Read-Budget: %@\r\n\r\n",budget];
    resp=roundTrip(port,limited,nil);
    CHECK([bodyOf(resp) isEqual:@"abc"], "shared byte budget ends a streamed response before exceeding its limit");
    CHECK([SFHTTPBudget remaining:budget]==0, "over-limit chunk exhausts the budget");
    resp=roundTrip(port,limited,nil);
    CHECK([resp hasPrefix:@"HTTP/1.1 503 "], "retry/new audio connection cannot bypass exhausted budget");
    [SFHTTPBudget close:budget];
    resp=roundTrip(port,limited,nil);
    CHECK([resp hasPrefix:@"HTTP/1.1 503 "], "revoked reader cannot restart requests");
    resp=roundTrip(port,@"GET /stream HTTP/1.1\r\n\r\n",nil);
    CHECK([bodyOf(resp) isEqual:@"abcdef"], "ordinary playback remains unlimited");

    resp = roundTrip(port, @"garbage\r\n\r\n", nil);
    CHECK([resp hasPrefix:@"HTTP/1.1 400 "], "malformed request: 400");

    int fd = connectTo(port);
    const char *hold = "GET /hold HTTP/1.1\r\n\r\n";
    write(fd, hold, strlen(hold));
    usleep(200000);
    close(fd);
    CHECK(waitFor(^{ return closedSeen; }, 3), "onClose when the reader goes away");
    CHECK(waitFor(^{ return lateWriteFailed; }, 3), "a write after the reader left reports NO");
    [s stop];
}

int main(void) {
    @autoreleasepool {
        testServer();
    }
    if (fails) { fprintf(stderr, "%d failure(s)\n", fails); return 1; }
    printf("localhttp ok\n");
    return 0;
}
