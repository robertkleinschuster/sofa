// lounge_stream.m - does NSURLSession on 10.9 deliver the Lounge long-poll chunks
// promptly (no 512-byte MIME-sniff buffering)?  Opens a throwaway screen + bind
// session, then a long-poll GET via a delegate-based NSURLSessionDataTask and logs
// every didReceiveData with a timestamp. Throwaway screen id, nothing persisted.
//
// build: /opt/local/bin/clang -fobjc-arc -mmacosx-version-min=10.9 -c lounge_stream.m -o /tmp/ls.o &&
//        /opt/local/bin/clang -mmacosx-version-min=10.9 /tmp/ls.o -framework Foundation -o /tmp/lounge_stream
//        (add  -I/opt/local/include -L/opt/local/lib -lcurl  for the curl mode)
// run:   /tmp/lounge_stream nsurl|nsurl-badsid|cfstream|curl [seconds]
#import <Foundation/Foundation.h>
#import <curl/curl.h>

static double T0;
static double now(void) { return [NSDate timeIntervalSinceReferenceDate] - T0; }

static NSString *enc(NSString *s) {
    return CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)s, NULL,
                             CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8));
}
static NSString *query(NSDictionary *d) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *k in d) [a addObject:[NSString stringWithFormat:@"%@=%@", enc(k), enc([d[k] description])]];
    return [a componentsJoinedByString:@"&"];
}
static NSData *syncReq(NSString *method, NSString *url, NSDictionary *body, NSInteger *status) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.HTTPMethod = method;
    if (body) {
        r.HTTPBody = [query(body) dataUsingEncoding:NSUTF8StringEncoding];
        [r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    }
    __block NSData *out = nil; __block NSInteger st = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        out = d; st = [(NSHTTPURLResponse *)resp statusCode]; dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (status) *status = st;
    return out;
}

@interface Poller : NSObject <NSURLSessionDataDelegate>
@end
@implementation Poller
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)resp
 completionHandler:(void (^)(NSURLSessionResponseDisposition))ch {
    NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
    printf("%7.2f response %ld %s\n", now(), (long)h.statusCode, [[h.allHeaderFields[@"Content-Type"] description] UTF8String]);
    ch(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d {
    NSString *txt = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    printf("%7.2f didReceiveData %4lu bytes: %s\n", now(), (unsigned long)d.length,
           [[[txt stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] substringToIndex:MIN(txt.length, 90)] UTF8String]);
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e {
    printf("%7.2f complete err=%s\n", now(), e ? [[e description] UTF8String] : "nil");
}
@end

static size_t curlWrite(char *ptr, size_t sz, size_t n, void *ud) {
    printf("%7.2f curl write %4lu bytes: %.*s\n", now(), (unsigned long)(sz * n), (int)MIN(sz * n, 60), ptr);
    fflush(stdout);
    return sz * n;
}

static void cfCallback(CFReadStreamRef st, CFStreamEventType ev, void *info) {
    if (ev == kCFStreamEventHasBytesAvailable) {
        UInt8 buf[4096];
        CFIndex n = CFReadStreamRead(st, buf, sizeof buf);
        printf("%7.2f CFReadStream %4ld bytes: %.*s\n", now(), (long)n, (int)MIN(n, 60), buf);
    } else if (ev == kCFStreamEventOpenCompleted) {
        printf("%7.2f CFReadStream open\n", now());
    } else {
        printf("%7.2f CFReadStream event %lu\n", now(), (unsigned long)ev);
    }
    fflush(stdout);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        T0 = [NSDate timeIntervalSinceReferenceDate];
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *mode = argc > 1 ? argv[1] : "nsurl";
        double secs = argc > 2 ? atof(argv[2]) : 70;
        NSString *api = @"https://www.youtube.com/api/lounge";
        NSInteger st;
        NSString *screen = [[NSString alloc] initWithData:syncReq(@"GET", [api stringByAppendingString:@"/pairing/generate_screen_id"], nil, &st)
                                                 encoding:NSUTF8StringEncoding];
        NSDictionary *tok = [NSJSONSerialization JSONObjectWithData:
                             syncReq(@"POST", [api stringByAppendingString:@"/pairing/get_lounge_token_batch"], @{@"screen_ids": screen}, &st) options:0 error:nil];
        NSString *lt = tok[@"screens"][0][@"loungeToken"];
        NSString *dev = [[NSUUID UUID] UUIDString].lowercaseString;
        NSDictionary *base = @{@"device": @"LOUNGE_SCREEN", @"id": dev, @"name": @"StreamTest", @"app": @"sofa",
                               @"theme": @"cl", @"loungeIdToken": lt, @"VER": @"8", @"v": @"2"};
        NSMutableDictionary *p = [base mutableCopy]; p[@"RID"] = @"1000"; p[@"CVER"] = @"1";
        NSData *b = syncReq(@"POST", [NSString stringWithFormat:@"%@/bc/bind?%@", api, query(p)], @{@"count": @"0"}, &st);
        NSString *txt = [[NSString alloc] initWithData:b encoding:NSUTF8StringEncoding];
        printf("%7.2f bind %ld (%lu bytes)\n", now(), (long)st, (unsigned long)b.length);
        // crude parse of c / S (the real implementation uses the framer + NSJSONSerialization)
        NSRange r1 = [txt rangeOfString:@"[\"c\",\""]; NSString *sid = [txt substringWithRange:NSMakeRange(NSMaxRange(r1), 16)];
        NSRange r2 = [txt rangeOfString:@"[\"S\",\""]; NSString *rest = [txt substringFromIndex:NSMaxRange(r2)];
        NSString *gs = [rest substringToIndex:[rest rangeOfString:@"\""].location];
        p = [base mutableCopy];
        p[@"RID"] = @"rpc"; p[@"SID"] = strcmp(mode, "nsurl-badsid") ? sid : @"0123456789ABCDEF";  // control: must give an immediate 410
        p[@"gsessionid"] = gs; p[@"CI"] = @"0"; p[@"AID"] = @"4"; p[@"TYPE"] = @"xmlhttp";
        NSString *url = [NSString stringWithFormat:@"%@/bc/bind?%@", api, query(p)];
        printf("%7.2f long-poll GET (%s) started\n", now(), mode);
        if (!strncmp(mode, "nsurl", 5)) {
            NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
            cfg.timeoutIntervalForRequest = 90;     // > noop interval (~30 s)
            NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg delegate:[Poller new] delegateQueue:nil];
            [[s dataTaskWithURL:[NSURL URLWithString:url]] resume];
        } else if (!strcmp(mode, "cfstream")) {
            CFHTTPMessageRef msg = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), (__bridge CFURLRef)[NSURL URLWithString:url], kCFHTTPVersion1_1);
            CFReadStreamRef rs = CFReadStreamCreateForHTTPRequest(NULL, msg);
            CFStreamClientContext ctx = {0};
            CFReadStreamSetClient(rs, kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered, cfCallback, &ctx);
            CFReadStreamScheduleWithRunLoop(rs, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            CFReadStreamOpen(rs);
        } else {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                CURL *c = curl_easy_init();
                curl_easy_setopt(c, CURLOPT_URL, url.UTF8String);
                curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, curlWrite);
                CURLcode rc = curl_easy_perform(c);
                printf("%7.2f curl done rc=%d\n", now(), rc);
            });
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
    }
    return 0;
}
