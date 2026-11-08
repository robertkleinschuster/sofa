// SFBluetooth - Bluetooth audio devices (headphones, speakers) through IOBluetooth's public API:
// search (inquiry, audio devices only), pair, connect, disconnect. The system's pairing list is
// the only memory - Sofa keeps no list of its own: a paired device that is switched on comes back
// by itself, and macOS moves the sound to it and back to the speakers when it goes (SFAudioOutput
// follows both). Everything runs on main (IOBluetooth calls back on the main run loop).
// Dev instances with SOFA_FAKE_BLUETOOTH=1 talk to a fake radio instead (tests: SFBluetoothFake.m).
#import "SFCore.h"

@interface SFBluetoothDevice : NSObject
@property (nonatomic, readonly, copy) NSString *address;   // "00-11-22-33-44-55" (also in its CoreAudio output's UID)
@property (nonatomic, readonly, copy) NSString *name;      // nil while a search has not resolved it yet
@property (nonatomic, readonly) BOOL paired, connected;
+ (instancetype)deviceWithAddress:(NSString *)address name:(NSString *)name paired:(BOOL)paired connected:(BOOL)connected;
@end

// What a radio does (the real one: IOBluetooth; dev tests: a fake)
@protocol SFBluetoothRadio <NSObject>
- (BOOL)poweredOn;
- (NSArray *)pairedAudioDevices;
- (void)connect:(NSString *)address done:(void (^)(BOOL ok))done;
- (void)disconnect:(NSString *)address;
- (void)pair:(NSString *)address done:(void (^)(BOOL ok))done;
- (void)search:(void (^)(SFBluetoothDevice *device))found done:(void (^)(void))done;   // one search at a time
- (void)stopSearch;
@end

@interface SFBluetooth : NSObject
+ (BOOL)poweredOn;
+ (NSArray *)pairedAudioDevices;                                       // SFBluetoothDevice, most recently used first
+ (void)connect:(SFBluetoothDevice *)device done:(void (^)(BOOL ok))done;
+ (void)disconnect:(SFBluetoothDevice *)device;
+ (void)pair:(SFBluetoothDevice *)device done:(void (^)(BOOL ok))done;  // pairs and connects
// Audio devices in reach (~10 s): `found` per new or renamed device (the paired ones too), then `done`
+ (void)search:(void (^)(SFBluetoothDevice *device))found done:(void (^)(void))done;
+ (void)stopSearch;
@end
