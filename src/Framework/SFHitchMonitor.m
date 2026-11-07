#import "SFHitchMonitor.h"
#import "SFCore.h"

// A watcher thread pings the main queue and measures how long each ping waits to run: the time a
// key press, an animation step or a frame would have waited too. (A run loop observer measuring
// wake-to-sleep counted idle time as busy - its 1-s "stalls" were idle in a sample, 2026-11-07.)
static const NSTimeInterval kHitch = 0.033;      // > 2 frames at 60 Hz: the micro-stutter the user sees
static const NSTimeInterval kPing = 0.050;       // between pings
static const NSTimeInterval kKeyWindow = 1.0;    // a stall this soon after a key press is "after" it

void SFHitchMonitorStart(void (^lastKey)(NSString **, NSTimeInterval *)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void (^key)(NSString **, NSTimeInterval *) = [lastKey copy];
        NSThread *t = [[NSThread alloc] initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            dispatch_semaphore_t ran = dispatch_semaphore_create(0);
            NSTimeInterval lastLog = 0;
            NSUInteger quiet = 0;   // stalls not logged since the last line (at most one line per second)
            while (YES) {
                NSTimeInterval sent = [NSDate timeIntervalSinceReferenceDate];
                dispatch_async(dispatch_get_main_queue(), ^{ dispatch_semaphore_signal(ran); });
                dispatch_semaphore_wait(ran, DISPATCH_TIME_FOREVER);
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate], waited = now - sent;
                if (waited >= kHitch) {
                    if (now - lastLog < 1) quiet++;
                    else {
                        __block NSString *name = nil; __block NSTimeInterval at = 0;
                        if (key) dispatch_sync(dispatch_get_main_queue(), ^{ key(&name, &at); });
                        NSString *after = name && now - at < waited + kKeyWindow ? [NSString stringWithFormat:@" after key %@", name] : @"";
                        SFLog(@"hitch: main thread blocked %.0f ms%@%@", waited * 1000, after,
                              quiet ? [NSString stringWithFormat:@" (+%lu more since the last line)", (unsigned long)quiet] : @"");
                        lastLog = now; quiet = 0;
                    }
                }
                usleep((useconds_t)(kPing * 1e6));
            }
        }] selector:@selector(start) object:nil];
        t.name = @"sofa.hitch-monitor";
        [t start];
    });
}
