// SFYTEngine (Calls) - the plain InnerTube-side calls through the page: innertube, suggestions, images
// and availability. Split from SFYTEngine.m (lifecycle, sessions) by responsibility.
#import "SFYTEngine+Private.h"
#import "SFJSON.h"

static const NSTimeInterval kCallTimeout = 30;   // as SFYTEngine.m's

@implementation SFYTEngine (Calls)

- (void)innertube:(NSString *)endpoint body:(NSDictionary *)body background:(BOOL)bg done:(void (^)(id, NSError *))done {
    [self call:@"innertube" args:@[endpoint, body ?: @{}, @{@"bg": @(bg)}] timeout:kCallTimeout done:done];
}

- (void)suggest:(NSString *)prefix done:(void (^)(id, NSError *))done {
    [self call:@"suggest" args:@[prefix ?: @""] timeout:10 done:done];
}

- (void)image:(NSURL *)url done:(void (^)(NSData *, NSInteger))done {
    SFMain(^{
        [self call:@"image" args:@[url.absoluteString ?: @""] timeout:kCallTimeout done:^(id v, NSError *e) {
            NSData *d = bin(dict(v)[@"data"]);
            // an engine error carries the host's status; unanswered/not ready: none
            NSInteger st = d ? 200 : (e && ![e.userInfo[@"unanswered"] boolValue] && e.code >= 400 && e.code < 500) ? e.code : 0;
            done(d, st);
        }];
    });
}

- (void)oembed:(NSString *)vid done:(void (^)(NSInteger, NSString *))done {
    SFMain(^{
        [self call:@"oembed" args:@[vid ?: @""] timeout:kCallTimeout done:^(id v, NSError *e) {
            NSDictionary *d = dict(v);
            NSInteger st = [nn(d[@"status"]) integerValue];
            done(st, st == 200 ? str(d[@"title"]) : nil);
        }];
    });
}

- (void)availability:(NSString *)vid done:(void (^)(NSInteger))done {
    [self call:@"availability" args:@[vid ?: @""] timeout:kCallTimeout done:^(id v, NSError *e) {
        NSInteger st = [v isKindOfClass:[NSNumber class]] ? [v integerValue] : 0;
        done(st == 200 ? 1 : (st == 400 || st == 404) ? 0 : -1);
    }];
}
@end
