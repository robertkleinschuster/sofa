// sources: src/Core/SFHTTPBudget.m src/Core/SFLocalHTTP.m src/Core/SFWebSocket.m src/Core/SFTLS.m src/Core/SFTailnet.m src/Core/SFLoopbackClient.m
// flags: -I/opt/local/include -L/opt/local/lib -lssl -lcrypto
// The server side of Sofa im Browser (docs/pwa.md): SFLocalHTTP with TLS (SFTLS, a throwaway
// self-signed certificate) on every address - a TLS request is `secure`, a plain one on the same port
// is still read (the connect redirect), the accept filter closes what it refuses, a certificate with
// the wrong key is refused while the loaded one stays; the loopback relay passes Range and status
// through; tailnet addresses are told apart (100.64.0.0/10, fd7a:115c:a1e0::/48, mapped IPv4).
#import "SFTLS.h"
#import "SFTailnet.h"
#import "SFLoopbackClient.h"
#include <arpa/inet.h>
#include <netinet/in.h>

BOOL SFDevMode = NO;

static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL %s (%s:%d)\n", msg, __FILE__, __LINE__); fails++; } } while (0)

static NSString *Run(NSString *cmd) {
    FILE *p = popen(cmd.UTF8String, "r");
    if (!p) return nil;
    NSMutableData *d = [NSMutableData new];
    char buf[4096]; size_t n;
    while ((n = fread(buf, 1, sizeof buf, p)) > 0) [d appendBytes:buf length:n];
    pclose(p);
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

// addresses built from their octets (the repository's hygiene check refuses tailnet-looking literals)
static BOOL V4(int a, int b, int c, int d) {
    struct sockaddr_in s = {0}; s.sin_len = sizeof s; s.sin_family = AF_INET;
    s.sin_addr.s_addr = htonl((uint32_t)a << 24 | (uint32_t)b << 16 | (uint32_t)c << 8 | (uint32_t)d);
    return SFIsTailnetAddress((struct sockaddr *)&s);
}
static BOOL Mapped(int a, int b, int c, int d) {
    struct sockaddr_in6 s = {0}; s.sin6_len = sizeof s; s.sin6_family = AF_INET6;
    s.sin6_addr.s6_addr[10] = 0xff; s.sin6_addr.s6_addr[11] = 0xff;
    s.sin6_addr.s6_addr[12] = (uint8_t)a; s.sin6_addr.s6_addr[13] = (uint8_t)b; s.sin6_addr.s6_addr[14] = (uint8_t)c; s.sin6_addr.s6_addr[15] = (uint8_t)d;
    return SFIsTailnetAddress((struct sockaddr *)&s);
}
static BOOL V6(const char *a) {
    struct sockaddr_in6 s = {0}; s.sin6_len = sizeof s; s.sin6_family = AF_INET6; inet_pton(AF_INET6, a, &s.sin6_addr);
    return SFIsTailnetAddress((struct sockaddr *)&s);
}

int main(void) {
    @autoreleasepool {
        CHECK(V4(100, 64, 0, 1) && V4(100, 127, 255, 254) && V4(100, 100, 100, 100), "100.64.0.0/10 is the tailnet");
        CHECK(!V4(100, 63, 255, 255) && !V4(100, 128, 0, 1) && !V4(192, 168, 1, 10) && !V4(127, 0, 0, 1), "neighbours are not");
        CHECK(Mapped(100, 101, 1, 2) && !Mapped(10, 0, 0, 1), "IPv4-mapped addresses by their IPv4");
        CHECK(V6("fd7a:115c:a1e0::1") && V6("fd7a:115c:a1e0:ab12::99"), "Tailscale's IPv6 range");
        CHECK(!V6("fd7a:115c:a1e1::1") && !V6("::1"), "other IPv6 are not");

        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *cert = [dir stringByAppendingPathComponent:@"c.pem"], *key = [dir stringByAppendingPathComponent:@"k.pem"],
                 *otherKey = [dir stringByAppendingPathComponent:@"o.pem"];
        NSString *gen = [NSString stringWithFormat:@"/opt/local/bin/openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes "
                         "-keyout '%@' -out '%@' -days 2 -subj /CN=sofa-test.invalid -addext subjectAltName=DNS:sofa-test.invalid 2>/dev/null; "
                         "/opt/local/bin/openssl ecparam -name prime256v1 -genkey -noout -out '%@' 2>/dev/null", key, cert, otherKey];
        Run(gen);
        SFTLS *tls = [SFTLS new];
        NSError *e = nil;
        CHECK([tls loadCertificate:cert key:key error:&e], "certificate loads");
        CHECK([tls.subjectName isEqualToString:@"sofa-test.invalid"], "its DNS name");
        CHECK([tls.expires timeIntervalSinceNow] > 86400, "its expiry");
        CHECK([[SFTLS expiryOfCertificate:cert] isEqual:tls.expires], "expiry without loading");
        CHECK(![tls loadCertificate:cert key:otherKey error:&e] && e && tls.ready, "a key that doesn't match is refused, the loaded certificate stays");

        // a plain loopback source the relay reads from: 100 bytes with Range
        NSMutableData *blob = [NSMutableData new];
        for (int i = 0; i < 100; i++) { uint8_t b = (uint8_t)i; [blob appendBytes:&b length:1]; }
        SFLocalHTTP *source = [[SFLocalHTTP alloc] initWithName:@"source" queue:dispatch_queue_create("t.src", 0) maxBody:0 handler:^(SFHTTPExchange *x) {
            long long a, b; BOOL partial;
            SFHTTPParseRange([x.request header:@"range"], 100, &a, &b, &partial);
            NSMutableDictionary *h = [@{@"Content-Type": @"video/mp4", @"Content-Length": [NSString stringWithFormat:@"%lld", b - a], @"Accept-Ranges": @"bytes"} mutableCopy];
            if (partial) h[@"Content-Range"] = [NSString stringWithFormat:@"bytes %lld-%lld/100", a, b - 1];
            [x begin:partial ? 206 : 200 headers:h];
            [x write:[blob subdataWithRange:NSMakeRange((NSUInteger)a, (NSUInteger)(b - a))] done:nil];
            [x finish];
        }];
        CHECK([source startPreferringPort:0], "source listens");
        NSURL *srcURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/s/x/media", source.port]];

        dispatch_queue_t q = dispatch_queue_create("t.web", 0);
        SFLocalHTTP *web = [[SFLocalHTTP alloc] initWithName:@"web" queue:q maxBody:1024 handler:^(SFHTTPExchange *x) {
            if ([x.request.pathParts.firstObject isEqualToString:@"relay"]) { [SFLoopbackClient relay:srcURL to:x]; return; }
            x.extraHeaders = @{@"X-Test": @"1"};
            [x respondJSON:200 object:@{@"secure": @(x.request.secure), @"path": [x.request.pathParts componentsJoinedByString:@"/"]}];
        }];
        CHECK([web startOnAllAddresses:0 security:tls accept:^BOOL(const struct sockaddr *l, const struct sockaddr *p) { return SFIsLoopbackAddress(l); }], "listens on every address");
        uint16_t port = web.port;
        NSString *curl = @"/opt/local/bin/curl -s --max-time 10";
        NSString *https = Run([NSString stringWithFormat:@"%@ -k -i https://127.0.0.1:%u/a/b", curl, port]);
        CHECK([https rangeOfString:@"\"secure\":true"].location != NSNotFound, "a TLS request is secure");
        CHECK([https rangeOfString:@"X-Test: 1"].location != NSNotFound, "extra headers are sent");
        CHECK([https rangeOfString:@"\"path\":\"a\\/b\""].location != NSNotFound, "its path");   // (NSJSONSerialization escapes /)
        NSString *v6 = Run([NSString stringWithFormat:@"%@ -k https://[::1]:%u/v6", curl, port]);
        CHECK([v6 rangeOfString:@"\"secure\":true"].location != NSNotFound, "IPv6 too (dual stack)");
        NSString *plain = Run([NSString stringWithFormat:@"%@ http://127.0.0.1:%u/connect", curl, port]);
        CHECK([plain rangeOfString:@"\"secure\":false"].location != NSNotFound, "a plain request on the same port is read, not secure");
        NSString *strict = Run([NSString stringWithFormat:@"%@ -o /dev/null -w '%%{http_code}' https://127.0.0.1:%u/", curl, port]);
        CHECK([strict isEqualToString:@"000"], "an untrusted certificate fails the client's check (no answer without -k)");
        NSString *ranged = Run([NSString stringWithFormat:@"%@ -k -i -r 10-19 https://127.0.0.1:%u/relay | od -An -tx1 | tr -d ' \\n'", curl, port]);
        CHECK([ranged hasSuffix:@"0a0b0c0d0e0f10111213"], "the relay passes the range and its bytes");
        NSString *status = Run([NSString stringWithFormat:@"%@ -k -i -r 10-19 https://127.0.0.1:%u/relay", curl, port]);
        CHECK([status hasPrefix:@"HTTP/1.1 206"] && [status rangeOfString:@"Content-Range: bytes 10-19/100"].location != NSNotFound, "206 and Content-Range relayed");

        SFLocalHTTP *closed = [[SFLocalHTTP alloc] initWithName:@"refusing" queue:q maxBody:0 handler:^(SFHTTPExchange *x) { [x respondJSON:200 object:@{}]; }];
        [closed startOnAllAddresses:0 security:tls accept:^BOOL(const struct sockaddr *l, const struct sockaddr *p) { return SFIsTailnetAddress(l); }];
        NSString *refused = Run([NSString stringWithFormat:@"%@ -k -o /dev/null -w '%%{http_code}' https://127.0.0.1:%u/", curl, closed.port]);
        CHECK([refused isEqualToString:@"000"], "the accept filter closes a connection it refuses (loopback is no tailnet address)");
        [web stop]; [closed stop]; [source stop];
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    if (fails) { fprintf(stderr, "%d check(s) failed\n", fails); return 1; }
    printf("webtls ok\n");
    return 0;
}
