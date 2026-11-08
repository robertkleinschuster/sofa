#import "SFVolume.h"
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioServices.h>
#import <stdatomic.h>

// CoreAudio calls wait on coreaudiod: while mpv opens the audio device they blocked the main thread
// (the lounge's volume report at a player start: 700 ms, hitch monitor 2026-11-07). Volume and mute
// are therefore kept here, read on the own queue and kept current by CoreAudio's change listeners
// (default output device, its volume and mute); the getters return the kept values and never
// block, the setters keep the new value at once and write it to the device on the queue.

@implementation SFVolume

static dispatch_queue_t gQueue;
static _Atomic float gVolume = -1;   // -1: not adjustable (or not read yet); SFVolumeOnDevice: set on the headphones
static _Atomic int gMuted = 0;
static AudioDeviceID gDevice = kAudioObjectUnknown;   // on gQueue
// Bluetooth headphones: on 10.9 their own volume is not synced with the Mac (the AirPods Max crown
// reports nothing, 2026-11-08) - the Mac's volume would only attenuate the signal before them, a
// second volume in front of theirs. Sofa sets it to full once and leaves the volume to the device.
static BOOL gOnDevice;   // on gQueue

static const AudioObjectPropertyAddress kDefaultOutput = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
static const AudioObjectPropertyAddress kVolume = {kAudioHardwareServiceDeviceProperty_VirtualMasterVolume, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};
static const AudioObjectPropertyAddress kMute = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};

// on gQueue: read the device's values into the kept ones
static void refresh(void) {
    Float32 v = -1; UInt32 size = sizeof v;
    if (gOnDevice) v = SFVolumeOnDevice;
    else if (!AudioHardwareServiceHasProperty(gDevice, &kVolume) || AudioHardwareServiceGetPropertyData(gDevice, &kVolume, 0, NULL, &size, &v) != noErr) v = -1;
    UInt32 m = 0; size = sizeof m;
    if (AudioObjectGetPropertyData(gDevice, &kMute, 0, NULL, &size, &m) != noErr) m = 0;
    atomic_store(&gVolume, v);
    atomic_store(&gMuted, m != 0);
}

// volume changes come through AudioHardwareService (a C callback on CoreAudio's thread)
static OSStatus volumeChanged(AudioObjectID obj, UInt32 n, const AudioObjectPropertyAddress *addr, void *ctx) {
    dispatch_async(gQueue, ^{ refresh(); });
    return noErr;
}

// on gQueue: follow the current default output device
static void bind(void) {
    static AudioObjectPropertyListenerBlock muteListener;
    if (!muteListener) muteListener = ^(UInt32 n, const AudioObjectPropertyAddress *addr) { refresh(); };
    if (gDevice != kAudioObjectUnknown) {
        AudioHardwareServiceRemovePropertyListener(gDevice, &kVolume, volumeChanged, NULL);
        AudioObjectRemovePropertyListenerBlock(gDevice, &kMute, gQueue, muteListener);
    }
    AudioDeviceID dev = kAudioObjectUnknown; UInt32 size = sizeof dev;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &kDefaultOutput, 0, NULL, &size, &dev);
    gDevice = dev;
    UInt32 transport = 0; size = sizeof transport;
    AudioObjectPropertyAddress t = {kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    gOnDevice = dev != kAudioObjectUnknown && AudioObjectGetPropertyData(dev, &t, 0, NULL, &size, &transport) == noErr
        && transport == kAudioDeviceTransportTypeBluetooth;
    if (dev != kAudioObjectUnknown) {
        AudioHardwareServiceAddPropertyListener(dev, &kVolume, volumeChanged, NULL);
        AudioObjectAddPropertyListenerBlock(dev, &kMute, gQueue, muteListener);
    }
    if (gOnDevice) {   // no attenuation before the headphones
        Float32 full = 1;
        if (AudioHardwareServiceHasProperty(dev, &kVolume)) AudioHardwareServiceSetPropertyData(dev, &kVolume, 0, NULL, sizeof full, &full);
        SFLog(@"volume: Bluetooth output - the Mac's volume at full, the headphones set theirs");
    }
    refresh();
}

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gQueue = dispatch_queue_create("sofa.volume", DISPATCH_QUEUE_SERIAL);
        dispatch_async(gQueue, ^{
            AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &kDefaultOutput, gQueue,
                                                ^(UInt32 n, const AudioObjectPropertyAddress *addr) { bind(); });
            bind();
        });
    });
}

+ (float)volume { [self start]; return atomic_load(&gVolume); }

+ (BOOL)muted { [self start]; return atomic_load(&gMuted) != 0; }

+ (void)setVolume:(float)v {
    [self start];
    Float32 x = MAX(0, MIN(1, v));
    if (atomic_load(&gVolume) < 0) return;   // not adjustable (or on the device)
    atomic_store(&gVolume, x);
    BOOL unmute = x > 0 && atomic_load(&gMuted);
    if (unmute) atomic_store(&gMuted, 0);
    dispatch_async(gQueue, ^{
        AudioHardwareServiceSetPropertyData(gDevice, &kVolume, 0, NULL, sizeof x, &x);
        if (unmute) { UInt32 m = 0; AudioObjectSetPropertyData(gDevice, &kMute, 0, NULL, sizeof m, &m); }
    });
}

+ (void)setMuted:(BOOL)mu {
    [self start];
    atomic_store(&gMuted, mu ? 1 : 0);
    dispatch_async(gQueue, ^{ UInt32 m = mu ? 1 : 0; AudioObjectSetPropertyData(gDevice, &kMute, 0, NULL, sizeof m, &m); });
}

+ (void)step:(int)dir {
    float v = [self volume];
    if (v < 0) return;   // not adjustable here (also: on the device)
    [self setVolume:roundf(v * 16 + dir) / 16];
}
@end
