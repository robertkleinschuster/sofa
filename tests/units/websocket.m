// sources: src/Core/SFLocalHTTP.m src/Core/SFWebSocket.m src/Apps/YouTube/SFYTChannel.m
// flags: -Isrc/Apps/YouTube -framework Security
// SFWebSocket: the accept key (RFC 6455's example), server frames, the reader (masking, any split,
// fragments, control frames, protocol errors, the size limit). SFYTChannelDecodeBinary: the
// extension's binary container (the bytes tests/sofa-yt/unit-protocol.test.ts encodes). End to end
// over SFLocalHTTP: the upgrade, the engine channel (token, commands out, answers and events in as
// text and binary, timeouts, failAll), ping, a newer connection replacing the older.
#import "SFLocalHTTP.h"
#import "SFWebSocket.h"
#import "SFYTChannel.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

BOOL SFDevMode = NO;   // main.m's, for SFCore.m
// SFModel's, without linking the model
NSError *SFError(NSString *msg) { return [NSError errorWithDomain:@"Sofa" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}]; }

static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL %s (%s:%d)\n", msg, __FILE__, __LINE__); fails++; } } while (0)

static NSData *D(const char *s) { return [NSData dataWithBytes:s length:strlen(s)]; }

static BOOL waitFor(BOOL (^cond)(void), double secs) {
    for (int i = 0; i < secs * 100; i++) { if (cond()) return YES; usleep(10000); }
    return cond();
}

// A client frame: masked, FIN as given.
static NSData *clientFrame(uint8_t op, BOOL fin, NSData *payload) {
    NSMutableData *f = [NSMutableData new];
    uint8_t h[14];
    size_t hl = 2;
    NSUInteger n = payload.length;
    h[0] = (fin ? 0x80 : 0) | op;
    if (n < 126) h[1] = 0x80 | (uint8_t)n;
    else if (n <= 0xffff) { h[1] = 0x80 | 126; h[2] = (uint8_t)(n >> 8); h[3] = (uint8_t)n; hl = 4; }
    else { h[1] = 0x80 | 127; for (int i = 0; i < 8; i++) h[2 + i] = (uint8_t)((uint64_t)n >> (56 - 8 * i)); hl = 10; }
    uint8_t key[4] = {0x12, 0x34, 0x56, 0x78};
    memcpy(h + hl, key, 4);
    [f appendBytes:h length:hl + 4];
    NSMutableData *m = [payload mutableCopy];
    uint8_t *p = m.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) p[i] ^= key[i & 3];
    [f appendData:m];
    return f;
}

