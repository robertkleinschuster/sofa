#import "SFNet.h"
#import "SFStore.h"
#import "SFModel.h"
#import "SFCurl.h"

#import <SystemConfiguration/SystemConfiguration.h>

NSString *const SFNetOnlineDidChangeNotification = @"SFNetOnlineDidChange";
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
    gReach = SCNetworkReachabilityCreateWithName(NULL, "www.youtube.com");
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
        c.HTTPAdditionalHeaders = @{@"User-Agent": [self userAgent], @"Accept-Language": @"de-AT,de;q=0.9"};
        s = [NSURLSession sessionWithConfiguration:c delegate:SFTrustAllSessionDelegate() delegateQueue:nil];
    });
    return s;
}

+ (NSString *)userAgent {
    return @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
}

+ (void)request:(NSMutableURLRequest *)req cacheKey:(NSString *)key cacheAge:(NSTimeInterval)age done:(SFJSONDone)done {
    void (^finish)(id, NSError *) = ^(id j, NSError *e) { SFMain(^{ done(j, e); }); };
    if (key && age > 0) {
        id hit = [[SFStore shared] cachedJSON:key maxAge:age];
        if (hit) { finish(hit, nil); return; }
    }
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
    NSURL *u = [NSURL URLWithString:url];
    NSData *b = body ? [NSJSONSerialization dataWithJSONObject:body options:0 error:nil] : nil;
    if (!u || (body && !b)) { SFMain(^{ done(nil, SFError(@"Ungültige Anfrage.")); }); return; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    r.HTTPMethod = @"POST";
    r.HTTPBody = b;
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [headers enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { [r setValue:v forHTTPHeaderField:k]; }];
    NSString *key = [NSString stringWithFormat:@"POST %@ %@", url, b ? [[NSString alloc] initWithData:b encoding:NSUTF8StringEncoding] : @""];
    [self request:r cacheKey:key cacheAge:age done:done];
}
+ (void)checkRegion:(NSString *)url expect:(NSString *)expect done:(void (^)(BOOL))done {
    static NSMutableDictionary *cache;   // url -> @[@(allowed), date]
    static dispatch_once_t o; dispatch_once(&o, ^{ cache = [NSMutableDictionary new]; });
    NSArray *hit;
    @synchronized (cache) { hit = cache[url]; }
    if (hit && [hit[1] timeIntervalSinceNow] > -3600) { done([hit[0] boolValue]); return; }
    NSURL *u = [NSURL URLWithString:url];
    if (!u) { done(YES); return; }
    // without expected text: media URL -> HEAD only (don't download the whole file)
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    if (!expect) req.HTTPMethod = @"HEAD";
    [[[self session] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSInteger code = [(NSHTTPURLResponse *)r statusCode];
        NSString *body = d ? [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
        BOOL ok = e ? YES : (code < 400 && (!expect || [body isEqualToString:expect]));   // network error: don't block
        if (!e) @synchronized (cache) { cache[url] = @[@(ok), [NSDate date]]; }
        SFLog(@"geo: %@ -> %@", u.path, ok ? @"allowed" : @"blocked");
        SFMain(^{ done(ok); });
    }] resume];
}
+ (NSString *)escape:(NSString *)s {
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [s ?: @"" stringByAddingPercentEncodingWithAllowedCharacters:ok];
}
@end
