#import "SFAudioOutput.h"
#import <CoreAudio/CoreAudio.h>

NSString *const SFAudioOutputChangedNotification = @"SFAudioOutputChanged";
NSString *const SFAudioOutputListChangedNotification = @"SFAudioOutputListChanged";

@interface SFAudioOutput ()
@property (nonatomic, readwrite) uint32_t deviceID;
@property (nonatomic, readwrite, copy) NSString *name, *uid;
@property (nonatomic, readwrite) BOOL bluetooth, current;
@end

@implementation SFAudioOutput

static dispatch_queue_t Queue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("sofa.audio-output", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static const AudioObjectPropertyAddress kDefault = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
static const AudioObjectPropertyAddress kDevices = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};

static AudioDeviceID defaultOutput(void) {
    AudioDeviceID d = kAudioObjectUnknown; UInt32 size = sizeof d;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &kDefault, 0, NULL, &size, &d) != noErr) return kAudioObjectUnknown;
    return d;
}

static NSString *stringProperty(AudioDeviceID d, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    CFStringRef s = NULL; UInt32 size = sizeof s;
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &size, &s) != noErr || !s) return nil;
    return CFBridgingRelease(s);
}

static BOOL hasOutputStreams(AudioDeviceID d) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};
    UInt32 size = 0;
    return AudioObjectGetPropertyDataSize(d, &a, 0, NULL, &size) == noErr && size > 0;
}

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &kDefault, Queue(), ^(UInt32 n, const AudioObjectPropertyAddress *addr) {
            NSString *name = stringProperty(defaultOutput(), kAudioObjectPropertyName);
            dispatch_async(dispatch_get_main_queue(), ^{
                SFLog(@"audio: output now %@", name ?: @"?");
                [[NSNotificationCenter defaultCenter] postNotificationName:SFAudioOutputChangedNotification object:nil];
            });
        });
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &kDevices, Queue(), ^(UInt32 n, const AudioObjectPropertyAddress *addr) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:SFAudioOutputListChangedNotification object:nil];
            });
        });
    });
}

+ (void)outputs:(void (^)(NSArray *))done {
    dispatch_async(Queue(), ^{
        AudioObjectPropertyAddress a = kDevices;
        UInt32 size = 0;
        NSMutableArray *out = [NSMutableArray new];
        if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) == noErr && size) {
            NSMutableData *ids = [NSMutableData dataWithLength:size];
            if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids.mutableBytes) == noErr) {
                AudioDeviceID cur = defaultOutput();
                const AudioDeviceID *d = ids.bytes;
                for (UInt32 i = 0; i < size / sizeof(AudioDeviceID); i++) {
                    if (!hasOutputStreams(d[i])) continue;
                    SFAudioOutput *o = [SFAudioOutput new];
                    o.deviceID = d[i];
                    o.name = stringProperty(d[i], kAudioObjectPropertyName) ?: @"Ausgang";
                    o.uid = stringProperty(d[i], kAudioDevicePropertyDeviceUID);
                    AudioObjectPropertyAddress t = {kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
                    UInt32 transport = 0, ts = sizeof transport;
                    AudioObjectGetPropertyData(d[i], &t, 0, NULL, &ts, &transport);
                    o.bluetooth = transport == kAudioDeviceTransportTypeBluetooth;
                    o.current = d[i] == cur;
                    if (o.current) [out insertObject:o atIndex:0]; else [out addObject:o];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(out); });
    });
}

+ (void)choose:(SFAudioOutput *)o done:(void (^)(BOOL))done {
    dispatch_async(Queue(), ^{
        AudioDeviceID d = o.deviceID;
        BOOL ok = AudioObjectSetPropertyData(kAudioObjectSystemObject, &kDefault, 0, NULL, sizeof d, &d) == noErr;
        SFLog(@"audio: choose %@ -> %@", o.name, ok ? @"ok" : @"failed");
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
    });
}

+ (void)waitForOutput:(NSString *)part timeout:(NSTimeInterval)timeout done:(void (^)(SFAudioOutput *))done {
    __block id obs = nil;
    __block BOOL over = NO;
    void (^finish)(SFAudioOutput *) = ^(SFAudioOutput *o) {
        if (over) return;
        over = YES;
        if (obs) [[NSNotificationCenter defaultCenter] removeObserver:obs];
        obs = nil;
        done(o);
    };
    void (^look)(void) = ^{
        [self outputs:^(NSArray *outputs) {
            for (SFAudioOutput *o in outputs)
                if ([o.uid rangeOfString:part options:NSCaseInsensitiveSearch].location != NSNotFound) { finish(o); return; }
        }];
    };
    obs = [[NSNotificationCenter defaultCenter] addObserverForName:SFAudioOutputListChangedNotification object:nil
                                                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { look(); }];
    look();   // there already
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(nil); });
}
@end
