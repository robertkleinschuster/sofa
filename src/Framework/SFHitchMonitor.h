// SFHitchMonitor - main-thread stalls as numbers: every busy stretch of the main run loop longer
// than two frames goes to the log, with the key press it followed. Home-screen micro-stutter
// (user 2026-11-07) is found from these lines instead of by feel.
#import <Foundation/Foundation.h>

// Starts once (main thread). `lastKey` describes the most recent key press and its time.
void SFHitchMonitorStart(void (^lastKey)(NSString **name, NSTimeInterval *at));
