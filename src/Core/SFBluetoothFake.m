// SFFakeBluetoothRadio - a radio for dev tests (SOFA_FAKE_BLUETOOTH=1, dev instances only): the
// whole flow without headphones and without touching the real radio. One paired speaker that is
// off ("Testlautsprecher"); a search finds headphones in pairing mode ("Testkopfhörer", its name
// a moment later, like a real inquiry) and the speaker; pairing and connecting succeed. No sound
// output appears for them (no CoreAudio device) - the UI's "connected, no output" path.
#import "SFBluetooth.h"

@interface SFFakeBluetoothRadio : NSObject <SFBluetoothRadio>
@end

static NSString *const kSpeaker = @"0a-00-00-00-00-01", *const kPhones = @"0a-00-00-00-00-02";

@implementation SFFakeBluetoothRadio {
    NSMutableSet *_paired, *_connected;
    NSInteger _search;   // the running search's number (a stop or a new one ends the old)
}

- (instancetype)init {
    if ((self = [super init])) { _paired = [NSMutableSet setWithObject:kSpeaker]; _connected = [NSMutableSet new]; }
    return self;
}

- (SFBluetoothDevice *)device:(NSString *)a named:(NSString *)name {
    return [SFBluetoothDevice deviceWithAddress:a name:name paired:[_paired containsObject:a] connected:[_connected containsObject:a]];
}
static NSString *NameOf(NSString *a) { return [a isEqual:kSpeaker] ? @"Testlautsprecher" : @"Testkopfhörer"; }

static void After(double s, dispatch_block_t b) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), b); }

- (BOOL)poweredOn { return YES; }

- (NSArray *)pairedAudioDevices {
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *a in @[kPhones, kSpeaker]) if ([_paired containsObject:a]) [out addObject:[self device:a named:NameOf(a)]];
    return out;
}

- (void)connect:(NSString *)address done:(void (^)(BOOL))done {
    BOOL ok = [_paired containsObject:address];
    After(0.3, ^{ if (ok) [self->_connected addObject:address]; done(ok); });
}

- (void)disconnect:(NSString *)address { [_connected removeObject:address]; }

- (void)pair:(NSString *)address done:(void (^)(BOOL))done {
    After(0.3, ^{ [self->_paired addObject:address]; [self->_connected addObject:address]; done(YES); });
}

- (void)search:(void (^)(SFBluetoothDevice *))found done:(void (^)(void))done {
    NSInteger n = ++_search;
    After(0.3, ^{ if (n == self->_search) found([self device:kPhones named:nil]); });
    After(0.6, ^{ if (n == self->_search) found([self device:kPhones named:NameOf(kPhones)]); });
    After(0.8, ^{ if (n == self->_search) found([self device:kSpeaker named:NameOf(kSpeaker)]); });
    After(1.5, ^{ if (n == self->_search) { self->_search++; SFLog(@"bluetooth: search over (fake)"); done(); } });
}

- (void)stopSearch { _search++; }
@end