static void testCodec(void) {
    CHECK([SFWSAccept(@"dGhlIHNhbXBsZSBub25jZQ==") isEqual:@"s3pPLMBiTxaQ9kYGzzhZRbK+xOo="], "accept key: RFC 6455's example");
    NSData *f = SFWSFrame(SFWSText, D("Hello"));
    CHECK([f isEqual:[NSData dataWithBytes:"\x81\x05Hello" length:7]], "server text frame: FIN, unmasked");
    NSData *big = SFWSFrame(SFWSBinary, [NSMutableData dataWithLength:70000]);
    const uint8_t *b = big.bytes;
    CHECK(big.length == 70010 && b[0] == 0x82 && b[1] == 127 && b[7] == 0x01 && b[8] == 0x11 && b[9] == 0x70, "64-bit length");

    SFWSReader *r = [[SFWSReader alloc] initWithMaxMessage:1000];
    NSMutableArray *got = [NSMutableArray new];
    void (^collect)(SFWSOpcode, NSData *) = ^(SFWSOpcode op, NSData *p) { [got addObject:@[@(op), p]]; };
    NSMutableData *stream = [NSMutableData new];
    [stream appendData:clientFrame(SFWSText, NO, D("Hel"))];
    [stream appendData:clientFrame(SFWSPing, YES, D("p"))];        // control frame between fragments
    [stream appendData:clientFrame(SFWSContinuation, YES, D("lo"))];
    [stream appendData:clientFrame(SFWSBinary, YES, [NSMutableData dataWithLength:300])];   // 16-bit length
    BOOL ok = YES;
    for (NSUInteger i = 0; i < stream.length; i++)                   // byte by byte: any split
        ok = ok && [r feed:[stream subdataWithRange:NSMakeRange(i, 1)] message:collect];
    CHECK(ok && got.count == 3, "three messages from one byte at a time");
    CHECK(got.count == 3 && [got[0][0] isEqual:@(SFWSPing)] && [got[1][0] isEqual:@(SFWSText)] && [got[1][1] isEqual:D("Hello")],
          "control frame as it comes, fragments joined and unmasked");
    CHECK(got.count == 3 && [got[2][0] isEqual:@(SFWSBinary)] && [got[2][1] length] == 300, "binary message");

    NSData *unmasked = [NSData dataWithBytes:"\x81\x02hi" length:4];
    CHECK(![[[SFWSReader alloc] initWithMaxMessage:1000] feed:unmasked message:collect], "an unmasked client frame is a protocol error");
    CHECK(![[[SFWSReader alloc] initWithMaxMessage:1000] feed:clientFrame(SFWSContinuation, YES, D("x")) message:collect], "a stray continuation");
    CHECK(![[[SFWSReader alloc] initWithMaxMessage:1000] feed:clientFrame(SFWSPing, NO, D("x")) message:collect], "a fragmented control frame");
    CHECK(![[[SFWSReader alloc] initWithMaxMessage:10] feed:clientFrame(SFWSText, YES, D("12345678901")) message:collect], "above the limit");
    SFWSReader *frag = [[SFWSReader alloc] initWithMaxMessage:10];
    CHECK([frag feed:clientFrame(SFWSText, NO, D("123456")) message:collect] && ![frag feed:clientFrame(SFWSContinuation, YES, D("78901")) message:collect],
          "the limit counts the whole message, not one fragment");
}

static void testDecodeBinary(void) {
    // the bytes unit-protocol.test.ts expects encodeUpload to make
    const char *json = "{\"answers\":[{\"id\":3,\"value\":{\"ok\":true,\"value\":{\"mimeType\":\"image/jpeg\",\"data\":{\"$blob\":0}}}}],\"events\":[{\"type\":\"lounge\",\"id\":\"p\",\"data\":{\"$blob\":1}}]}";
    NSMutableData *m = [NSMutableData new];
    uint8_t len[4] = {0, 0, 0, (uint8_t)strlen(json)};
    [m appendBytes:len length:4]; [m appendBytes:json length:strlen(json)];
    [m appendBytes:"\0\0\0\x03\x01\x02\x03" length:7];
    [m appendBytes:"\0\0\0\x01\xff" length:5];
    NSDictionary *up = SFYTChannelDecodeBinary(m);
    CHECK([up[@"answers"][0][@"value"][@"value"][@"data"] isEqual:[NSData dataWithBytes:"\x01\x02\x03" length:3]], "a blob in an answer");
    CHECK([up[@"events"][0][@"data"] isEqual:[NSData dataWithBytes:"\xff" length:1]], "a blob in an event");
    CHECK([up[@"answers"][0][@"value"][@"value"][@"mimeType"] isEqual:@"image/jpeg"], "the rest of the JSON as it was");
    CHECK(SFYTChannelDecodeBinary([m subdataWithRange:NSMakeRange(0, m.length - 1)]) == nil, "a truncated block: nil");
    CHECK(SFYTChannelDecodeBinary([NSData dataWithBytes:"\0\0\0\x09{}" length:6]) == nil, "a length past the end: nil");
}

#pragma mark End to end

static int connectTo(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa = {0};
    sa.sin_len = sizeof sa; sa.sin_family = AF_INET; sa.sin_port = htons(port); sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) { close(fd); return -1; }
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    return fd;
}

static void sendAll(int fd, NSData *d) { write(fd, d.bytes, d.length); }

