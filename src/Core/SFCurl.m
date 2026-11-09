#import "SFCurl.h"
#import "SFNet.h"
#import "SFUserAgent.h"
#import "SFModel.h"
#import "SFRuntime.h"
#include <curl/curl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#pragma mark - Hosts

// Hosts (exact) and domains (".example.org": every host below) that need the curl path: learned
// on TLS errors, or declared up front by the apps that know them (SFMarkDomainNeedsCurl).
static NSMutableSet *curlHosts(void) {
    static NSMutableSet *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [NSMutableSet new]; });
    return s;
}
static NSMutableSet *curlDomains(void) {
    static NSMutableSet *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [NSMutableSet new]; });
    return s;
}
BOOL SFHostNeedsCurl(NSString *host) {
    if (!host) return NO;
    NSMutableSet *s = curlHosts(), *d = curlDomains();
    @synchronized (s) { if ([s containsObject:host]) return YES; }
    @synchronized (d) { for (NSString *suffix in d) if ([host hasSuffix:suffix]) return YES; }
    return NO;
}
void SFMarkDomainNeedsCurl(NSString *domain) {
    if (!domain.length) return;
    NSMutableSet *d = curlDomains();
    @synchronized (d) { [d addObject:[domain hasPrefix:@"."] ? domain : [@"." stringByAppendingString:domain]]; }
}
void SFMarkHostNeedsCurl(NSString *host) {
    if (!host) return;
    NSMutableSet *s = curlHosts();
    @synchronized (s) { if (![s containsObject:host]) { [s addObject:host]; SFLog(@"tls: %@ -> curl", host); } }
}
BOOL SFIsTLSError(NSError *e) {
    if (![e.domain isEqualToString:NSURLErrorDomain]) return NO;
    return (e.code <= -1200 && e.code >= -1206) || e.code == -1205;
}

#pragma mark - Fetch


void SFCurlGlobalInit(void) {
    static dispatch_once_t o;
    dispatch_once(&o, ^{ curl_global_init(CURL_GLOBAL_DEFAULT); });
}

// Without TLS certificate verification (user decision 2026-11-04): an outdated CA bundle on the
// frozen 10.9 must never break anything. Code authenticity is ensured by signatures (SFUpdater:
// Sofa DMG), not TLS.
void *SFCurlNew(void) {
    CURL *c = curl_easy_init();
    if (c) {
        curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 0L);
        curl_easy_setopt(c, CURLOPT_SSL_VERIFYHOST, 0L);
    }
    return c;
}

typedef struct { __unsafe_unretained NSMutableData *data; __unsafe_unretained BOOL (^accept)(NSUInteger); } SFFetchSink;
static size_t appendData(char *p, size_t sz, size_t n, void *ud) {
    SFFetchSink *sink = ud;
    NSUInteger bytes = sz * n;
    if (sink->accept && !sink->accept(bytes)) return 0;
    [sink->data appendBytes:p length:bytes];
    return bytes;
}

static int fetchProgress(void *ud, curl_off_t total, curl_off_t now, curl_off_t upTotal, curl_off_t upNow) {
    SFFetchSink *sink = ud;
    return sink->accept && !sink->accept(0) ? 1 : 0; // cancellation even while no data arrives
}

