// System volume (CoreAudio, default output device) + global volume indicator.
#import "SFCore.h"

@interface SFVolume : NSObject
+ (void)start;                   // reads and follows the device in the background (at launch); idempotent
+ (float)volume;                 // 0..1, -1 = not adjustable
+ (void)setVolume:(float)v;
+ (BOOL)muted;
+ (void)setMuted:(BOOL)m;
+ (void)step:(int)dir;           // ±1 = 1/16 (like macOS)
@end
