// Systemlautstärke (CoreAudio, Standard-Ausgabegerät) + globale Lautstärke-Anzeige.
#import "SFCore.h"

@interface SFVolume : NSObject
+ (float)volume;                 // 0..1, -1 = nicht regelbar
+ (void)setVolume:(float)v;
+ (BOOL)muted;
+ (void)setMuted:(BOOL)m;
+ (void)step:(int)dir;           // ±1 = 1/16 (wie macOS)
@end
