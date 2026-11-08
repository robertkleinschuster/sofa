#import "SFAudioOutput.h"
#import <CoreAudio/CoreAudio.h>
#import <libkern/OSAtomic.h>

NSString *const SFAudioOutputChangedNotification = @"SFAudioOutputChanged";
NSString *const SFAudioOutputListChangedNotification = @"SFAudioOutputListChanged";
NSString *const SFAudioOutputFellBackNotification = @"SFAudioOutputFellBack";

@interface SFAudioOutput ()
@property (nonatomic, readwrite) uint32_t deviceID;
@property (nonatomic, readwrite, copy) NSString *name, *uid;
@property (nonatomic, readwrite) BOOL bluetooth, current, builtIn;
@end

@implementation SFAudioOutput

// The verify IO callback (one verify at a time: on its queue): counts the device's calls and signals
// the waiting verify once it has seen enough - the device's own sign that it takes audio
static const int32_t kPlaysAfter = 5;
static volatile int32_t gIOCalls;
static dispatch_semaphore_t gPlays;
static OSStatus verifyIO(AudioObjectID d, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *inTime,
                         AudioBufferList *out, const AudioTimeStamp *outTime, void *ctx) {
    for (UInt32 i = 0; i < out->mNumberBuffers; i++) memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);   // silence
    if (OSAtomicIncrement32(&gIOCalls) == kPlaysAfter) dispatch_semaphore_signal(gPlays);
    return noErr;
}

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
                [self checkCurrentIfBluetooth];
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
                    o.builtIn = transport == kAudioDeviceTransportTypeBuiltIn;
                    o.current = d[i] == cur;
                    if (o.current) [out insertObject:o atIndex:0]; else [out addObject:o];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(out); });
    });
}

+ (void)choose:(SFAudioOutput *)o done:(void (^)(BOOL))done {
    if (SFDevMode) {   // dev instances never move the real sound (like the volume: SFScreen volumeStep)
        SFLog(@"audio: choose %@ -> skipped (dev instance)", o.name);
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(NO); });
        return;
    }
    dispatch_async(Queue(), ^{
        AudioDeviceID d = o.deviceID;
        BOOL ok = AudioObjectSetPropertyData(kAudioObjectSystemObject, &kDefault, 0, NULL, sizeof d, &d) == noErr;
        SFLog(@"audio: choose %@ -> %@", o.name, ok ? @"ok" : @"failed");
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
    });
}

+ (void)waitForCurrent:(NSString *)part timeout:(NSTimeInterval)timeout done:(void (^)(SFAudioOutput *))done {
    __block id obs = nil;
    __block BOOL over = NO;
    void (^finish)(SFAudioOutput *) = ^(SFAudioOutput *o) {
        if (over) return;
        over = YES;
        if (obs) [[NSNotificationCenter defaultCenter] removeObserver:obs];
        obs = nil;
        done(o);
    };
    void (^look)(BOOL) = ^(BOOL last) {
        [self outputs:^(NSArray *outputs) {
            SFAudioOutput *cur = outputs.firstObject;
            if (cur.current && [cur.uid rangeOfString:part options:NSCaseInsensitiveSearch].location != NSNotFound) finish(cur);
            else if (last) finish(nil);
        }];
    };
    obs = [[NSNotificationCenter defaultCenter] addObserverForName:SFAudioOutputChangedNotification object:nil
                                                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { look(NO); }];
    look(NO);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ look(YES); });
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

// A healthy device calls back ~40-90 times a second (512-1024 frames at 44.1 kHz): the verdict comes
// with its 5th call (~0.1 s). No calls within 2 s is a device that takes no audio (the limit is
// only the net for that case). A hanging start (StartIO timeout) blocks AudioDeviceStart itself
// for seconds - on the verify queue, never on main.
+ (void)verify:(SFAudioOutput *)o done:(void (^)(BOOL))done {
    // a queue of its own: a device whose start hangs (15 s, AirPods Max right after connecting,
    // 2026-11-08) must not hold up listing and choosing outputs
    static dispatch_queue_t vq; static dispatch_once_t once;
    dispatch_once(&once, ^{ vq = dispatch_queue_create("sofa.audio-verify", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(vq, ^{
        AudioDeviceIOProcID proc = NULL;
        BOOL plays = NO;
        NSDate *t0 = [NSDate date];
        if (AudioDeviceCreateIOProcID(o.deviceID, verifyIO, NULL, &proc) == noErr) {
            gIOCalls = 0;
            gPlays = dispatch_semaphore_create(0);
            if (AudioDeviceStart(o.deviceID, proc) == noErr) {
                plays = dispatch_semaphore_wait(gPlays, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
                AudioDeviceStop(o.deviceID, proc);
            }
            AudioDeviceDestroyIOProcID(o.deviceID, proc);
        }
        SFLog(@"audio: %@ %@ (%d calls, %.1f s)", o.name, plays ? @"takes audio" : @"takes NO audio", (int)gIOCalls, -[t0 timeIntervalSinceNow]);
        dispatch_async(dispatch_get_main_queue(), ^{ done(plays); });
    });
}

// after a switch, once it has settled (1.5 s without another): a connecting headset switches the
// output several times while it comes up, and its first moments are no verdict
+ (void)checkCurrentIfBluetooth {
    static NSUInteger generation;
    NSUInteger n = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (n == generation) [self checkSettledIfBluetooth];
    });
}

+ (void)checkSettledIfBluetooth {
    [self outputs:^(NSArray *outputs) {
        SFAudioOutput *cur = outputs.firstObject;
        if (cur.current && cur.bluetooth) [self check:cur among:outputs];
    }];
}

+ (void)checkCurrent {
    [self outputs:^(NSArray *outputs) {
        SFAudioOutput *cur = outputs.firstObject;
        if (cur.current) [self check:cur among:outputs];
    }];
}

+ (void)check:(SFAudioOutput *)cur among:(NSArray *)outputs {
    if (SFDevMode) return;   // dev instances play into no device (SOFA_AUDIO_OUT) and never move the sound
    static BOOL checking;   // one check at a time (a switch and a stalled player may both ask)
    if (checking) return;
    checking = YES;
    [self verify:cur done:^(BOOL plays) {
        checking = NO;
        if (plays || cur.builtIn) return;   // the built-in output is the last resort: stays
        SFAudioOutput *to = nil;
        for (SFAudioOutput *o in outputs) if (o.builtIn) { to = o; break; }
        if (!to) return;
        [self choose:to done:^(BOOL ok) {
            if (!ok) return;
            SFLog(@"audio: %@ takes no audio - back to %@", cur.name, to.name);
            [[NSNotificationCenter defaultCenter] postNotificationName:SFAudioOutputFellBackNotification object:nil
                                                              userInfo:@{@"from": cur.name ?: @"?", @"to": to.name ?: @"?"}];
        }];
    }];
}
@end
