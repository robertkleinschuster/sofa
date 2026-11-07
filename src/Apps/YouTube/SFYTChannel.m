#import "SFYTChannel.h"
#import "SFModel.h"
#import "SFWebSocket.h"
#import <Security/Security.h>

NSString *const SFYTChannelErrorDomain = @"SFYTChannel";

@implementation SFYTChannel {
    dispatch_queue_t _queue;
    NSMutableArray *_queued;            // commands not yet sent (no connection)
    NSMutableDictionary *_pending;      // id -> block(value, error), answered or timed out once
    SFWebSocket *_socket;               // the extension's connection, if any
    NSUInteger _maxMessage;
    long _nextID;
}

NSString *SFYTChannelNewToken(void) {
    uint8_t b[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof b, b) != 0) arc4random_buf(b, sizeof b);
    NSMutableString *t = [NSMutableString new];
    for (size_t i = 0; i < sizeof b; i++) [t appendFormat:@"%02x", b[i]];
    return t;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue token:(NSString *)token maxMessage:(NSUInteger)max {
    if ((self = [super init])) {
        _queue = queue;
        _maxMessage = max;
        _queued = [NSMutableArray new];
        _pending = [NSMutableDictionary new];
        _token = [token copy];
    }
    return self;
}

- (BOOL)handle:(SFHTTPExchange *)x {
    NSArray *p = x.request.pathParts;
    if (p.count != 2 || ![p[0] isEqualToString:@"engine"]) return NO;
    if (![x.request.query[@"token"] isEqualToString:_token]) { [x respond:403 type:nil body:nil]; return YES; }
    if (![p[1] isEqualToString:@"ws"]) { [x respond:404 type:nil body:nil]; return YES; }
    SFWebSocket *ws = [x acceptWebSocket:_maxMessage];
    if (ws) [self connected:ws];
    return YES;
}

#pragma mark Connection

// The newest connection is the extension's (a restarted background, a taken-over browser after a
// Sofa restart); an older one is closed. Commands queued while there was none go out now.
- (void)connected:(SFWebSocket *)ws {
    [_socket close];
    _socket = ws;
    __weak SFYTChannel *wself = self;
    __weak SFWebSocket *wws = ws;
    ws.onMessage = ^(BOOL binary, NSData *payload) { [wself received:payload binary:binary]; };
    ws.onClose = ^{ SFYTChannel *s = wself; if (s && s->_socket == wws) s->_socket = nil; };
    [self flush];
}

- (void)flush {
    if (!_socket || !_queued.count) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:_queued options:0 error:nil];
    [_queued removeAllObjects];
    [_socket sendText:[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]];
}

#pragma mark Answers and events in

// A message of the extension: {answers, events} as JSON text, or binary - a 4-byte big-endian
// length, that JSON, then blocks of bytes (each with its 4-byte length) that `{"$blob": n}` in the
// JSON stand for (media and pictures without base64).
- (void)received:(NSData *)payload binary:(BOOL)binary {
    id up = binary ? SFYTChannelDecodeBinary(payload) : [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    if (![up isKindOfClass:[NSDictionary class]]) { SFLog(@"yt-engine: unreadable channel message (%lu bytes)", (unsigned long)payload.length); return; }
    for (id e in [up[@"events"] isKindOfClass:[NSArray class]] ? up[@"events"] : @[]) {
        NSDictionary *ev = [e isKindOfClass:[NSString class]]
            ? [NSJSONSerialization JSONObjectWithData:[e dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : e;
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

static id Substitute(id v, NSArray *blobs) {
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSNumber *i = [v count] == 1 ? v[@"$blob"] : nil;
        if ([i isKindOfClass:[NSNumber class]]) return i.unsignedIntegerValue < blobs.count ? blobs[i.unsignedIntegerValue] : [NSNull null];
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:[v count]];
        [(NSDictionary *)v enumerateKeysAndObjectsUsingBlock:^(id k, id o, BOOL *stop) { d[k] = Substitute(o, blobs); }];
        return d;
    }
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:[v count]];
        for (id o in v) [a addObject:Substitute(o, blobs)];
        return a;
    }
    return v;
}

static BOOL ReadLength(NSData *d, NSUInteger *at, NSUInteger *len) {
    if (d.length - *at < 4) return NO;
    const uint8_t *p = (const uint8_t *)d.bytes + *at;
    *len = ((NSUInteger)p[0] << 24) | ((NSUInteger)p[1] << 16) | ((NSUInteger)p[2] << 8) | p[3];
    *at += 4;
    return *len <= d.length - *at;
}

id SFYTChannelDecodeBinary(NSData *d) {
    NSUInteger at = 0, len = 0;
    if (!ReadLength(d, &at, &len)) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:[d subdataWithRange:NSMakeRange(at, len)] options:0 error:nil];
    at += len;
    NSMutableArray *blobs = [NSMutableArray new];
    while (at < d.length) {
        if (!ReadLength(d, &at, &len)) return nil;
        [blobs addObject:[d subdataWithRange:NSMakeRange(at, len)]];
        at += len;
    }
    return json ? Substitute(json, blobs) : nil;
}

#pragma mark Calls

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
            once(nil, [NSError errorWithDomain:SFYTChannelErrorDomain code:SFYTChannelTimedOut
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"engine: no answer to %@ within %.0f s", method, timeout]}]);
        });
        [self flush];
    });
}

- (void)failAll:(NSError *)error {
    dispatch_async(_queue, ^{
        [self->_queued removeAllObjects];
        for (void (^f)(id, NSError *) in [self->_pending allValues]) f(nil, error);
    });
}

@end
