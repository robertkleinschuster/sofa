#import "SFVolume.h"
#import <CoreAudio/CoreAudio.h>
#import <stdatomic.h>

// CoreAudio calls wait on coreaudiod: while mpv opens the audio device they blocked the main thread
// (the lounge's volume report at a player start: 700 ms, hitch monitor 2026-11-07). Volume and mute
// are therefore kept here, read on the own queue and kept current by CoreAudio's change listeners
// (default output device, its volume controls and mute); the getters return the kept values and
// never block, the setters keep the new value at once and write it to the device on the queue.
//
// The volume is the device's own HAL controls (kAudioDevicePropertyVolumeScalar): the master element
// when the device has one, else the channels it prefers for stereo - what AudioToolbox's
// VirtualMasterVolume does internally. That service answered "unknown property" for every device
// here (2026-11-08: built-in output and AirPods alike, any process) - Sofa then took the built-in
// speakers for not adjustable and never set the AirPods' signal to full.

@implementation SFVolume

static dispatch_queue_t gQueue;
static _Atomic float gVolume = -1;   // -1: not adjustable (or not read yet); SFVolumeOnDevice: set on the headphones
static _Atomic int gMuted = 0;
static AudioDeviceID gDevice = kAudioObjectUnknown;   // on gQueue
static UInt32 gElements[2], gElementCount;            // on gQueue: the volume controls (elements) of gDevice
// Bluetooth headphones: on 10.9 their own volume is not synced with the Mac (the AirPods Max crown
// reports nothing, 2026-11-08) - the Mac's volume would only attenuate the signal before them, a
// second volume in front of theirs. Sofa sets it to full once and leaves the volume to the device.
static BOOL gOnDevice;   // on gQueue

static const AudioObjectPropertyAddress kDefaultOutput = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
static const AudioObjectPropertyAddress kMute = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};
static AudioObjectPropertyAddress VolumeOf(UInt32 element) {
    return (AudioObjectPropertyAddress){kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element};
}

// on gQueue: the elements whose volume is the device's volume - master, or the preferred stereo pair
static void findElements(AudioDeviceID dev) {
    gElementCount = 0;
    if (dev == kAudioObjectUnknown) return;
    Boolean settable = false;
    AudioObjectPropertyAddress master = VolumeOf(kAudioObjectPropertyElementMaster);
    if (AudioObjectHasProperty(dev, &master) && AudioObjectIsPropertySettable(dev, &master, &settable) == noErr && settable) {
        gElements[gElementCount++] = kAudioObjectPropertyElementMaster;
        return;
    }
    UInt32 pair[2] = {1, 2}, size = sizeof pair;
    AudioObjectPropertyAddress stereo = {kAudioDevicePropertyPreferredChannelsForStereo, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};
    AudioObjectGetPropertyData(dev, &stereo, 0, NULL, &size, pair);
    for (int i = 0; i < 2; i++) {
        AudioObjectPropertyAddress a = VolumeOf(pair[i]);
        settable = false;
        if (AudioObjectHasProperty(dev, &a) && AudioObjectIsPropertySettable(dev, &a, &settable) == noErr && settable) gElements[gElementCount++] = pair[i];
    }
}

// on gQueue: the device's volume = the loudest of its controls (a balance stays a balance)
static Float32 readVolume(void) {
    Float32 v = -1;
    for (UInt32 i = 0; i < gElementCount; i++) {
        Float32 x = 0; UInt32 size = sizeof x;
        AudioObjectPropertyAddress a = VolumeOf(gElements[i]);
        if (AudioObjectGetPropertyData(gDevice, &a, 0, NULL, &size, &x) == noErr) v = MAX(v, x);
    }
    return v;
}

static void writeVolume(Float32 x) {
    for (UInt32 i = 0; i < gElementCount; i++) {
        AudioObjectPropertyAddress a = VolumeOf(gElements[i]);
        AudioObjectSetPropertyData(gDevice, &a, 0, NULL, sizeof x, &x);
    }
}

// on gQueue: read the device's values into the kept ones
static void refresh(void) {
    Float32 v = gOnDevice ? SFVolumeOnDevice : readVolume();
    UInt32 m = 0, size = sizeof m;
    if (AudioObjectGetPropertyData(gDevice, &kMute, 0, NULL, &size, &m) != noErr) m = 0;
    atomic_store(&gVolume, v);
    atomic_store(&gMuted, m != 0);
}

// on gQueue: follow the current default output device
static void bind(void) {
    static AudioObjectPropertyListenerBlock listener;
    if (!listener) listener = ^(UInt32 n, const AudioObjectPropertyAddress *addr) { refresh(); };
    if (gDevice != kAudioObjectUnknown) {
        for (UInt32 i = 0; i < gElementCount; i++) { AudioObjectPropertyAddress a = VolumeOf(gElements[i]); AudioObjectRemovePropertyListenerBlock(gDevice, &a, gQueue, listener); }
        AudioObjectRemovePropertyListenerBlock(gDevice, &kMute, gQueue, listener);
    }
    AudioDeviceID dev = kAudioObjectUnknown; UInt32 size = sizeof dev;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &kDefaultOutput, 0, NULL, &size, &dev);
    gDevice = dev;
    findElements(dev);
    UInt32 transport = 0; size = sizeof transport;
    AudioObjectPropertyAddress t = {kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    gOnDevice = dev != kAudioObjectUnknown && AudioObjectGetPropertyData(dev, &t, 0, NULL, &size, &transport) == noErr
        && transport == kAudioDeviceTransportTypeBluetooth;
    if (dev != kAudioObjectUnknown) {
        for (UInt32 i = 0; i < gElementCount; i++) { AudioObjectPropertyAddress a = VolumeOf(gElements[i]); AudioObjectAddPropertyListenerBlock(dev, &a, gQueue, listener); }
        AudioObjectAddPropertyListenerBlock(dev, &kMute, gQueue, listener);
    }
    if (gOnDevice) {   // no attenuation before the headphones
        writeVolume(1);
        SFLog(@"volume: Bluetooth output - the Mac's volume at full (%u controls), the headphones set theirs", (unsigned)gElementCount);
    } else {
        SFLog(@"volume: output %u - %u volume control%@", (unsigned)dev, (unsigned)gElementCount, gElementCount == 1 ? @"" : @"s");
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
        writeVolume(x);
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
