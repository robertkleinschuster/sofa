#import "SFWebServer+Private.h"
#import "SFTLS.h"
#import "SFTailnet.h"
#import "SFWebDevices.h"
#import "SFWebStreams.h"
#import "SFWebImages.h"
#import "SFWebTV.h"
#import "SFJSON.h"

NSString *const SFWebServerStatusDidChangeNotification = @"SFWebServerStatusDidChange";

static const uint16_t kPort = 7443;
static NSString *const kAppURL = @"https://robertkleinschuster.github.io/sofa/";   // the Pages site (.github/workflows/pwa.yml)
static const NSTimeInterval kCertCheck = 86400;
static const NSTimeInterval kRenewBefore = 30 * 86400;
static const NSTimeInterval kListenRetry = 10;
static const NSTimeInterval kCertRetry = 600;   // Tailscale not up yet, a failed issue

void SFWebReply(SFHTTPExchange *x, NSInteger status, id object) {
    dispatch_async(x.queue, ^{ [x respondJSON:status object:object]; });
}

static NSString *Origin(NSString *url) {
    NSURL *u = [NSURL URLWithString:url];
    if (!u.scheme || !u.host) return nil;
    return u.port ? [NSString stringWithFormat:@"%@://%@:%@", u.scheme, u.host, u.port] : [NSString stringWithFormat:@"%@://%@", u.scheme, u.host];
}

@implementation SFWebServer {
    dispatch_queue_t _q;
    SFLocalHTTP *_http;
    SFTLS *_tls;
    NSArray *_origins;
    BOOL _loopback, _ownCert, _started;
    NSTimer *_certTimer;
}

+ (instancetype)shared {
    static SFWebServer *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SFWebServer new]; });
    return s;
}

+ (NSString *)appURL { return SFDevEnv(@"SOFA_WEB_APP_URL") ?: kAppURL; }

- (void)startWithHost:(id<SFPlayerHost>)host {
    if (_started || (SFDevMode && !SFDevEnv(@"SOFA_WEB_PORT"))) return;
    _started = YES;
    [SFWebTV shared].host = host;
    _q = dispatch_queue_create("sofa.web", DISPATCH_QUEUE_SERIAL);
    _tls = [SFTLS new];
    _port = SFDevMode ? (uint16_t)SFDevEnv(@"SOFA_WEB_PORT").intValue : kPort;
    NSMutableArray *origins = [NSMutableArray arrayWithObject:Origin(kAppURL)];
    for (NSString *o in [SFDevEnv(@"SOFA_WEB_ORIGINS") componentsSeparatedByString:@","]) if (o.length) [origins addObject:o];
    _origins = origins;
    _loopback = SFDevEnv(@"SOFA_WEB_LOOPBACK") != nil;
    NSString *cert = SFDevEnv(@"SOFA_WEB_CERT"), *key = SFDevEnv(@"SOFA_WEB_KEY");
    if (cert && key) {   // a dev instance's own certificate: no tailnet
        _ownCert = YES;
        NSError *e = nil;
        if (![_tls loadCertificate:cert key:key error:&e]) SFLog(@"web: %@", e.localizedDescription);
        _fullName = _tls.subjectName; _shortName = [_fullName componentsSeparatedByString:@"."].firstObject;
    } else {
        [self checkCertificate];
        _certTimer = [NSTimer scheduledTimerWithTimeInterval:kCertCheck target:self selector:@selector(checkCertificate) userInfo:nil repeats:YES];
    }
    [self listen];
}

- (void)setProblem:(NSString *)p {
    if ((p ?: @"").length == (_problem ?: @"").length && [p ?: @"" isEqualToString:_problem ?: @""]) return;
    _problem = [p copy];
    if (p) SFLog(@"web: %@", p);
    [[NSNotificationCenter defaultCenter] postNotificationName:SFWebServerStatusDidChangeNotification object:self];
}

- (void)listen {
    __weak SFWebServer *ws = self;
    _http = [[SFLocalHTTP alloc] initWithName:@"web" queue:_q maxBody:256 * 1024 handler:^(SFHTTPExchange *x) { [ws handle:x]; }];
    BOOL loopback = _loopback;
    BOOL ok = [_http startOnAllAddresses:_port security:_tls accept:^BOOL(const struct sockaddr *local, const struct sockaddr *peer) {
        return SFIsTailnetAddress(local) || (loopback && SFIsLoopbackAddress(local));
    }];
    if (ok) { SFLog(@"web: listening on port %u (tailnet%@)", _http.port, loopback ? @" + loopback" : @""); return; }
    _http = nil;   // the port is still taken (the Sofa before an update): again shortly
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kListenRetry * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws listen]; });
}

