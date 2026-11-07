// The phone lounge's transport through the engine page (lib/lounge.ts on the page side): short
// requests as calls, the bind channel's long poll as `lounge` events (bytes, then an end).
#import "SFModel.h"
#import "SFYTEngine+Private.h"
#import "SFJSON.h"

// a poll's call is answered at once; its end comes as an event within the page's silence limit
// (70 s without bytes) - beyond this the page is taken for gone
static const NSTimeInterval kPollStartTimeout = 30, kPollMaxSeconds = 420;
static const NSTimeInterval kRequestTimeout = 30;

@implementation SFYTEngine (Lounge)

// id -> @[data block, done block]
static NSMutableDictionary *Polls(void) {
    static NSMutableDictionary *polls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ polls = [NSMutableDictionary new]; });
    return polls;
}

static NSArray *TakePoll(NSString *pid) {
    NSMutableDictionary *polls = Polls();
    @synchronized (polls) {
        NSArray *p = polls[pid];
        [polls removeObjectForKey:pid];
        return p;
    }
}

// Straight from the caller's queue, never through the main queue: SFLounge waits on its own queue,
// which the main thread waits for at times (dropSession, the goodbye at quit). Until the engine is
// ready the call fails at once (no answer) and the engine is asked to start; the lounge retries.
- (void)loungeCall:(NSString *)method args:(NSArray *)args timeout:(NSTimeInterval)timeout done:(void (^)(id, NSError *))done {
    if (self.ready) { [self request:method args:args timeout:timeout done:done]; return; }
    dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
    done(nil, [NSError errorWithDomain:@"SFYTEngine" code:503 userInfo:@{NSLocalizedDescriptionKey: @"engine not ready", @"unanswered": @YES}]);
}

- (void)loungeRequest:(NSString *)method url:(NSString *)url body:(NSString *)body done:(void (^)(NSData *, NSInteger))done {
    [self loungeCall:@"loungeRequest" args:@[method ?: @"GET", url ?: @"", body ?: [NSNull null]] timeout:kRequestTimeout done:^(id v, NSError *e) {
        NSDictionary *r = dict(v);
        NSString *b64 = str(r[@"data"]);
        done(b64 ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil, e ? 0 : num(r[@"status"]).integerValue);
    }];
}

- (void)loungePoll:(NSString *)url data:(void (^)(NSData *))onData done:(void (^)(NSInteger))done {
    NSString *pid = [[NSUUID UUID] UUIDString];
    NSMutableDictionary *polls = Polls();
    @synchronized (polls) { polls[pid] = @[[onData copy], [done copy]]; }
    void (^end)(NSInteger) = ^(NSInteger st) { NSArray *p = TakePoll(pid); if (p) ((void (^)(NSInteger))p[1])(st); };
    [self loungeCall:@"loungePoll" args:@[pid, url ?: @""] timeout:kPollStartTimeout done:^(id v, NSError *e) { if (e) end(0); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPollMaxSeconds * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ end(0); });
}

- (void)loungeEvent:(NSDictionary *)e {
    NSString *pid = str(e[@"id"]);
    if (!pid) return;
    if ([e[@"end"] boolValue]) {
        NSArray *p = TakePoll(pid);   // an earlier Sofa's poll (taken-over page): nobody waits
        if (str(e[@"error"])) SFLog(@"lounge: poll ended: %@", e[@"error"]);
        if (p) ((void (^)(NSInteger))p[1])(num(e[@"status"]).integerValue);
        return;
    }
    NSArray *p;
    NSMutableDictionary *polls = Polls();
    @synchronized (polls) { p = polls[pid]; }
    NSString *b64 = str(e[@"data"]);
    NSData *d = b64 ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
    if (p && d) ((void (^)(NSData *))p[0])(d);
}

- (void)endLoungePolls {
    NSArray *all;
    NSMutableDictionary *polls = Polls();
    @synchronized (polls) { all = polls.allValues; [polls removeAllObjects]; }
    for (NSArray *p in all) ((void (^)(NSInteger))p[1])(0);
}
@end
