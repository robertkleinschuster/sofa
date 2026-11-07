#import "SFHostFetch.h"

// @[hosts, fetcher] pairs; locked by itself (registered at launch, read by loader threads)
static NSMutableArray *Routes(void) {
    static NSMutableArray *routes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ routes = [NSMutableArray new]; });
    return routes;
}

void SFRegisterHostFetcher(NSArray *hosts, SFHostFetcher fetcher) {
    NSMutableArray *routes = Routes();
    @synchronized (routes) { [routes addObject:@[[hosts copy], [fetcher copy]]]; }
}

static BOOL Matches(NSString *host, NSString *entry) {
    return [entry hasPrefix:@"."] ? [host hasSuffix:entry] : [host isEqualToString:entry];
}

SFHostFetcher SFHostFetcherFor(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (!host.length) return nil;
    NSMutableArray *routes = Routes();
    @synchronized (routes) {
        for (NSArray *r in routes)
            for (NSString *h in r[0]) if (Matches(host, h)) return r[1];
    }
    return nil;
}
