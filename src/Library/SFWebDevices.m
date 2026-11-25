#import "SFWebDevices.h"
#import "SFStore.h"
#import "SFJSON.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/SecRandom.h>

NSString *const SFWebDevicesDidChangeNotification = @"SFWebDevicesDidChange";

static const NSTimeInterval kCodeLife = 300;
static const NSUInteger kTriesPerCode = 3;
static const NSUInteger kWrongPerMinute = 10;
static const NSTimeInterval kSeenEvery = 600;   // "last seen" is written at most this often per device
static const NSUInteger kMaxName = 60;

@implementation SFWebDevice
@end

static NSString *Hex(const uint8_t *b, size_t n) {
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static NSString *RandomHex(size_t bytes) {
    uint8_t b[64];
    if (bytes > sizeof b || SecRandomCopyBytes(kSecRandomDefault, bytes, b) != 0) return nil;
    return Hex(b, bytes);
}

static NSString *TokenHash(NSString *token) {
    NSData *d = [token dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    return Hex(h, sizeof h);
}

// 6 digits, uniformly (rejection sampling over 20 random bits)
static NSString *NewCode(void) {
    for (;;) {
        uint32_t v = 0;
        if (SecRandomCopyBytes(kSecRandomDefault, sizeof v, (uint8_t *)&v) != 0) return nil;
        v &= 0xFFFFF;
        if (v < 1000000) return [NSString stringWithFormat:@"%06u", v];
    }
}

@implementation SFWebDevices {
    dispatch_queue_t _q;                 // devices, code, counters
    NSMutableDictionary *_byHash;        // token hash -> SFWebDevice
    NSUInteger _triesLeft;
    NSMutableArray *_wrong;              // times of wrong entries (the last minute)
    NSTimer *_renew;
}

+ (instancetype)shared {
    static SFWebDevices *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SFWebDevices new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("sofa.web-devices", DISPATCH_QUEUE_SERIAL);
        _byHash = [NSMutableDictionary new];
        _wrong = [NSMutableArray new];
        for (NSDictionary *r in [[SFStore shared] rows:@"SELECT id, name, token, paired, seen FROM web_devices" args:nil]) {
            SFWebDevice *d = [SFWebDevice new];
            d.identifier = r[@"id"]; d.name = r[@"name"];
            d.paired = [r[@"paired"] doubleValue]; d.seen = [nn(r[@"seen"]) doubleValue];
            if (d.identifier && r[@"token"]) _byHash[r[@"token"]] = d;
        }
    }
    return self;
}

- (NSArray *)devices {
    __block NSArray *out;
    dispatch_sync(_q, ^{
        out = [self->_byHash.allValues sortedArrayUsingComparator:^NSComparisonResult(SFWebDevice *a, SFWebDevice *b) {
            return a.paired > b.paired ? NSOrderedAscending : a.paired < b.paired ? NSOrderedDescending : NSOrderedSame;
        }];
    });
    return out;
}

static void Changed(void) {
    SFMain(^{ [[NSNotificationCenter defaultCenter] postNotificationName:SFWebDevicesDidChangeNotification object:nil]; });
}

#pragma mark Pairing window

- (void)openPairing {
    [self newCode];
    [_renew invalidate];
    _renew = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(renewIfDue) userInfo:nil repeats:YES];
}

- (void)closePairing {
    [_renew invalidate]; _renew = nil;
    dispatch_sync(_q, ^{ self->_pairingCode = nil; self->_pairingCodeExpires = nil; });
    Changed();
}

- (void)renewIfDue {
    __block BOOL due;
    dispatch_sync(_q, ^{ due = self->_pairingCode && [self->_pairingCodeExpires timeIntervalSinceNow] <= 0; });
    if (due) [self newCode];
}

- (void)newCode {
    dispatch_sync(_q, ^{ [self newCodeOnQueue]; });
    Changed();
}

- (void)newCodeOnQueue {
    _pairingCode = NewCode();
    _pairingCodeExpires = [NSDate dateWithTimeIntervalSinceNow:kCodeLife];
    _triesLeft = kTriesPerCode;
}

