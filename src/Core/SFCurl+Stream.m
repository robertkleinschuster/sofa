// SFCurlStream (SFCurl.h): a streamed range GET with backpressure - the media proxy's source reads.
#import "SFCurl.h"
#import "SFModel.h"
#import "SFUserAgent.h"
#import "SFRuntime.h"
#include <curl/curl.h>

// SFCurlStream's state across curl's callbacks
@interface SFCurlStreamState : NSObject
@property (nonatomic, copy) BOOL (^head)(NSInteger, long long, NSString *);
@property (nonatomic, copy) BOOL (^chunk)(NSData *);
@property (nonatomic, copy) BOOL (^continuing)(void);
@property (nonatomic) long long start, total, length;
@property (nonatomic, copy) NSString *mime;
@property (nonatomic) BOOL headDone, stopped;
@property (nonatomic) void *curl;
@end
@implementation SFCurlStreamState
@end

// header lines of every response (a redirect's too): the last response's decide
static size_t streamHeader(char *p, size_t sz, size_t n, void *ud) {
    SFCurlStreamState *st = (__bridge SFCurlStreamState *)ud;
    NSString *line = [[[NSString alloc] initWithBytes:p length:sz * n encoding:NSISOLatin1StringEncoding]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRange colon = [line rangeOfString:@":"];
    if ([line hasPrefix:@"HTTP/"]) { st.total = -1; st.length = -1; st.mime = nil; return sz * n; }
    if (colon.location == NSNotFound) return sz * n;
    NSString *k = [line substringToIndex:colon.location].lowercaseString;
    NSString *v = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([k isEqualToString:@"content-range"]) {          // "bytes a-b/total"
        NSRange slash = [v rangeOfString:@"/" options:NSBackwardsSearch];
        if (slash.location != NSNotFound) st.total = [[v substringFromIndex:slash.location + 1] longLongValue] ?: -1;
    } else if ([k isEqualToString:@"content-length"]) st.length = v.longLongValue;
    else if ([k isEqualToString:@"content-type"]) st.mime = [[v componentsSeparatedByString:@";"].firstObject copy];
    return sz * n;
}

static size_t streamWrite(char *p, size_t sz, size_t n, void *ud) {
    SFCurlStreamState *st = (__bridge SFCurlStreamState *)ud;
    if (!st.headDone) {
        st.headDone = YES;
        long code = 0;
        curl_easy_getinfo((CURL *)st.curl, CURLINFO_RESPONSE_CODE, &code);
        long long total = st.total > 0 ? st.total : (code == 200 && st.length >= 0 ? st.length : -1);
        if (!st.head(code, total, st.mime)) { st.stopped = YES; return 0; }
    }
    if (!st.chunk([NSData dataWithBytes:p length:sz * n])) { st.stopped = YES; return 0; }
    return sz * n;
}

static int streamProgress(void *ud, curl_off_t total, curl_off_t now, curl_off_t upTotal, curl_off_t upNow) {
    SFCurlStreamState *st = (__bridge SFCurlStreamState *)ud;
    if (st.continuing && !st.continuing()) { st.stopped = YES; return 1; }
    return 0;
}

BOOL SFCurlStreamWhile(NSString *url, long long start, long long end, long long maxRate,
                  BOOL (^continuing)(void), BOOL (^head)(NSInteger, long long, NSString *), BOOL (^chunk)(NSData *), NSError **error) {
    if (SFSimulatedOffline()) { if (error) *error = SFError(@"Keine Internetverbindung."); return NO; }
    SFCurlGlobalInit();
    CURL *c = SFCurlNew();
    if (!c) return NO;
    SFCurlStreamState *st = [SFCurlStreamState new];
    st.head = head; st.chunk = chunk; st.continuing = continuing; st.start = start; st.total = -1; st.length = -1; st.curl = c;
    NSString *range = end > start ? [NSString stringWithFormat:@"%lld-%lld", start, end - 1] : [NSString stringWithFormat:@"%lld-", start];
    curl_easy_setopt(c, CURLOPT_URL, url.UTF8String);
    curl_easy_setopt(c, CURLOPT_RANGE, range.UTF8String);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c, CURLOPT_MAXREDIRS, 8L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 15L);
    curl_easy_setopt(c, CURLOPT_LOW_SPEED_LIMIT, 1024L);   // < 1 KB/s for 30 s: a dead connection ends
    curl_easy_setopt(c, CURLOPT_LOW_SPEED_TIME, 30L);
    curl_easy_setopt(c, CURLOPT_USERAGENT, SFNativeUserAgent().UTF8String);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    if (maxRate > 0) curl_easy_setopt(c, CURLOPT_MAX_RECV_SPEED_LARGE, (curl_off_t)maxRate);
    curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, streamHeader);
    curl_easy_setopt(c, CURLOPT_HEADERDATA, (__bridge void *)st);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, streamWrite);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, (__bridge void *)st);
    if (continuing) {
        curl_easy_setopt(c, CURLOPT_NOPROGRESS, 0L);
        curl_easy_setopt(c, CURLOPT_XFERINFOFUNCTION, streamProgress);
        curl_easy_setopt(c, CURLOPT_XFERINFODATA, (__bridge void *)st);
    }
    CURLcode rc = curl_easy_perform(c);
    if (rc == CURLE_OK && !st.headDone) {   // an empty body: the head still answers
        long code = 0; curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
        head(code, st.total > 0 ? st.total : -1, st.mime);
    }
    curl_easy_cleanup(c);
    if (rc != CURLE_OK && !st.stopped) {
        if (error) *error = [NSError errorWithDomain:@"curl" code:rc userInfo:@{NSLocalizedDescriptionKey: @(curl_easy_strerror(rc))}];
        return NO;
    }
    return YES;
}

BOOL SFCurlStream(NSString *url, long long start, long long end, long long maxRate,
                  BOOL (^head)(NSInteger,long long,NSString *), BOOL (^chunk)(NSData *), NSError **error) {
    return SFCurlStreamWhile(url,start,end,maxRate,nil,head,chunk,error);
}
