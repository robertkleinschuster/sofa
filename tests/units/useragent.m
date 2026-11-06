// sources: src/Core/SFUserAgent.m
// SFUserAgent: the native user agent is exactly what NSURLSession sends; per-domain overrides.
#import "SFCore.h"
#import "../../src/Core/SFUserAgent.h"
#include <sys/socket.h>
#include <netinet/in.h>
BOOL SFDevMode = NO;

static int fails;
static void expect(BOOL ok, NSString *what) { if (!ok) { fails++; printf("FAIL %s\n", what.UTF8String); } }

// the User-Agent line of one request NSURLSession sends to a local socket
static NSString *sentByURLSession(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t al = sizeof a;
    if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 1) || getsockname(s, (struct sockaddr *)&a, &al)) return nil;
    NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/", ntohs(a.sin_port)]];
    NSURLSession *ses = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    [[ses dataTaskWithURL:u] resume];
    struct timeval tv = {5, 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    int c = accept(s, NULL, NULL);
    if (c < 0) return nil;
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    char buf[4096]; ssize_t n = recv(c, buf, sizeof buf - 1, 0);
    close(c); close(s); [ses invalidateAndCancel];
    if (n <= 0) return nil;
    buf[n] = 0;
    for (NSString *l in [@(buf) componentsSeparatedByString:@"\r\n"])
        if ([l.lowercaseString hasPrefix:@"user-agent: "]) return [l substringFromIndex:12];
    return nil;
}

int main(void) {
    @autoreleasepool {
        NSString *sent = sentByURLSession();
        expect([sent isEqualToString:SFNativeUserAgent()], [NSString stringWithFormat:@"native UA = NSURLSession's: sent '%@', built '%@'", sent, SFNativeUserAgent()]);
        expect([SFUserAgentForHost(@"api.zdf.de") isEqualToString:SFNativeUserAgent()], @"no override: native");
        SFSetUserAgentForDomains(@"Chrome-ish", @[@"youtube.com", @"ytimg.com"]);
        expect([SFUserAgentForHost(@"i.ytimg.com") isEqualToString:@"Chrome-ish"], @"subdomain takes the domain's");
        expect([SFUserAgentForHost(@"WWW.YouTube.com") isEqualToString:@"Chrome-ish"], @"case-insensitive");
        expect([SFUserAgentForHost(@"notyoutube.com") isEqualToString:SFNativeUserAgent()], @"suffix only at a dot");
        SFSetUserAgentForDomains(nil, @[@"ytimg.com"]);
        expect([SFUserAgentForHost(@"i.ytimg.com") isEqualToString:SFNativeUserAgent()], @"removed");
    }
    if (!fails) printf("ok\n");
    return fails ? 1 : 0;
}