// The answer head of an upgrade request (up to the blank line); fd stays open.
static NSString *upgrade(int fd, NSString *path) {
    NSString *req = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n", path];
    sendAll(fd, [req dataUsingEncoding:NSUTF8StringEncoding]);
    NSMutableData *in = [NSMutableData new];
    char c;
    while (read(fd, &c, 1) == 1) {
        [in appendBytes:&c length:1];
        if (in.length >= 4 && memcmp((const char *)in.bytes + in.length - 4, "\r\n\r\n", 4) == 0) break;
    }
    return [[NSString alloc] initWithData:in encoding:NSISOLatin1StringEncoding];
}

// One server frame: its opcode and payload (op -1: the connection ended).
static int readFrame(int fd, NSData **payload) {
    uint8_t h[10];
    if (read(fd, h, 2) != 2) return -1;
    uint64_t n = h[1] & 0x7f;
    if (n == 126) { if (read(fd, h + 2, 2) != 2) return -1; n = ((uint64_t)h[2] << 8) | h[3]; }
    else if (n == 127) { if (read(fd, h + 2, 8) != 8) return -1; n = 0; for (int i = 0; i < 8; i++) n = (n << 8) | h[2 + i]; }
    NSMutableData *p = [NSMutableData dataWithLength:(NSUInteger)n];
    for (uint64_t got = 0; got < n;) {
        ssize_t r = read(fd, (uint8_t *)p.mutableBytes + got, (size_t)(n - got));
        if (r <= 0) return -1;
        got += (uint64_t)r;
    }
    if (payload) *payload = p;
    return h[0] & 0x0f;
}

static NSData *json(id o) { return [NSJSONSerialization dataWithJSONObject:o options:0 error:nil]; }

