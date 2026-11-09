// sources: src/Core/SFCurl+Stream.m src/Core/SFCurl.m src/Core/SFHTTPBudget.m src/Core/SFLocalHTTP.m src/Core/SFWebSocket.m
// flags: -I/opt/local/include -L/opt/local/lib -lcurl
// SFHTTPBudget at the curl layer: an oversized body aborts (never truncated as success), the
// upstream budget bounds what is kept, exhaustion revokes the token, a closed token cancels a
// stalled fetch or stream at once; ordinary fetches (no token) are unchanged.
#import "SFCurl.h"
#import "SFHTTPBudget.h"
#import "SFLocalHTTP.h"
BOOL SFDevMode = NO;
NSString *SFNativeUserAgent(void) { return @"Sofa local budget test"; }
NSError *SFError(NSString *m) { return [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: m}]; }
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }

// closes `token` after half a second, from another queue (a cancelled reader)
static void CloseSoon(NSString *token) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ [SFHTTPBudget close:token]; });
}

int main(void) { @autoreleasepool {
    NSData *body = [NSMutableData dataWithLength:2 * 1024 * 1024];
    __block uint16_t port = 0;
    SFLocalHTTP *server = [[SFLocalHTTP alloc] initWithName:@"curl-budget-test" queue:dispatch_queue_create("curl-budget-test", DISPATCH_QUEUE_SERIAL)
                                                     maxBody:0 handler:^(SFHTTPExchange *x) {
        NSString *path = x.request.pathParts.firstObject;
        if ([path isEqual:@"redirect"]) {
            [x begin:302 headers:@{@"Content-Length": @"0", @"Location": [NSString stringWithFormat:@"http://127.0.0.1:%u/body", port]}];
            [x finish];
        } else if ([path isEqual:@"stall"]) {
            x.onClose = ^{ (void)x; };   // own the exchange until the cancelled reader closes it
            [x begin:200 headers:@{@"Content-Length": @"2097152"}];
        } else [x respond:200 type:@"application/octet-stream" body:body];
    }];
    expect([server startPreferringPort:0], "the local fixture server starts");
    port = server.port;
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%u/redirect", port], *stall = [NSString stringWithFormat:@"http://127.0.0.1:%u/stall", port];

    NSString *token = [SFHTTPBudget open:64 * 1024];
    __block NSUInteger accepted = 0;
    BOOL (^take)(NSUInteger) = ^BOOL(NSUInteger bytes) {
        BOOL ok = [SFHTTPBudget takeSource:bytes token:token];
        if (ok) accepted += bytes;
        return ok;
    };
    NSInteger status = 0;
    NSString *effective = nil;
    NSError *error = nil;
    NSData *limited = SFCurlFetchLimitedFinal(url, &status, &effective, &error, take);
    expect(limited == nil && error != nil, "an oversized body aborts, never returned truncated as success");
    expect(accepted > 0 && accepted <= 128 * 1024, "the upstream budget bounds the kept bytes across chunks");
    expect([effective hasSuffix:@"/body"], "the redirect target is kept (playlist-relative URLs)");
    expect([SFHTTPBudget remaining:token] == 0, "upstream exhaustion revokes further response work");
    [SFHTTPBudget close:token];
    accepted = 0;
    limited = SFCurlFetchLimitedFinal(url, &status, NULL, NULL, take);
    expect(!limited && accepted == 0, "a cancelled reader keeps no source bytes on a retry");

    NSString *stalled = [SFHTTPBudget open:1024];
    CloseSoon(stalled);
    NSTimeInterval began = [NSDate timeIntervalSinceReferenceDate];
    NSData *waiting = SFCurlFetchLimitedFinal(stall, &status, NULL, NULL, ^BOOL(NSUInteger bytes) { return [SFHTTPBudget takeSource:bytes token:stalled]; });
    expect(!waiting && [NSDate timeIntervalSinceReferenceDate] - began < 3, "a cancel interrupts an origin that sends no body");

    NSString *streamToken = [SFHTTPBudget open:1024];
    CloseSoon(streamToken);
    began = [NSDate timeIntervalSinceReferenceDate];
    __block BOOL delivered = NO;
    BOOL stopped = SFCurlStreamWhile(stall, 0, -1, 0,
        ^BOOL { return [SFHTTPBudget takeSource:0 token:streamToken]; },
        ^BOOL(NSInteger code, long long total, NSString *mime) { return YES; },
        ^BOOL(NSData *bytes) { delivered = YES; return YES; }, NULL);
    expect(stopped && !delivered && [NSDate timeIntervalSinceReferenceDate] - began < 3, "a stream's cancel is polled while the origin sends nothing");

    NSData *ordinary = SFCurlFetchFinal(url, &status, &effective, &error);
    expect(ordinary.length == body.length && status == 200, "an ordinary playback/download fetch is unchanged");
    expect([SFHTTPBudget takeSource:NSUIntegerMax token:nil], "ordinary source reads need no token");
    [server stop];
    return bad ? 1 : 0;
} }
