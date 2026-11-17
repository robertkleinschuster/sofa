// sources: src/Core/SFFanLink.m
// SFFanLink: the fan daemon's state datagrams (interface v1) - strictly versioned, level clamped -
// and the round trip against a mock daemon: hint out, state back on the main thread, nothing
// blocks without a daemon.
#import "../../src/Core/SFFanLink.h"
#import "SFCore.h"
#include <sys/socket.h>
#include <sys/un.h>
BOOL SFDevMode = YES;   // SOFA_FAND_DIR is read in dev mode only

static int fails;
static void expect(BOOL ok, NSString *what) { if (!ok) { fails++; printf("FAIL %s\n", what.UTF8String); } }
static NSData *J(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }
static BOOL until(BOOL (^cond)(void), NSTimeInterval secs) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:secs];
    while (!cond() && [end timeIntervalSinceNow] > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return cond();
}

int main(void) {
    @autoreleasepool {
        NSDictionary *s = SFFanParseState(J(@"{\"v\":1,\"level\":2,\"cpu_c\":71.5,\"fans\":[{\"name\":\"ODD\",\"rpm\":1200}]}"));
        expect([s[@"level"] isEqual:@2] && [s[@"cpu_c"] isEqual:@71.5], @"a v1 state: level and temperatures");
        expect(SFFanParseState(J(@"{\"v\":2,\"level\":1}")) == nil, @"another version: ignored");
        expect(SFFanParseState(J(@"{\"v\":\"1\",\"level\":1}")) == nil, @"version as a string: ignored");
        expect(SFFanParseState(J(@"{\"v\":true,\"level\":1}")) == nil, @"version true (an NSNumber equal to 1): ignored");
        expect(SFFanParseState(J(@"{\"v\":1}")) == nil, @"no level: ignored");
        expect(SFFanParseState(J(@"{\"v\":1,\"level\":\"2\"}")) == nil, @"level as a string: ignored");
        expect(SFFanParseState(J(@"{\"v\":1,\"level\":true}")) == nil, @"level true: ignored");
        expect([SFFanParseState(J(@"{\"v\":1,\"level\":9}"))[@"level"] isEqual:@3], @"level clamped to 3");
        expect([SFFanParseState(J(@"{\"v\":1,\"level\":-1}"))[@"level"] isEqual:@0], @"level clamped to 0");
        expect(SFFanParseState(J(@"{\"v\":1,\"level\":2")) == nil, @"truncated JSON: nil");
        expect(SFFanParseState(J(@"not json")) == nil && SFFanParseState(nil) == nil, @"garbage, nothing: nil");
        expect(SFFanParseState(J(@"[1,2]")) == nil, @"not an object: nil");
        NSMutableString *big = [NSMutableString stringWithString:@"{\"v\":1,\"level\":1,\"pad\":\""];
        while (big.length < 5000) [big appendString:@"xxxxxxxxxx"];
        [big appendString:@"\"}"];
        expect(SFFanParseState(J(big)) == nil, @"larger than 4 KB: ignored");

        // no daemon: hints go nowhere and nothing waits
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"fand-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("SOFA_FAND_DIR", dir.fileSystemRepresentation, 1);
        __block NSMutableArray *states = [NSMutableArray new];
        SFFanStart(^(NSDictionary *st) { [states addObject:st]; });
        NSDate *t0 = [NSDate date];
        for (int i = 0; i < 200; i++) SFFanSendHint(@"idle", -1, 90);
        expect(-[t0 timeIntervalSinceNow] < 0.5, @"200 hints without a daemon return at once");

        // a mock daemon: receives the hint, answers its sender
        int d = socket(AF_UNIX, SOCK_DGRAM, 0);
        struct sockaddr_un a = {0}; a.sun_family = AF_UNIX;
        strcpy(a.sun_path, [dir stringByAppendingPathComponent:@"hint.sock"].fileSystemRepresentation);
        expect(bind(d, (struct sockaddr *)&a, (socklen_t)SUN_LEN(&a)) == 0, @"mock daemon bound");
        struct timeval tv = {2, 0}; setsockopt(d, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        until(^BOOL { return NO; }, 0.3);   // a hint of the burst still queued may reach the mock now
        SFFanSendHint(@"playback", 0.5f, 90);
        char buf[600]; struct sockaddr_un from; socklen_t fl = sizeof from;
        ssize_t n = 0; NSDictionary *h = nil;
        for (int i = 0; i < 4 && ![h[@"ctx"] isEqual:@"playback"]; i++) {   // skip such a leftover idle
            fl = sizeof from;
            n = recvfrom(d, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
            h = n > 0 ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buf length:(NSUInteger)n] options:0 error:nil] : nil;
            if (n <= 0) break;
        }
        expect([h[@"v"] isEqual:@1] && [h[@"ctx"] isEqual:@"playback"] && [h[@"vol"] doubleValue] == 0.5 && [h[@"ttl"] isEqual:@90], @"the hint as agreed");
        expect(fl > 0 && from.sun_path[0], @"the hint comes from a bound address (the daemon can answer)");
        const char *reply = "{\"v\":1,\"level\":2,\"cpu_c\":80}";
        sendto(d, reply, strlen(reply), 0, (struct sockaddr *)&from, fl);
        const char *bad = "{\"v\":7,\"level\":3}";
        sendto(d, bad, strlen(bad), 0, (struct sockaddr *)&from, fl);
        expect(until(^BOOL { return states.count >= 1; }, 2), @"the answer arrives on the main thread");
        until(^BOOL { return NO; }, 0.2);
        expect(states.count == 1 && [states[0][@"level"] isEqual:@2], @"only the valid state is taken");
        close(d);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    if (!fails) printf("fanlink ok\n");
    return fails ? 1 : 0;
}
