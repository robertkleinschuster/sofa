// SFAudioOutput - the Mac's audio outputs (CoreAudio devices with output streams) and which one plays
// the sound. Choosing one makes it the system's default output: the volume (SFVolume) and the player
// (ao-reload on SFAudioOutputChangedNotification) follow it - also when the system switches by itself
// (headphones disconnected: back to the speakers). CoreAudio waits on coreaudiod: every call runs on
// a queue of its own, results come on main.
#import "SFCore.h"

extern NSString *const SFAudioOutputChangedNotification;   // the default output changed (posted on main)

@interface SFAudioOutput : NSObject
@property (nonatomic, readonly) uint32_t deviceID;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *uid;       // stable across launches (to remember a choice)
@property (nonatomic, readonly) BOOL bluetooth;            // transport type Bluetooth (headphones, speakers)
@property (nonatomic, readonly) BOOL current;              // the default output when listed
+ (void)start;                                             // follow default-output changes; idempotent
+ (void)outputs:(void (^)(NSArray *outputs))done;          // SFAudioOutput, the current one first
+ (void)choose:(SFAudioOutput *)output done:(void (^)(BOOL ok))done;
@end
