#import "SFNet.h"
#import "SFStore.h"
#import "SFModel.h"
#import "SFCurl.h"
#import "SFUserAgent.h"

#import <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>

NSString *const SFNetOnlineDidChangeNotification = @"SFNetOnlineDidChange";
NSString *const SFNetRegionDidChangeNotification = @"SFNetRegionDidChange";
static BOOL gOnline = YES;
static SCNetworkReachabilityRef gReach;

static void setOnline(BOOL on) {
    if (SFSimulatedOffline()) on = NO;
    if (on == gOnline) return;
    gOnline = on;
    SFLog(@"net: %@", on ? @"online" : @"OFFLINE");
    SFMain(^{ [[NSNotificationCenter defaultCenter] postNotificationName:SFNetOnlineDidChangeNotification object:nil]; });
}

static void reachCallback(SCNetworkReachabilityRef r, SCNetworkReachabilityFlags f, void *info) {
    setOnline((f & kSCNetworkReachabilityFlagsReachable) && !(f & kSCNetworkReachabilityFlagsConnectionRequired));
}

@interface SFTrustAll : NSObject <NSURLSessionDelegate>
@end
@implementation SFTrustAll
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)ch
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))done {
    if ([ch.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] && ch.protectionSpace.serverTrust)
        done(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:ch.protectionSpace.serverTrust]);
    else
        done(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

id<NSURLSessionDelegate> SFTrustAllSessionDelegate(void) {
    static SFTrustAll *d; static dispatch_once_t o;
    dispatch_once(&o, ^{ d = [SFTrustAll new]; });
    return d;
}

@implementation SFNet

+ (BOOL)isOnline { return gOnline && !SFSimulatedOffline(); }

+ (void)startMonitoring {
    if (gReach) return;
    if (SFSimulatedOffline()) { setOnline(NO); return; }
    // the default route ("is there a network at all") - no particular service, no DNS lookup
    struct sockaddr_in any = { .sin_len = sizeof(any), .sin_family = AF_INET };
    gReach = SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&any);
    if (!gReach) return;
    SCNetworkReachabilityFlags f;
    if (SCNetworkReachabilityGetFlags(gReach, &f)) reachCallback(gReach, f, NULL);
    SCNetworkReachabilitySetCallback(gReach, reachCallback, NULL);
    SCNetworkReachabilityScheduleWithRunLoop(gReach, CFRunLoopGetMain(), kCFRunLoopCommonModes);
}

+ (NSURLSession *)session {
    static NSURLSession *s; static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
        c.timeoutIntervalForRequest = 20;
        c.timeoutIntervalForResource = 60;
        c.HTTPMaximumConnectionsPerHost = 4;
        c.URLCache = nil;
        c.HTTPAdditionalHeaders = @{@"Accept-Language": @"de-AT,de;q=0.9"};   // User-Agent: per request (SFUserAgent)
        s = [NSURLSession sessionWithConfiguration:c delegate:SFTrustAllSessionDelegate() delegateQueue:nil];
    });
    return s;
}

+ (void)request:(NSMutableURLRequest *)req cacheKey:(NSString *)key cacheAge:(NSTimeInterval)age done:(SFJSONDone)done {
    void (^finish)(id, NSError *) = ^(id j, NSError *e) { SFMain(^{ done(j, e); }); };
    // never on the caller's thread; done comes on main. The cache is a disk read and a JSON parse
    // (from the main thread it stalled navigation 91 ms in pread), the send reads the user agent's
    // plists and makes the session task (130-210 ms of the main thread at launch; hitch monitor
    // 2026-11-07)
    SFBackground(^{
        id hit = key && age > 0 ? [[SFStore shared] cachedJSON:key maxAge:age] : nil;
        if (hit) finish(hit, nil); else [self send:req cacheKey:key cacheAge:age finish:finish];
    });
}

