#import "SFYTInnerTube.h"

static NSString *const kClientVersion = @"2.20261030.02.00";
static NSString *const kOrigin = @"https://www.youtube.com";

void SFYTCall(NSString *endpoint, NSDictionary *body, NSTimeInterval cacheAge, SFJSONDone done) {
    NSMutableDictionary *b = [body mutableCopy];
    b[@"context"] = @{@"client": @{@"clientName": @"WEB", @"clientVersion": kClientVersion, @"hl": @"de", @"gl": @"AT"}};
    NSDictionary *h = @{@"X-Youtube-Client-Name": @"1", @"X-Youtube-Client-Version": kClientVersion, @"Origin": kOrigin};
    NSString *url = [NSString stringWithFormat:@"https://www.youtube.com/youtubei/v1/%@?prettyPrint=false", endpoint];
    [SFNet postJSON:url body:b headers:h cacheAge:cacheAge done:done];
}

id SFYTPath(id root, NSString *p) {
    id cur = root;
    for (NSString *k in [p componentsSeparatedByString:@"."]) {
        if (!k.length) continue;
        unichar c = [k characterAtIndex:0];
        if (c >= '0' && c <= '9') { NSArray *a = arr(cur); NSInteger i = k.integerValue; cur = (a && i < (NSInteger)a.count) ? a[i] : nil; }
        else cur = dict(cur)[k];
        if (!cur) return nil;
    }
    return nn(cur);
}

NSString *SFYTText(id n) {
    if (str(n)) return n;
    NSDictionary *d = dict(n);
    if (!d) return nil;
    if (str(d[@"simpleText"])) return d[@"simpleText"];
    if (str(d[@"content"])) return d[@"content"];
    NSArray *runs = arr(d[@"runs"]);
    if (runs) { NSMutableString *s = [NSMutableString new]; for (id r in runs) [s appendString:str(dict(r)[@"text"]) ?: @""]; return s.length ? s : nil; }
    return nil;
}

NSString *SFYTLastURL(id sources) {
    NSString *u = str(dict(arr(sources).lastObject)[@"url"]);
    if ([u hasPrefix:@"//"]) u = [@"https:" stringByAppendingString:u];
    return u;
}
