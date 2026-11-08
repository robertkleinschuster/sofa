#import "SFBluetooth.h"
#import <IOBluetooth/IOBluetooth.h>

@implementation SFBluetoothDevice
+ (instancetype)deviceWithAddress:(NSString *)address name:(NSString *)name paired:(BOOL)paired connected:(BOOL)connected {
    SFBluetoothDevice *d = [self new];
    d->_address = [address copy]; d->_name = [name copy]; d->_paired = paired; d->_connected = connected;
    return d;
}
@end

#pragma mark - The real radio (IOBluetooth)

// A device's name as it is: IOBluetooth (10.9) hands a name from a search over as Latin-1 although
// Bluetooth names are UTF-8 ("AirPods Max ð\u009f\u008e§ ..." for "AirPods Max 🎧 ..."). Its
// Latin-1 bytes decoded as UTF-8 give the real name; a genuine Latin-1 name ("Café") is no valid
// UTF-8 and stays as it is.
NSString *SFBluetoothName(NSString *name) {
    NSData *bytes = [name dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:NO];
    NSString *utf8 = bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
    return utf8.length ? utf8 : name;
}

static SFBluetoothDevice *Wrap(IOBluetoothDevice *d) {
    return [SFBluetoothDevice deviceWithAddress:d.addressString name:SFBluetoothName(d.name) paired:d.isPaired connected:d.isConnected];
}

// One asynchronous IOBluetooth operation: the target of its callbacks, alive until it ends
@interface SFBTOperation : NSObject
@property (nonatomic, copy) void (^done)(BOOL ok);
@property (nonatomic, strong) IOBluetoothDevicePair *pairing;
@end

static NSMutableSet *gRunning;   // the operations in flight (IOBluetooth's delegates and targets are not retained)

@implementation SFBTOperation
// An operation ends after `limit` seconds at the latest: a device that never answers (switched off
// mid-way, out of reach) must not leave the caller waiting for good
+ (instancetype)operation:(void (^)(BOOL))done limit:(NSTimeInterval)limit {
    SFBTOperation *o = [self new];
    o.done = done;
    if (!gRunning) gRunning = [NSMutableSet new];
    [gRunning addObject:o];
    __weak SFBTOperation *wo = o;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SFBTOperation *x = wo;
        if (x.done) { SFLog(@"bluetooth: no answer after %.0f s", limit); [x.pairing stop]; [x end:NO]; }
    });
    return o;
}
- (void)end:(BOOL)ok {
    void (^d)(BOOL) = self.done;
    self.done = nil;
    self.pairing.delegate = nil;
    [gRunning removeObject:self];
    if (d) d(ok);
}
// openConnection:
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status { [self end:status == kIOReturnSuccess]; }
// pairing: a legacy device (most headphones) asks for a PIN, by convention 0000; a Simple Secure
// Pairing one for a numeric comparison - headphones have no display, so the answer is yes
- (void)devicePairingPINCodeRequest:(id)sender {
    BluetoothPINCode pin = {{'0', '0', '0', '0'}};
    [(IOBluetoothDevicePair *)sender replyPINCode:4 PINCode:&pin];
}
- (void)devicePairingUserConfirmationRequest:(id)sender numericValue:(BluetoothNumericValue)v {
    [(IOBluetoothDevicePair *)sender replyUserConfirmation:YES];
}
- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
    IOBluetoothDevice *d = [(IOBluetoothDevicePair *)sender device];
    SFLog(@"bluetooth: pairing %@ finished (0x%x)", d.addressString, error);
    if (error != kIOReturnSuccess) { [self end:NO]; return; }
    // the services (audio sink, remote control) make it a sound output - then the connection
    if ([d performSDPQuery:self] != kIOReturnSuccess) [self sdpQueryComplete:d status:kIOReturnError];
}
- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    if (device.isConnected) { [self end:YES]; return; }
    if ([device openConnection:self] != kIOReturnSuccess) [self end:NO];
}
@end

@interface SFIOBluetoothRadio : NSObject <SFBluetoothRadio>
@end

@implementation SFIOBluetoothRadio {
    IOBluetoothDeviceInquiry *_inquiry;
    void (^_found)(SFBluetoothDevice *);
    void (^_done)(void);
}

- (BOOL)poweredOn { return [IOBluetoothHostController defaultController].powerState == kBluetoothHCIPowerStateON; }

- (NSArray *)pairedAudioDevices {
    NSMutableArray *audio = [NSMutableArray new];
    for (IOBluetoothDevice *d in [IOBluetoothDevice pairedDevices])
        if (d.deviceClassMajor == kBluetoothDeviceClassMajorAudio) [audio addObject:d];
    [audio sortUsingComparator:^NSComparisonResult(IOBluetoothDevice *a, IOBluetoothDevice *b) {
        return [(b.recentAccessDate ?: [NSDate distantPast]) compare:(a.recentAccessDate ?: [NSDate distantPast])];
    }];
    NSMutableArray *out = [NSMutableArray new];
    for (IOBluetoothDevice *d in audio) [out addObject:Wrap(d)];
    return out;
}