// The request itself; on failure an older cached answer (up to 30 days) rather than none.
+ (void)send:(NSMutableURLRequest *)req cacheKey:(NSString *)key cacheAge:(NSTimeInterval)age finish:(void (^)(id, NSError *))finish {
    [req setValue:SFUserAgentForHost(req.URL.host) forHTTPHeaderField:@"User-Agent"];
    NSDate *t0 = [NSDate date];
    void (^handle)(NSData *, NSInteger, NSError *) = ^(NSData *data, NSInteger code, NSError *err) {
        if (err || code >= 400 || !data.length) {
            SFLog(@"net: %@ %@ -> %ld %@", req.HTTPMethod, req.URL.host, (long)code, err.localizedDescription ?: @"");
            // on error, fall back to a stale cache if need be (works offline)
            id stale = key ? [[SFStore shared] cachedJSON:key maxAge:30 * 86400] : nil;
            finish(stale, stale ? nil : (err ?: SFError(code == 403 ? @"In deinem Land nicht verfügbar." : @"Server nicht erreichbar.")));
            return;
        }
        NSError *pe = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&pe];
        if (!json) { finish(nil, SFError(@"Ungültige Antwort vom Server.")); return; }
        if (key && age > 0) [[SFStore shared] cacheJSON:json forKey:key];
        SFLog(@"net: %@ %@%@ %.2fs", req.HTTPMethod, req.URL.host, req.URL.path.length > 60 ? [req.URL.path substringToIndex:60] : req.URL.path, -[t0 timeIntervalSinceNow]);
        finish(json, nil);
    };
    // TLS bridge: hosts that 10.9 SecureTransport can't handle -> libcurl
    if (SFSimulatedOffline()) { SFBackground(^{ handle(nil, 0, SFError(@"Keine Internetverbindung.")); }); return; }
    void (^viaCurl)(void) = ^{
        SFBackground(^{
            NSMutableDictionary *h = [req.allHTTPHeaderFields mutableCopy] ?: [NSMutableDictionary new];
            if (!h[@"Accept-Language"]) h[@"Accept-Language"] = @"de-AT,de;q=0.9";
            NSInteger st = 0; NSError *ce = nil;
            NSData *d = SFCurlFetch(req.URL.absoluteString, req.HTTPMethod, h, req.HTTPBody, &st, &ce);
            handle(d, st, ce);
        });
    };
    if (SFHostNeedsCurl(req.URL.host)) { viaCurl(); return; }
    [[[self session] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (SFIsTLSError(err)) { SFMarkHostNeedsCurl(req.URL.host); viaCurl(); return; }
        handle(data, [(NSHTTPURLResponse *)resp statusCode], err);
    }] resume];
}

+ (void)getJSON:(NSString *)url headers:(NSDictionary *)headers cacheAge:(NSTimeInterval)age done:(SFJSONDone)done {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) { SFMain(^{ done(nil, SFError(@"Ungültige Adresse.")); }); return; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    r.HTTPMethod = @"GET";
    [headers enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { [r setValue:v forHTTPHeaderField:k]; }];
    [self request:r cacheKey:[@"GET " stringByAppendingString:url] cacheAge:age done:done];
}

+ (void)postJSON:(NSString *)url body:(id)body headers:(NSDictionary *)headers cacheAge:(NSTimeInterval)age done:(SFJSONDone)done {
    [self postJSON:url body:body headers:headers cacheKey:nil cacheAge:age done:done];
}

