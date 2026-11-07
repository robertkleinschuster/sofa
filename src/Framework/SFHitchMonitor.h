// SFHitchMonitor - main-thread stalls as numbers: whenever the main queue makes work wait longer
// than two frames, the log says so, with the key press it followed and the Sofa functions the
// main thread was in meanwhile (sampled from its stack). Home-screen micro-stutter
// (user 2026-11-07) is found from these lines instead of by feel.
#import <Foundation/Foundation.h>

// Starts once (main thread). `lastKey` describes the most recent key press and its time.
void SFHitchMonitorStart(void (^lastKey)(NSString **name, NSTimeInterval *at));