static NSData *fetchFull(NSString *url, NSString *method, NSDictionary *headers, NSData *body,
                         NSInteger *status, NSString **effective, NSError **error, BOOL (^accept)(NSUInteger)) {
    SFCurlGlobalInit();
    CURL *c = SFCurlNew();
    if (!c) return nil;
    NSMutableData *out = [NSMutableData new];
    SFFetchSink sink = {out, accept};
    struct curl_slist *hl = NULL;
    for (NSString *k in headers) hl = curl_slist_append(hl, [NSString stringWithFormat:@"%@: %@", k, headers[k]].UTF8String);
    curl_easy_setopt(c, CURLOPT_URL, url.UTF8String);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c, CURLOPT_MAXREDIRS, 8L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 15L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, 60L);
    curl_easy_setopt(c, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(c, CURLOPT_USERAGENT, SFNativeUserAgent().UTF8String);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, appendData);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &sink);
    if (accept) {
        curl_easy_setopt(c, CURLOPT_NOPROGRESS, 0L);
        curl_easy_setopt(c, CURLOPT_XFERINFOFUNCTION, fetchProgress);
        curl_easy_setopt(c, CURLOPT_XFERINFODATA, &sink);
    }
    if (hl) curl_easy_setopt(c, CURLOPT_HTTPHEADER, hl);
    if ([method isEqualToString:@"POST"]) {
        curl_easy_setopt(c, CURLOPT_POST, 1L);
        curl_easy_setopt(c, CURLOPT_POSTFIELDSIZE, (long)body.length);
        curl_easy_setopt(c, CURLOPT_POSTFIELDS, body.bytes);
    } else if ([method isEqualToString:@"HEAD"]) {
        curl_easy_setopt(c, CURLOPT_NOBODY, 1L);
    }
    CURLcode rc = curl_easy_perform(c);
    long code = 0; char *eff = NULL;
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
    curl_easy_getinfo(c, CURLINFO_EFFECTIVE_URL, &eff);
    if (status) *status = code;
    if (effective) *effective = eff ? @(eff) : url;
    if (rc != CURLE_OK && error) *error = [NSError errorWithDomain:@"curl" code:rc userInfo:@{NSLocalizedDescriptionKey: @(curl_easy_strerror(rc))}];
    if (hl) curl_slist_free_all(hl);
    curl_easy_cleanup(c);
    return rc == CURLE_OK ? out : nil;
}

NSData *SFCurlFetch(NSString *url, NSString *method, NSDictionary *headers, NSData *body, NSInteger *status, NSError **error) {
    if (SFSimulatedOffline()) { if (error) *error = SFError(@"Keine Internetverbindung."); return nil; }
    return fetchFull(url, method ?: @"GET", headers, body, status, NULL, error, nil);
}

NSData *SFCurlFetchFinal(NSString *url, NSInteger *status, NSString **effective, NSError **error) {
    if (SFSimulatedOffline()) { if (error) *error = SFError(@"Keine Internetverbindung."); return nil; }
    return fetchFull(url, @"GET", nil, nil, status, effective, error, nil);
}

NSData *SFCurlFetchLimitedFinal(NSString *url, NSInteger *status, NSString **effective, NSError **error, BOOL (^accept)(NSUInteger)) {
    if (SFSimulatedOffline()) { if (error) *error = SFError(@"Keine Internetverbindung."); return nil; }
    return fetchFull(url,@"GET",nil,nil,status,effective,error,accept);
}

static size_t writeFile(char *p, size_t sz, size_t n, void *ud) {
    return fwrite(p, sz, n, (FILE *)ud) * sz;
}

BOOL SFCurlDownload(NSString *url, NSString *path, NSError **error) {
    SFCurlGlobalInit();
    FILE *f = fopen(path.fileSystemRepresentation, "wb");
    if (!f) { if (error) *error = SFError(@"Datei nicht schreibbar."); return NO; }
    CURL *c = SFCurlNew();
    curl_easy_setopt(c, CURLOPT_URL, url.UTF8String);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);          // GitHub assets redirect to their CDN
    curl_easy_setopt(c, CURLOPT_MAXREDIRS, 8L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 20L);
    curl_easy_setopt(c, CURLOPT_LOW_SPEED_LIMIT, 1024L);      // < 1 KB/s for 60 s -> abort
    curl_easy_setopt(c, CURLOPT_LOW_SPEED_TIME, 60L);
    curl_easy_setopt(c, CURLOPT_FAILONERROR, 1L);
    curl_easy_setopt(c, CURLOPT_USERAGENT, SFNativeUserAgent().UTF8String);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, writeFile);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, f);
    CURLcode rc = curl_easy_perform(c);
    curl_easy_cleanup(c);
    BOOL ok = fclose(f) == 0 && rc == CURLE_OK;
    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if (error) *error = [NSError errorWithDomain:@"curl" code:rc userInfo:@{NSLocalizedDescriptionKey: @(curl_easy_strerror(rc))}];
    }
    return ok;
}
