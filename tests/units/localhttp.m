// sources: src/Core/SFLocalHTTP.m src/Apps/YouTube/SFYTChannel.m
// flags: -Isrc/Apps/YouTube -framework Security
// SFLocalHTTP: request parsing (path, query, headers, body), 413 above the body limit, streamed
// answers, a reader that goes away (onClose, failed writes). SFYTChannel: the engine extension's
// long poll and post (token, command out, answer in, events), call timeouts, failAll.
#import "SFLocalHTTP.h"
#import "SFYTChannel.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

BOOL SFDevMode = NO;   // main.m's, for SFCore.m
// SFModel's, without linking the model
NSError *SFError(NSString *msg) { return [NSError errorWithDomain:@"Sofa" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}]; }

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
    CHECK([s start] && s.port > 0, "server starts on a free port");
    uint16_t port = s.port;

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

static void testChannel(void) {
    dispatch_queue_t q = dispatch_queue_create("test.channel", DISPATCH_QUEUE_SERIAL);
    SFYTChannel *ch = [[SFYTChannel alloc] initWithQueue:q];
    NSMutableArray *events = [NSMutableArray new];
    ch.onEvent = ^(NSDictionary *e) { @synchronized (events) { [events addObject:e]; } };
    SFLocalHTTP *s = [[SFLocalHTTP alloc] initWithName:@"test" queue:q maxBody:1 << 20 handler:^(SFHTTPExchange *x) {
        if (![ch handle:x]) [x respond:404 type:nil body:nil];
    }];
    [s start];
    uint16_t port = s.port;
    CHECK(ch.token.length == 32, "token: 16 random bytes");
    CHECK([roundTrip(port, @"GET /engine/poll?token=wrong HTTP/1.1\r\n\r\n", nil) hasPrefix:@"HTTP/1.1 403 "], "wrong token: 403");
    CHECK([roundTrip(port, @"GET /other HTTP/1.1\r\n\r\n", nil) hasPrefix:@"HTTP/1.1 404 "], "other paths are not the channel's");

    __block id value = nil; __block NSError *err = nil; __block BOOL done = NO;
    [ch call:@"open" args:@[@{@"v": @"x"}] timeout:5 done:^(id v, NSError *e) { value = v; err = e; done = YES; }];
    NSString *poll = [NSString stringWithFormat:@"GET /engine/poll?token=%@ HTTP/1.1\r\n\r\n", ch.token];
    NSArray *cmds = [NSJSONSerialization JSONObjectWithData:[bodyOf(roundTrip(port, poll, nil)) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    CHECK(cmds.count == 1 && [cmds[0][@"method"] isEqual:@"open"] && [cmds[0][@"args"] isEqual:(@[@{@"v": @"x"}])], "poll fetches the queued command");
    NSData *up = [NSJSONSerialization dataWithJSONObject:@{@"answers": @[@{@"id": cmds[0][@"id"], @"value": @{@"ok": @YES}}],
                                                           @"events": @[@"{\"type\":\"log\",\"line\":\"hi\"}"]} options:0 error:nil];
    NSString *post = [NSString stringWithFormat:@"POST /engine/post?token=%@ HTTP/1.1\r\nContent-Length: %lu\r\n\r\n", ch.token, (unsigned long)up.length];
    CHECK([roundTrip(port, post, up) hasPrefix:@"HTTP/1.1 204 "], "post: 204");
    CHECK(waitFor(^{ return done; }, 3) && !err && [value isEqual:@{@"ok": @YES}], "the answer completes the call");
    CHECK(waitFor(^{ @synchronized (events) { return (BOOL)(events.count == 1 && [events[0][@"line"] isEqual:@"hi"]); } }, 3), "events decoded");

    // a held poll is answered as soon as a command arrives
    __block NSString *held = nil;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ held = roundTrip(port, poll, nil); });
    usleep(300000);
    __block BOOL failed = NO;
    [ch call:@"status" args:@[@"sid"] timeout:0.5 done:^(id v, NSError *e) {
        failed = v == nil && [e.domain isEqualToString:SFYTChannelErrorDomain] && e.code == SFYTChannelTimedOut;
    }];
    CHECK(waitFor(^{ return (BOOL)(held != nil); }, 3) && [bodyOf(held) rangeOfString:@"\"status\""].location != NSNotFound, "held poll released by a call");
    CHECK(waitFor(^{ return failed; }, 3), "no answer: the call times out (SFYTChannelTimedOut)");

    __block BOOL dropped = NO;
    [ch call:@"read" args:@[] timeout:30 done:^(id v, NSError *e) { dropped = e != nil && ![e.domain isEqualToString:SFYTChannelErrorDomain]; }];
    [ch failAll:SFError(@"gone")];
    CHECK(waitFor(^{ return dropped; }, 3), "failAll fails pending calls (not as a timeout)");
    [s stop];
}

int main(void) {
    @autoreleasepool {
        testServer();
        testChannel();
    }
    if (fails) { fprintf(stderr, "%d failure(s)\n", fails); return 1; }
    printf("localhttp ok\n");
    return 0;
}