#pragma mark Certificate

// The tailnet's certificate for this machine: renewed by tailscaled within its last 30 days (it
// answers with its cached one before), loaded into the running server
- (void)checkCertificate {
    if (_ownCert) return;
    NSString *dir = [SFAppSupportDir() stringByAppendingPathComponent:@"web"];
    NSString *cert = [dir stringByAppendingPathComponent:@"tailnet.crt"], *key = [dir stringByAppendingPathComponent:@"tailnet.key"];
    SFTLS *tls = _tls;
    __weak SFWebServer *ws = self;
    SFBackground(^{
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
        NSDictionary *st = [SFTailnet status];
        NSString *domain = str(st[@"certDomain"]), *dns = str(st[@"dnsName"]), *problem = nil, *why = nil;
        if (![SFTailnet cliPath]) problem = @"Tailscale ist auf diesem Mac nicht installiert.";
        else if (!st) problem = @"Tailscale läuft gerade nicht oder ist nicht angemeldet.";
        else if (!domain) problem = @"Im Tailnet sind HTTPS-Zertifikate nicht eingeschaltet (Tailscale-Verwaltung: DNS → HTTPS Certificates).";
        if (!problem) {
            NSDate *expires = [SFTLS expiryOfCertificate:cert];
            BOOL due = !expires || [expires timeIntervalSinceNow] < kRenewBefore;
            if (due && ![SFTailnet fetchCertificateFor:domain cert:cert key:key error:&why]) {
                if (!expires || [expires timeIntervalSinceNow] <= 0) problem = @"Das Zertifikat für die sichere Verbindung ließ sich nicht holen.";
                SFLog(@"web: certificate for the tailnet name not renewed: %@", why);
            } else if (due) SFLog(@"web: certificate renewed (valid until %@)", [SFTLS expiryOfCertificate:cert]);
        }
        NSError *e = nil;
        if (!problem && ![tls loadCertificate:cert key:key error:&e]) problem = @"Das Zertifikat für die sichere Verbindung ist unbrauchbar.";
        if (e) SFLog(@"web: %@", e.localizedDescription);
        SFMain(^{
            SFWebServer *me = ws;
            if (!me) return;
            if (!problem) { me->_fullName = domain; me->_shortName = [dns componentsSeparatedByString:@"."].firstObject ?: domain; }
            [me setProblem:problem];
            if (problem) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCertRetry * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws checkCertificate]; });
            else [[NSNotificationCenter defaultCenter] postNotificationName:SFWebServerStatusDidChangeNotification object:me];
        });
    });
}

#pragma mark Requests (server queue)

- (void)handle:(SFHTTPExchange *)x {
    SFHTTPRequest *r = x.request;
    NSString *origin = [r header:@"origin"];
    NSMutableDictionary *h = [@{@"X-Content-Type-Options": @"nosniff", @"Referrer-Policy": @"no-referrer"} mutableCopy];
    if (origin && [_origins containsObject:origin]) {
        h[@"Access-Control-Allow-Origin"] = origin;
        h[@"Vary"] = @"Origin";
        h[@"Access-Control-Expose-Headers"] = @"Content-Length, Content-Range, Accept-Ranges";
    }
    x.extraHeaders = h;
    NSArray *parts = r.pathParts;
    NSString *first = parts.firstObject ?: @"";
    if (!r.secure) { [self plain:x]; return; }
    if ([r.method isEqualToString:@"OPTIONS"]) { [self preflight:x allowed:h[@"Access-Control-Allow-Origin"] != nil]; return; }
    if ([first isEqualToString:@"m"] && parts.count >= 3) {   // a stream's capability path
        NSString *sid = parts[1];
        if ([r.method isEqualToString:@"POST"] && parts.count == 3 && [parts[2] isEqualToString:@"state"]) {   // also from sendBeacon
            NSDictionary *state = dict([NSJSONSerialization JSONObjectWithData:r.body options:0 error:nil]);
            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger st = [[SFWebStreams shared] report:sid device:nil state:state ?: @{}];
                SFWebReply(x, st, @{@"ok": st == 200 ? @YES : @NO});
            });
            return;
        }
        [[SFWebStreams shared] serve:x stream:sid rest:[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)]];
        return;
    }
    if ([first isEqualToString:@"img"] && parts.count == 2) { [self image:x signature:parts[1]]; return; }
    if ([first isEqualToString:@"api"]) {
        NSString *auth = [r header:@"authorization"];
        NSString *device = [auth hasPrefix:@"Bearer "] ? [[SFWebDevices shared] deviceForToken:[auth substringFromIndex:7]] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ [self api:x parts:[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] device:device]; });
        return;
    }
    [x respondJSON:404 object:@{@"error": @"not found"}];
}

