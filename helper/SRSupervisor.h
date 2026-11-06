// SRSupervisor: when the remote helper relaunches a Sofa that ended unexpectedly.
//
// Sofa removes its "running" marker on every planned exit (quit, update handover); a process that
// is gone while the marker is still there crashed (or was killed). launchd's autostart agent
// (KeepAlive SuccessfulExit=false) only covers a Sofa it launched itself at login - after an
// update or a remote button the helper launched it, and a crash left the TV dark until someone
// came (2026-11-06 12:36). The helper runs permanently, so it supervises:
//   * relaunch after `grace` seconds without a process (launchd may be relaunching it already),
//   * at most `maxRelaunches` within `window` seconds: a crash at launch must not loop - after
//     that it waits for a remote button (which still launches Sofa) or a normal run.
// Pure state machine, fed by the helper's 3 s tick (unit test: tests/units/supervisor.m).
#import <Foundation/Foundation.h>

@interface SRSupervisor : NSObject
@property (nonatomic) NSTimeInterval grace;        // default 10 s
@property (nonatomic) NSUInteger maxRelaunches;    // default 3
@property (nonatomic) NSTimeInterval window;       // default 600 s
@property (nonatomic, readonly) BOOL gaveUp;       // limit reached; cleared once Sofa runs again
// One tick. running: a real Sofa process exists; markerLeft: its "running" marker exists.
// YES = relaunch now (counted).
- (BOOL)shouldRelaunchAt:(NSDate *)now running:(BOOL)running markerLeft:(BOOL)markerLeft;
@end