+ (void)postJSON:(NSString *)url body:(id)body headers:(NSDictionary *)headers cacheKey:(NSString *)cacheKey cacheAge:(NSTimeInterval)age done:(SFJSONDone)done {
    NSURL *u = [NSURL URLWithString:url];
    NSData *b = body ? [NSJSONSerialization dataWithJSONObject:body options:0 error:nil] : nil;
    if (!u || (body && !b)) { SFMain(^{ done(nil, SFError(@"Ungültige Anfrage.")); }); return; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    r.HTTPMethod = @"POST";
    r.HTTPBody = b;
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [headers enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { [r setValue:v forHTTPHeaderField:k]; }];
    NSString *key = cacheKey ?: [NSString stringWithFormat:@"POST %@ %@", url, b ? [[NSString alloc] initWithData:b encoding:NSUTF8StringEncoding] : @""];
    [self request:r cacheKey:key cacheAge:age done:done];
}
static NSString *regionKey(NSString *region) { return [@"geo.region." stringByAppendingString:region]; }

+ (SFRegionState)stateOfRegion:(NSString *)region {
    if (!region.length) return SFRegionInside;   // not limited
    NSArray *v = [[[SFStore shared] setting:regionKey(region)] componentsSeparatedByString:@" "];   // "<0|1> <epoch>"
    if (v.count != 2) return SFRegionUnknown;
    BOOL inside = [v[0] isEqualToString:@"1"];
    // outside hides content -> asked again sooner (travel, VPN) than inside
    if ([NSDate date].timeIntervalSince1970 - [v[1] doubleValue] > (inside ? 86400 : 6 * 3600)) return SFRegionUnknown;
    return inside ? SFRegionInside : SFRegionOutside;
}

+ (void)checkRegion:(NSString *)url expect:(NSString *)expect region:(NSString *)region done:(void (^)(BOOL))done {
    [self probeRegion:url expect:expect done:^(BOOL ok, BOOL definite) {
        if (definite && region.length) [self noteRegion:region inside:ok];
        done(ok);
    }];
}

+ (void)noteRegion:(NSString *)region inside:(BOOL)inside {
    if (!region.length) return;
    SFMain(^{
        SFRegionState before = [self stateOfRegion:region];
        [[SFStore shared] setSetting:[NSString stringWithFormat:@"%d %.0f", inside, [NSDate date].timeIntervalSince1970] forKey:regionKey(region)];
        if (before == (inside ? SFRegionInside : SFRegionOutside)) return;
        SFLog(@"geo: device %@ %@", inside ? @"inside" : @"outside", region);
        [[NSNotificationCenter defaultCenter] postNotificationName:SFNetRegionDidChangeNotification object:nil];
    });
}

+ (void)checkRegion:(NSString *)url expect:(NSString *)expect done:(void (^)(BOOL))done {
    [self probeRegion:url expect:expect done:^(BOOL ok, BOOL definite) { done(ok); }];
}

// `definite`: the answer really says something about the device's location (2xx with the expected
// text = inside; 403/451 or a wrong text = outside). Network errors, 5xx, a refused HEAD … are not
// - the stream is still allowed then (don't block), but nothing is learned about the region.
+ (void)probeRegion:(NSString *)url expect:(NSString *)expect done:(void (^)(BOOL ok, BOOL definite))done {
    static NSMutableDictionary *cache;   // url -> @[@(allowed), date] (definite answers only)
    static dispatch_once_t o; dispatch_once(&o, ^{ cache = [NSMutableDictionary new]; });
    NSArray *hit;
    @synchronized (cache) { hit = cache[url]; }
    if (hit && [hit[1] timeIntervalSinceNow] > -3600) { done([hit[0] boolValue], YES); return; }
    NSURL *u = [NSURL URLWithString:url];
    if (!u) { done(YES, NO); return; }
    // without expected text: media URL -> HEAD only (don't download the whole file)
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    if (!expect) req.HTTPMethod = @"HEAD";
    [req setValue:SFUserAgentForHost(u.host) forHTTPHeaderField:@"User-Agent"];
    [[[self session] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSInteger code = [(NSHTTPURLResponse *)r statusCode];
        NSString *body = d ? [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
        BOOL inside = !e && code >= 200 && code < 300 && (!expect || [body isEqualToString:expect]);
        BOOL outside = !e && (code == 403 || code == 451 || (expect && code >= 200 && code < 300 && !inside));
        BOOL ok = !outside;   // undecided: don't block
        if (inside || outside) @synchronized (cache) { cache[url] = @[@(ok), [NSDate date]]; }
        SFLog(@"geo: %@ -> %@", u.path, inside ? @"allowed" : outside ? @"blocked" : [NSString stringWithFormat:@"undecided (%ld%@)", (long)code, e ? @", error" : @""]);
        SFMain(^{ done(ok, inside || outside); });
    }] resume];
}
+ (NSString *)escape:(NSString *)s {
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [s ?: @"" stringByAddingPercentEncodingWithAllowedCharacters:ok];
}
@end
