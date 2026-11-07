#import "SFYTChannel.h"
#import "SFModel.h"
#import <Security/Security.h>

// A poll is held this long without commands, then answered empty (the background polls again).
static const NSTimeInterval kPollHold = 20;

@implementation SFYTChannel {
    dispatch_queue_t _queue;
    NSMutableArray *_queued;            // commands not yet fetched
    NSMutableDictionary *_pending;      // id -> block(value, error), answered or timed out once
    SFHTTPExchange *_poll;              // the held poll, if any
    dispatch_source_t _pollTimer;
    long _nextID;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _queue = queue;
        _queued = [NSMutableArray new];
        _pending = [NSMutableDictionary new];
        uint8_t b[16];
        if (SecRandomCopyBytes(kSecRandomDefault, sizeof b, b) != 0) arc4random_buf(b, sizeof b);
        NSMutableString *t = [NSMutableString new];
        for (size_t i = 0; i < sizeof b; i++) [t appendFormat:@"%02x", b[i]];
        _token = t;
    }
    return self;
}

- (BOOL)handle:(SFHTTPExchange *)x {
    NSArray *p = x.request.pathParts;
    if (p.count != 2 || ![p[0] isEqualToString:@"engine"]) return NO;
    if (![x.request.query[@"token"] isEqualToString:_token]) { [x respond:403 type:nil body:nil]; return YES; }
    if ([p[1] isEqualToString:@"poll"] && [x.request.method isEqualToString:@"GET"]) { [self poll:x]; return YES; }
    if ([p[1] isEqualToString:@"post"] && [x.request.method isEqualToString:@"POST"]) { [self post:x]; return YES; }
    [x respond:404 type:nil body:nil];
    return YES;
}

#pragma mark Commands out

- (void)poll:(SFHTTPExchange *)x {
    if (_poll) [self answerPoll];   // a newer poll (another page, a retry) replaces the held one
    _poll = x;
    __weak SFYTChannel *ws = self;
    __weak SFHTTPExchange *wx = x;
    x.onClose = ^{ SFYTChannel *s = ws; if (s && s->_poll == wx) [s dropPoll]; };
    if (_queued.count) { [self answerPoll]; return; }
    _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_pollTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPollHold * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(_pollTimer, ^{ [ws answerPoll]; });
    dispatch_resume(_pollTimer);
}

- (void)dropPoll {
    if (_pollTimer) dispatch_source_cancel(_pollTimer);
    _pollTimer = nil;
    _poll = nil;
}

- (void)answerPoll {
    SFHTTPExchange *x = _poll;
    [self dropPoll];
    if (!x) return;
    NSArray *batch = [_queued copy];
    [_queued removeAllObjects];
    [x respondJSON:200 object:batch];
}

- (void)call:(NSString *)method args:(NSArray *)args timeout:(NSTimeInterval)timeout done:(void (^)(id, NSError *))done {
    dispatch_async(_queue, ^{
        NSNumber *cid = @(++self->_nextID);
        __block BOOL answered = NO;
        void (^once)(id, NSError *) = ^(id v, NSError *e) {
            if (answered) return;
            answered = YES;
            [self->_pending removeObjectForKey:cid];
            done(v, e);
        };
        self->_pending[cid] = [once copy];
        [self->_queued addObject:@{@"id": cid, @"method": method, @"args": args ?: @[]}];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), self->_queue, ^{
            NSUInteger i = [self->_queued indexOfObjectPassingTest:^BOOL(NSDictionary *c, NSUInteger n, BOOL *stop) { return [c[@"id"] isEqual:cid]; }];
            if (i != NSNotFound) [self->_queued removeObjectAtIndex:i];   // never fetched: don't run it late
            once(nil, SFError([NSString stringWithFormat:@"engine: no answer to %@ within %.0f s", method, timeout]));
        });
        if (self->_poll) [self answerPoll];
    });
}

- (void)failAll:(NSError *)error {
    dispatch_async(_queue, ^{
        [self->_queued removeAllObjects];
        for (void (^f)(id, NSError *) in [self->_pending allValues]) f(nil, error);
    });
}

#pragma mark Answers and events in

- (void)post:(SFHTTPExchange *)x {
    NSDictionary *up = [NSJSONSerialization JSONObjectWithData:x.request.body options:0 error:nil];
    if (![up isKindOfClass:[NSDictionary class]]) { [x respond:400 type:nil body:nil]; return; }
    [x respond:204 type:nil body:nil];
    for (id e in [up[@"events"] isKindOfClass:[NSArray class]] ? up[@"events"] : @[]) {
        NSDictionary *ev = [e isKindOfClass:[NSString class]]
            ? [NSJSONSerialization JSONObjectWithData:[e dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        if ([ev isKindOfClass:[NSDictionary class]] && self.onEvent) self.onEvent(ev);
    }
    for (NSDictionary *a in [up[@"answers"] isKindOfClass:[NSArray class]] ? up[@"answers"] : @[]) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        void (^f)(id, NSError *) = _pending[a[@"id"]];
        if (!f) continue;   // timed out meanwhile
        if (a[@"error"]) f(nil, SFError([NSString stringWithFormat:@"engine: %@", a[@"error"]]));
        else f(a[@"value"] == [NSNull null] ? nil : a[@"value"], nil);
    }
}
@end
