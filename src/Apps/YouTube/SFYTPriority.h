// SFYTPriority - the engine browser's processes at background priority while Sofa rests (SFRest),
// set in a way that cannot end up wrong: one serial queue applies the *wanted* state as it is when
// the queue gets to it (not the value asked for), so the last run always sets the current state
// whatever the order of requests (review 2026-11-17, H1); reapply brings later processes (content
// processes, a taken-over or restarted browser) to it (M1). The queue also orders the browser's
// background stops (SFYTBrowser).
#import <Foundation/Foundation.h>

@interface SFYTPriority : NSObject
// apply(bg) runs on the queue, with the wanted state read there
- (instancetype)initWithApply:(void (^)(BOOL bg))apply;
@property (atomic) BOOL want;            // setting it schedules an apply
@property (nonatomic, readonly) dispatch_queue_t queue;
- (void)reapply;                         // apply the wanted state again (asynchronous)
@end

// Every process of `group` (ps -g) and `extra` (the display) at background priority or back
// (PRIO_DARWIN_BG: the kernel throttles CPU and disk I/O; same user, reversible). Blocking (ps);
// the number of processes set.
NSUInteger SFYTSetGroupBackground(pid_t group, pid_t extra, BOOL bg);
// The processes of `group` plus `extra` (blocking, ps), and the priority for a list of them
NSArray *SFYTGroupPids(pid_t group, pid_t extra);
NSUInteger SFYTSetBackground(NSArray *pids, BOOL bg);
