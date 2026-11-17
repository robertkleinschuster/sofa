// sources: src/Apps/YouTube/SFYTPriority.m
// SFYTPriority (review 2026-11-17, H1/M1): whatever the order of requests, the last apply sets the
// state wanted now; and the real thing on a process group - background priority on and off.
#import "../../src/Apps/YouTube/SFYTPriority.h"
#import "SFCore.h"
#include <spawn.h>
#include <signal.h>
BOOL SFDevMode = NO;
extern char **environ;

static int fails;
static void expect(BOOL ok, NSString *what) { if (!ok) { fails++; printf("FAIL %s\n", what.UTF8String); } }
static int pri(pid_t p) {
    NSTask *t = [NSTask new]; t.launchPath = @"/bin/ps"; t.arguments = @[@"-o", @"pri=", @"-p", @(p).stringValue];
    NSPipe *o = [NSPipe pipe]; t.standardOutput = o; [t launch];
    NSData *d = [o.fileHandleForReading readDataToEndOfFile]; [t waitUntilExit];
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] intValue];
}

int main(void) {
    @autoreleasepool {
        NSMutableArray *applied = [NSMutableArray new];
        SFYTPriority *p = [[SFYTPriority alloc] initWithApply:^(BOOL bg) { usleep(arc4random_uniform(300)); @synchronized (applied) { [applied addObject:@(bg)]; } }];
        dispatch_apply(400, dispatch_get_global_queue(0, 0), ^(size_t i) { p.want = (i % 2) == 0; });
        p.want = YES; p.want = NO; p.want = YES;
        dispatch_sync(p.queue, ^{});
        expect([applied.lastObject isEqual:@YES], @"the last apply is the state wanted now (YES)");
        p.want = NO;
        dispatch_sync(p.queue, ^{});
        expect([applied.lastObject isEqual:@NO], @"and after waking: NO");
        [p reapply];
        dispatch_sync(p.queue, ^{});
        expect([applied.lastObject isEqual:@NO], @"reapply applies the current state");

        // a process group: background priority (PRI 4) and back
        pid_t c; posix_spawnattr_t at; posix_spawnattr_init(&at);
        posix_spawnattr_setflags(&at, POSIX_SPAWN_SETPGROUP); posix_spawnattr_setpgroup(&at, 0);
        char *argv[] = {"/bin/sleep", "20", NULL};
        expect(posix_spawn(&c, "/bin/sleep", NULL, &at, argv, environ) == 0, @"child in a group of its own");
        usleep(200000);
        int normal = pri(c);
        expect(SFYTSetGroupBackground(c, 0, YES) >= 1 && pri(c) == 4, @"background: PRI 4");
        expect(SFYTSetGroupBackground(c, 0, NO) >= 1 && pri(c) > 4, @"back to normal (above the background band; the exact value moves with the scheduler)"); (void)normal;
        expect(SFYTSetGroupBackground(0, 0, YES) == 0, @"no group: nothing");
        kill(c, SIGKILL);
    }
    if (!fails) printf("ytpriority ok\n");
    return fails ? 1 : 0;
}