- (void)preflight:(SFHTTPExchange *)x allowed:(BOOL)allowed {
    if (!allowed) { [x respond:403 type:nil body:nil]; return; }
    NSMutableDictionary *h = [@{@"Access-Control-Allow-Methods": @"GET, POST, DELETE, OPTIONS",
                                @"Access-Control-Allow-Headers": @"Authorization, Content-Type, Range",
                                @"Access-Control-Max-Age": @"600", @"Content-Length": @"0"} mutableCopy];
    // Chrome's Private Network Access: a public page asking for a private address
    if ([[x.request header:@"access-control-request-private-network"] isEqualToString:@"true"]) h[@"Access-Control-Allow-Private-Network"] = @"true";
    [x begin:204 headers:h];
    [x finish];
}

// Plain HTTP: only the connect redirect - it teaches the PWA this machine's full name (the
// certificate's) after the user typed the short one; anything else goes to https
- (void)plain:(SFHTTPExchange *)x {
    SFHTTPRequest *r = x.request;
    NSString *full = _fullName;
    uint16_t port = _http.port;
    if ([r.pathParts.firstObject isEqualToString:@"connect"] && r.pathParts.count == 1) {
        NSString *ret = r.query[@"return"];
        NSString *o = Origin(ret);
        BOOL ok = o && [_origins containsObject:o] && [ret hasPrefix:[o stringByAppendingString:@"/"]] && [ret rangeOfString:@"#"].location == NSNotFound;
        if (!ok) { [x respond:400 type:@"text/plain; charset=utf-8" body:[@"Unbekannte Rücksprungadresse." dataUsingEncoding:NSUTF8StringEncoding]]; return; }
        NSString *frag = full ? [NSString stringWithFormat:@"#host=%@:%u", full, port] : @"#error=https";
        [x begin:303 headers:@{@"Location": [ret stringByAppendingString:frag], @"Content-Length": @"0"}];
        [x finish];
        return;
    }
    if (!full) { [x respond:400 type:@"text/plain; charset=utf-8" body:[@"Nur über HTTPS erreichbar." dataUsingEncoding:NSUTF8StringEncoding]]; return; }
    NSString *path = [@"/" stringByAppendingString:[r.pathParts componentsJoinedByString:@"/"]];
    [x begin:308 headers:@{@"Location": [NSString stringWithFormat:@"https://%@:%u%@", full, port, path], @"Content-Length": @"0"}];
    [x finish];
}

// /img/<signature>?u=<source>&w=<px>: a picture this server handed out, cached by the browser
- (void)image:(SFHTTPExchange *)x signature:(NSString *)sig {
    NSString *src = x.request.query[@"u"];
    if (![SFWebImages signature:sig matches:src]) { [x respondJSON:403 object:@{@"error": @"unknown picture"}]; return; }
    NSUInteger w = (NSUInteger)MAX(0, [x.request.query[@"w"] integerValue]);
    [SFWebImages imageFor:src width:w done:^(NSData *data, NSString *mime) {
        dispatch_async(x.queue, ^{
            if (!data) { [x respondJSON:404 object:@{@"error": @"no picture"}]; return; }
            [x begin:200 headers:@{@"Content-Type": mime, @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
                                   @"Cache-Control": @"private, max-age=86400", @"Content-Security-Policy": @"sandbox"}];
            if (![x.request.method isEqualToString:@"HEAD"]) [x write:data done:nil];
            [x finish];
        });
    }];
}
@end
