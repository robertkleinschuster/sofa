// SFRest - Sofa at rest and Sofa warm (user 2026-11-17: as efficient as possible, never system
// sleep). One place that knows
//  - whether Sofa rests: the screen is off ("Ausschalten", the sleep timer, or macOS' display
//    sleep) and nothing plays (a video playing on behind a dark screen is not rest). Resting, nothing renders or polls, no prebuffer or focus preload runs, follows come in
//    batches (SFRefreshBatchAfter: about every 2 h by day, 4-6 h by night), the engine's processes
//    run at background priority. A remote key wakes the screen: everything is there at once.
//  - the thermal level from the fan daemon (SFFanLink): 1 warm = background work waits (prebuffer,
//    focus preloads, follows/Home refreshes, decorative animations), 2 hot = also no new download,
//    stricter engine memory limits, 3 critical = also new videos at most 720p.
// And it tells the daemon what Sofa does (playback with its volume, idle, rest) - fire and forget,
// renewed every 30 s; the daemon answers with its state (SFFanLink). Main thread.
#import <Foundation/Foundation.h>

// rest entered or left, thermal level changed (main thread)
extern NSString *const SFRestDidChangeNotification;

@interface SFRest : NSObject
+ (void)start;                       // at launch; idempotent
+ (BOOL)resting;
+ (NSInteger)thermalLevel;           // 0..3; 0 without the daemon
+ (BOOL)backgroundDeferred;          // thermal level >= 1: background work waits
// "Ausschalten"/sleep timer: rest now (the screen follows); left again when the screen wakes or,
// if it did not go off, at the next key
+ (void)noteSwitchedOff;
+ (void)noteKey;                     // a remote key: wake from a rest whose screen stayed on
// setting (Energie menu, default off): apps may end their background services at night while
// resting - fewer restarts are fewer bot checks, so off unless the user wants it
+ (BOOL)nightStopEnabled;
+ (void)setNightStopEnabled:(BOOL)on;
+ (BOOL)isNight;                     // 23-6 h local time
@end

// pure (tests): the rest decision and the context the daemon hears - playback before rest
BOOL SFRestShouldRest(BOOL screensAsleep, BOOL switchedOff, BOOL playing);
NSString *SFRestContextFor(BOOL resting, BOOL playing);