#pragma mark Devices

- (NSDictionary *)pairWithCode:(NSString *)code name:(NSString *)name status:(NSInteger *)status {
    __block NSDictionary *out = nil;
    __block NSInteger st = 403;
    __block BOOL changed = NO;
    NSString *given = [code stringByReplacingOccurrencesOfString:@" " withString:@""];
    dispatch_sync(_q, ^{
        NSDate *now = [NSDate date];
        while (self->_wrong.count && [now timeIntervalSinceDate:self->_wrong[0]] > 60) [self->_wrong removeObjectAtIndex:0];
        if (self->_wrong.count >= kWrongPerMinute) { st = 429; return; }
        if (!self->_pairingCode || [self->_pairingCodeExpires timeIntervalSinceNow] <= 0) { st = 410; return; }
        // compared in constant time: the code is the secret here
        NSData *a = [given dataUsingEncoding:NSUTF8StringEncoding], *b = [self->_pairingCode dataUsingEncoding:NSUTF8StringEncoding];
        BOOL same = a.length == b.length;
        uint8_t diff = 0;
        for (NSUInteger i = 0; same && i < a.length; i++) diff |= ((const uint8_t *)a.bytes)[i] ^ ((const uint8_t *)b.bytes)[i];
        if (!same || diff) {
            [self->_wrong addObject:now];
            if (--self->_triesLeft == 0) { [self newCodeOnQueue]; changed = YES; SFLog(@"web: pairing code replaced after %lu wrong entries", (unsigned long)kTriesPerCode); }
            st = 403;
            return;
        }
        NSString *token = RandomHex(32), *ident = RandomHex(8);
        if (!token || !ident) { st = 500; return; }
        SFWebDevice *d = [SFWebDevice new];
        d.identifier = ident;
        NSString *n = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        d.name = n.length ? (n.length > kMaxName ? [n substringToIndex:kMaxName] : n) : @"Browser";
        d.paired = now.timeIntervalSince1970;
        NSString *h = TokenHash(token);
        self->_byHash[h] = d;
        [[SFStore shared] run:@"INSERT INTO web_devices (id, name, token, paired) VALUES (?, ?, ?, ?)" args:@[ident, d.name, h, @(d.paired)]];
        [self newCodeOnQueue];   // a code pairs once
        changed = YES;
        out = @{@"token": token, @"device": ident, @"name": d.name};
        st = 200;
        SFLog(@"web: paired device %@ (%@)", ident, d.name);
    });
    if (changed) Changed();
    if (status) *status = st;
    return out;
}

- (NSString *)deviceForToken:(NSString *)token {
    if (token.length != 64) return nil;
    NSString *h = TokenHash(token);
    __block NSString *ident = nil;
    dispatch_sync(_q, ^{
        SFWebDevice *d = self->_byHash[h];
        if (!d) return;
        ident = d.identifier;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - d.seen > kSeenEvery) {
            d.seen = now;
            [[SFStore shared] run:@"UPDATE web_devices SET seen = ? WHERE id = ?" args:@[@(now), ident]];
        }
    });
    return ident;
}

- (void)remove:(NSString *)identifier {
    __block BOOL gone = NO;
    dispatch_sync(_q, ^{
        for (NSString *h in self->_byHash.allKeys)
            if ([[self->_byHash[h] identifier] isEqualToString:identifier]) { [self->_byHash removeObjectForKey:h]; gone = YES; }
    });
    if (!gone) return;
    [[SFStore shared] run:@"DELETE FROM web_devices WHERE id = ?" args:@[identifier]];
    SFLog(@"web: device %@ removed", identifier);
    Changed();
}

- (void)removeAll {
    dispatch_sync(_q, ^{ [self->_byHash removeAllObjects]; });
    [[SFStore shared] run:@"DELETE FROM web_devices" args:@[]];
    SFLog(@"web: every device removed");
    Changed();
}
@end
