#import "SFVolume.h"
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioServices.h>

@implementation SFVolume

static AudioDeviceID outputDevice(void) {
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev);
    return dev;
}

+ (float)volume {
    AudioDeviceID d = outputDevice();
    Float32 v = -1; UInt32 size = sizeof v;
    AudioObjectPropertyAddress a = {kAudioHardwareServiceDeviceProperty_VirtualMasterVolume, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};
    if (!AudioHardwareServiceHasProperty(d, &a)) return -1;
    if (AudioHardwareServiceGetPropertyData(d, &a, 0, NULL, &size, &v) != noErr) return -1;
    return v;
}

+ (void)setVolume:(float)v {
    AudioDeviceID d = outputDevice();
    Float32 x = MAX(0, MIN(1, v));
    AudioObjectPropertyAddress a = {kAudioHardwareServiceDeviceProperty_VirtualMasterVolume, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};
    AudioHardwareServiceSetPropertyData(d, &a, 0, NULL, sizeof x, &x);
    if (x > 0 && [self muted]) [self setMuted:NO];
}

+ (BOOL)muted {
    AudioDeviceID d = outputDevice();
    UInt32 m = 0, size = sizeof m;
    AudioObjectPropertyAddress a = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &size, &m) != noErr) return NO;
    return m != 0;
}

+ (void)setMuted:(BOOL)mu {
    AudioDeviceID d = outputDevice();
    UInt32 m = mu ? 1 : 0;
    AudioObjectPropertyAddress a = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};
    AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof m, &m);
}

+ (void)step:(int)dir {
    float v = [self volume];
    if (v < 0) return;
    float n = roundf(v * 16 + dir) / 16;
    [self setVolume:n];
}
@end
