#import "SFYTInnerTube.h"
#import "SFYTEngine.h"
#import "SFStore.h"

static void call(NSString *endpoint, NSDictionary *body, NSTimeInterval age, BOOL bg, SFJSONDone done) {
    NSData *b = [NSJSONSerialization dataWithJSONObject:body ?: @{} options:0 error:nil];
    NSString *key = [NSString stringWithFormat:@"yt %@ %@", endpoint, b ? [[NSString alloc] initWithData:b encoding:NSUTF8StringEncoding] : @""];
    // cache reads are disk reads: off the main thread (SFNet's request, hitch monitor 2026-11-07)
    SFBackground(^{
        id hit = age > 0 ? [[SFStore shared] cachedJSON:key maxAge:age] : nil;
        if (hit) { SFMain(^{ done(hit, nil); }); return; }
        SFMain(^{ [[SFYTEngine shared] innertube:endpoint body:body background:bg done:^(id json, NSError *e) {
            if (json && !e) { if (age > 0) [[SFStore shared] cacheJSON:json forKey:key]; done(json, nil); return; }
            // no engine (yet) or no answer: an older answer rather than none, never a request of our own
            SFBackground(^{
                id stale = [[SFStore shared] cachedJSON:key maxAge:30 * 86400];
                SFMain(^{ done(stale, stale ? nil : (e ?: SFError(@"YouTube antwortet nicht."))); });
            });
        }]; });   // SFYTEngine lives on the main thread
    });
}

void SFYTCall(NSString *endpoint, NSDictionary *body, NSTimeInterval age, SFJSONDone done) { call(endpoint, body, age, NO, done); }
void SFYTCallBackground(NSString *endpoint, NSDictionary *body, NSTimeInterval age, SFJSONDone done) { call(endpoint, body, age, YES, done); }

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
