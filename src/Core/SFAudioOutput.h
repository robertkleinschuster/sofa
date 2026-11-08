// SFAudioOutput - the Mac's audio outputs (CoreAudio devices with output streams) and which one plays
// the sound. Choosing one makes it the system's default output: the volume (SFVolume) and the player
// (ao-reload on SFAudioOutputChangedNotification) follow it - also when the system switches by itself
// (headphones disconnected: back to the speakers). CoreAudio waits on coreaudiod: every call runs on
// a queue of its own, results come on main.
#import "SFCore.h"

extern NSString *const SFAudioOutputChangedNotification;       // the default output changed (posted on main)
extern NSString *const SFAudioOutputListChangedNotification;   // an output came or went (posted on main)
// The current output took no audio, the sound went to another one: userInfo "from", "to" (names)
extern NSString *const SFAudioOutputFellBackNotification;

@interface SFAudioOutput : NSObject
@property (nonatomic, readonly) uint32_t deviceID;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *uid;       // stable across launches (to remember a choice)
@property (nonatomic, readonly) BOOL bluetooth;            // transport type Bluetooth (headphones, speakers)
@property (nonatomic, readonly) BOOL current;              // the default output when listed
@property (nonatomic, readonly) BOOL builtIn;              // the Mac's own speakers / headphone jack
+ (void)start;                                             // follow default-output changes; idempotent
+ (void)outputs:(void (^)(NSArray *outputs))done;          // SFAudioOutput, the current one first
+ (void)choose:(SFAudioOutput *)output done:(void (^)(BOOL ok))done;
// The output whose UID contains `part` (a Bluetooth device's address: its CoreAudio UID is
// "<address>:output"), as soon as it exists - nil after `timeout` seconds
+ (void)waitForOutput:(NSString *)part timeout:(NSTimeInterval)timeout done:(void (^)(SFAudioOutput *output))done;
// Does the output take audio? Started briefly with an IO callback of its own: a device that is
// there but plays nothing (Bluetooth headphones whose audio link hangs - "StartIO timeout",
// AirPods Max 2026-11-08) calls it back rarely or never. mpv's audio clock stands still on such a
// device: the video hangs with it.
+ (void)verify:(SFAudioOutput *)output done:(void (^)(BOOL plays))done;
// Check the current output; one that takes no audio is left for the built-in one
// (SFAudioOutputFellBackNotification). Also after every switch to a Bluetooth output, by itself.
+ (void)checkCurrent;
@end
