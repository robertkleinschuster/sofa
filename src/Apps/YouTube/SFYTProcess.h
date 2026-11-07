// The engine browser's processes (SFYTBrowser): spawning them clean, ending them only while they
// still are ours, and the watcher that ends them when Sofa is gone.
#import <Foundation/Foundation.h>

// posix_spawn with only stdin (`in`, or /dev/null when < 0), stdout+stderr (`log`) and, if >= 0,
// `fd3` as fd 3; an own process group, default signals; `env` added to Sofa's environment minus
// what must not reach the browser. 0 when it could not start.
pid_t SFYTSpawn(NSString *path, NSArray *args, NSDictionary *env, int in, int log, int fd3);
// `pid` is alive and runs an executable called `name` (not a reused pid).
BOOL SFYTProcessIs(pid_t pid, NSString *name);
// Ends `pid` if it still is `name`: TERM, then KILL after 5 s. Blocking.
void SFYTEndProcess(pid_t pid, NSString *name);

// A shell reading a pipe only Sofa writes to. However Sofa ends - crash, kill -9, the update's
// _exit - the kernel closes Sofa's end, the read returns, and `grace` seconds later the shell ends
// the processes (each only if its pid still runs that executable). The grace lets the next Sofa
// adopt the running browser: it ends the earlier watcher (endEarlier:) and starts its own.
@interface SFYTWatcher : NSObject
// `processes`: pid -> executable name. nil when the shell could not start.
+ (instancetype)watch:(NSDictionary *)processes grace:(int)grace log:(int)log;
@property (nonatomic, readonly) pid_t pid;
// The watcher goes without ending anything (Sofa ends or keeps the processes itself).
- (void)cancel;
// A watcher an earlier Sofa left (its pid from the process record): ended, its processes stay.
+ (void)endEarlier:(pid_t)pid;
// Closes Sofa's end of the pipe as Sofa's end does - the grace starts (tests).
- (void)closeLifeline;
@end