static void testChannel(void) {
    dispatch_queue_t q = dispatch_queue_create("test.channel", DISPATCH_QUEUE_SERIAL);
    SFYTChannel *ch = [[SFYTChannel alloc] initWithQueue:q token:SFYTChannelNewToken() maxMessage:1 << 20];
    NSMutableArray *events = [NSMutableArray new];
    ch.onEvent = ^(NSDictionary *e) { @synchronized (events) { [events addObject:e]; } };
    SFLocalHTTP *s = [[SFLocalHTTP alloc] initWithName:@"test" queue:q maxBody:1024 handler:^(SFHTTPExchange *x) {
        if (![ch handle:x]) [x respond:404 type:nil body:nil];
    }];
    [s startPreferringPort:0];
    uint16_t port = s.port;
    CHECK(ch.token.length == 32, "token: 16 random bytes");
    NSString *path = [NSString stringWithFormat:@"/engine/ws?token=%@", ch.token];

    int bad = connectTo(port);
    CHECK([upgrade(bad, @"/engine/ws?token=wrong") hasPrefix:@"HTTP/1.1 403 "], "wrong token: 403");
    close(bad);
    bad = connectTo(port);
    sendAll(bad, D("GET /engine/ws?token=x HTTP/1.1\r\n\r\n"));
    close(bad);
    int plain = connectTo(port);
    NSString *req = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\n\r\n", path];
    sendAll(plain, [req dataUsingEncoding:NSUTF8StringEncoding]);
    char buf[64] = {0};
    read(plain, buf, sizeof buf - 1);
    CHECK(strncmp(buf, "HTTP/1.1 400 ", 13) == 0, "the channel's path without an upgrade: 400");
    close(plain);

    // a command made before there is a connection waits for it
    __block id value = nil; __block NSError *err = nil; __block BOOL done = NO;
    [ch call:@"open" args:@[@{@"v": @"x"}] timeout:5 done:^(id v, NSError *e) { value = v; err = e; done = YES; }];
    int fd = connectTo(port);
    NSString *head = upgrade(fd, path);
    CHECK([head hasPrefix:@"HTTP/1.1 101 "] && [head rangeOfString:@"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"].location != NSNotFound, "101 with the accept key");
    NSData *p = nil;
    CHECK(readFrame(fd, &p) == SFWSText, "commands come as text");
    NSArray *cmds = [NSJSONSerialization JSONObjectWithData:p options:0 error:nil];
    CHECK(cmds.count == 1 && [cmds[0][@"method"] isEqual:@"open"] && [cmds[0][@"args"] isEqual:(@[@{@"v": @"x"}])], "the queued command on connect");
    // answered as text, with an event as an object and one as a JSON string (both accepted)
    sendAll(fd, clientFrame(SFWSText, YES, json(@{@"answers": @[@{@"id": cmds[0][@"id"], @"value": @{@"ok": @YES}}],
                                                 @"events": @[@{@"type": @"log", @"line": @"hi"}, @"{\"type\":\"log\",\"line\":\"ho\"}"]})));
    CHECK(waitFor(^{ return done; }, 3) && !err && [value isEqual:@{@"ok": @YES}], "the answer completes the call");
    CHECK(waitFor(^{ @synchronized (events) { return (BOOL)(events.count == 2 && [events[1][@"line"] isEqual:@"ho"]); } }, 3), "events as objects and strings");

    // a call while connected goes out at once; answered in the binary container
    __block NSData *bytes = nil;
    [ch call:@"image" args:@[@"u"] timeout:5 done:^(id v, NSError *e) { bytes = v[@"data"]; }];
    CHECK(readFrame(fd, &p) == SFWSText, "a call while connected is sent at once");
    cmds = [NSJSONSerialization JSONObjectWithData:p options:0 error:nil];
    NSData *j = json(@{@"answers": @[@{@"id": cmds[0][@"id"], @"value": @{@"data": @{@"$blob": @0}}}], @"events": @[]});
    NSMutableData *m = [NSMutableData new];
    uint32_t be = htonl((uint32_t)j.length); [m appendBytes:&be length:4]; [m appendData:j];
    be = htonl(3); [m appendBytes:&be length:4]; [m appendBytes:"abc" length:3];
    sendAll(fd, clientFrame(SFWSBinary, YES, m));
    CHECK(waitFor(^{ return (BOOL)(bytes != nil); }, 3) && [bytes isEqual:D("abc")], "binary answer: the blob as bytes");

    sendAll(fd, clientFrame(SFWSPing, YES, D("k")));
    CHECK(readFrame(fd, &p) == SFWSPong && [p isEqual:D("k")], "ping: pong with its payload");

    __block BOOL failed = NO;
    [ch call:@"status" args:@[@"sid"] timeout:0.5 done:^(id v, NSError *e) {
        failed = v == nil && [e.domain isEqualToString:SFYTChannelErrorDomain] && e.code == SFYTChannelTimedOut;
    }];
    readFrame(fd, NULL);
    CHECK(waitFor(^{ return failed; }, 3), "no answer: the call times out (SFYTChannelTimedOut)");

    // a newer connection replaces the older: the older is closed, commands go to the newer
    int fd2 = connectTo(port);
    CHECK([upgrade(fd2, path) hasPrefix:@"HTTP/1.1 101 "], "a second connection");
    CHECK(readFrame(fd, &p) == SFWSClose, "the older one is closed");
    [ch call:@"health" args:@[] timeout:5 done:^(id v, NSError *e) {}];
    CHECK(readFrame(fd2, &p) == SFWSText && [[[NSString alloc] initWithData:p encoding:NSUTF8StringEncoding] rangeOfString:@"health"].location != NSNotFound,
          "commands go to the newer");
    // a protocol error (unmasked frame) closes with 1002
    sendAll(fd2, [NSData dataWithBytes:"\x81\x02hi" length:4]);
    CHECK(readFrame(fd2, &p) == SFWSClose && p.length == 2 && ((const uint8_t *)p.bytes)[1] == 0xea, "protocol error: close 1002");
    close(fd); close(fd2);

    __block BOOL dropped = NO;
    [ch call:@"read" args:@[] timeout:30 done:^(id v, NSError *e) { dropped = e != nil && ![e.domain isEqualToString:SFYTChannelErrorDomain]; }];
    [ch failAll:SFError(@"gone")];
    CHECK(waitFor(^{ return dropped; }, 3), "failAll fails pending calls (not as a timeout)");
    [s stop];
}

int main(void) {
    @autoreleasepool {
        testCodec();
        testDecodeBinary();
        testChannel();
    }
    if (fails) { fprintf(stderr, "%d failure(s)\n", fails); return 1; }
    printf("websocket ok\n");
    return 0;
}