- (void)connect:(NSString *)address done:(void (^)(BOOL))done {
    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:address];
    if (d.isConnected) { done(YES); return; }
    SFBTOperation *op = [SFBTOperation operation:done limit:20];   // paging alone may take ~10 s
    if (!d || [d openConnection:op] != kIOReturnSuccess) [op end:NO];
}

- (void)disconnect:(NSString *)address { [[IOBluetoothDevice deviceWithAddressString:address] closeConnection]; }

- (void)pair:(NSString *)address done:(void (^)(BOOL))done {
    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:address];
    SFBTOperation *op = [SFBTOperation operation:done limit:60];   // pairing, services, connection
    op.pairing = d ? [IOBluetoothDevicePair pairWithDevice:d] : nil;
    op.pairing.delegate = op;
    if (!op.pairing || [op.pairing start] != kIOReturnSuccess) [op end:NO];
}

- (void)search:(void (^)(SFBluetoothDevice *))found done:(void (^)(void))done {
    [self stopSearch];
    _found = [found copy]; _done = [done copy];
    _inquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
    _inquiry.inquiryLength = 10;
    _inquiry.updateNewDeviceNames = YES;
    [_inquiry setSearchCriteria:kBluetoothServiceClassMajorAny majorDeviceClass:kBluetoothDeviceClassMajorAudio minorDeviceClass:kBluetoothDeviceClassMinorAny];
    if ([_inquiry start] != kIOReturnSuccess) [self deviceInquiryComplete:_inquiry error:kIOReturnError aborted:NO];
}

- (void)stopSearch {
    IOBluetoothDeviceInquiry *i = _inquiry;
    _inquiry = nil; _found = nil; _done = nil;
    i.delegate = nil;
    [i stop];
}

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender device:(IOBluetoothDevice *)device {
    if (sender == _inquiry && _found) _found(Wrap(device));
}
- (void)deviceInquiryDeviceNameUpdated:(IOBluetoothDeviceInquiry *)sender device:(IOBluetoothDevice *)device devicesRemaining:(uint32_t)n {
    if (sender == _inquiry && _found) _found(Wrap(device));
}
- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender error:(IOReturn)error aborted:(BOOL)aborted {
    if (sender != _inquiry) return;
    void (^d)(void) = _done;
    _inquiry.delegate = nil; _inquiry = nil; _found = nil; _done = nil;
    SFLog(@"bluetooth: search over (0x%x%@)", error, aborted ? @", aborted" : @"");
    if (d) d();
}
@end

#pragma mark - Facade

@interface SFFakeBluetoothRadio : NSObject <SFBluetoothRadio>   // SFBluetoothFake.m
@end

static id<SFBluetoothRadio> Radio(void) {
    static id<SFBluetoothRadio> r; static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL fake = SFDevMode && getenv("SOFA_FAKE_BLUETOOTH");
        r = fake ? [SFFakeBluetoothRadio new] : [SFIOBluetoothRadio new];
        if (fake) SFLog(@"bluetooth: fake radio (SOFA_FAKE_BLUETOOTH)");
    });
    return r;
}

static NSString *Label(SFBluetoothDevice *d) { return d.name.length ? d.name : d.address; }

@implementation SFBluetooth
+ (BOOL)poweredOn { return [Radio() poweredOn]; }
+ (NSArray *)pairedAudioDevices { return [Radio() pairedAudioDevices]; }

+ (void)connect:(SFBluetoothDevice *)device done:(void (^)(BOOL))done {
    SFLog(@"bluetooth: connect %@", Label(device));
    [Radio() connect:device.address done:^(BOOL ok) {
        SFLog(@"bluetooth: connect %@ -> %@", Label(device), ok ? @"ok" : @"failed");
        if (done) done(ok);
    }];
}

+ (void)disconnect:(SFBluetoothDevice *)device {
    SFLog(@"bluetooth: disconnect %@", Label(device));
    [Radio() disconnect:device.address];
}

+ (void)pair:(SFBluetoothDevice *)device done:(void (^)(BOOL))done {
    SFLog(@"bluetooth: pair %@", Label(device));
    [Radio() pair:device.address done:^(BOOL ok) {
        SFLog(@"bluetooth: pair %@ -> %@", Label(device), ok ? @"ok" : @"failed");
        if (done) done(ok);
    }];
}

+ (void)search:(void (^)(SFBluetoothDevice *))found done:(void (^)(void))done {
    SFLog(@"bluetooth: search");
    [Radio() search:found done:done];
}
+ (void)stopSearch { [Radio() stopSearch]; }
@end
