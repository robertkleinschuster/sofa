// sources: src/Apps/YouTube/SFYTProcess.m
// flags: -Isrc/Apps/YouTube
// SFYTWatcher (the engine browser's hand-over): when Sofa is gone (its pipe end closed) the watched
// processes end after the grace, at once without one; a watcher ended within the grace (the next
// Sofa takes them over) ends nothing; a pid that runs another program is left alone; cancel ends
// nothing. Stand-ins for Firefox/Xvfb: copies of sleep named like them.
#import "SFYTProcess.h"
#include <signal.h>
#include <sys/wait.h>

BOOL SFDevMode = NO;   // main.m's, for SFCore.m

static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL %s (%s:%d)\n", msg, __FILE__, __LINE__); fails++; } else printf("ok   %s\n", msg); } while (0)

static NSString *gDir;
static int gLog;

static pid_t standIn(NSString *name) {
    NSString *path = [gDir stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) [[NSFileManager defaultManager] copyItemAtPath:@"/bin/sleep" toPath:path error:nil];
    return SFYTSpawn(path, @[@"60"], @{}, -1, gLog, -1);
}

// alive = not exited; reaps it once it has (the stand-ins are our children)
static BOOL alive(pid_t p) { return waitpid(p, NULL, WNOHANG) == 0; }

// true once `p` has ended, within `s` seconds
static BOOL endsWithin(pid_t p, double s) {
    for (double t = 0; t < s; t += 0.05) { if (!alive(p)) return YES; usleep(50000); }
    return !alive(p);
}

int main(void) { @autoreleasepool {
    gDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sofa-ytwatcher-%d", getpid()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:gDir withIntermediateDirectories:YES attributes:nil error:nil];
    gLog = open("/dev/null", O_WRONLY);

    pid_t ff = standIn(@"firefox"), xv = standIn(@"Xvfb");
    CHECK(ff > 0 && xv > 0, "stand-ins started");
    CHECK(SFYTProcessIs(ff, @"firefox") && SFYTProcessIs(xv, @"Xvfb"), "processes known by their executable");
    CHECK(!SFYTProcessIs(ff, @"Xvfb"), "another name is not the process");

    // Sofa gone, grace 1 s: still there for the grace, gone after it
    SFYTWatcher *w = [SFYTWatcher watch:@{@(ff): @"firefox", @(xv): @"Xvfb"} grace:1 log:gLog];
    CHECK(w && w.pid > 0, "watcher started");
    usleep(300000);   // the shell is at its read
    [w closeLifeline];
    usleep(500000);
    CHECK(alive(ff) && alive(xv), "within the grace both still run");
    CHECK(endsWithin(ff, 3) && endsWithin(xv, 3), "after the grace both are ended");

    // Sofa gone, the next one takes over within the grace: nothing is ended
    ff = standIn(@"firefox"); xv = standIn(@"Xvfb");
    w = [SFYTWatcher watch:@{@(ff): @"firefox", @(xv): @"Xvfb"} grace:1 log:gLog];
    usleep(300000);
    [w closeLifeline];
    usleep(300000);
    [SFYTWatcher endEarlier:w.pid];
    CHECK(endsWithin(w.pid, 2), "the earlier watcher is ended");
    usleep(1500000);
    CHECK(alive(ff) && alive(xv), "taken over: both still run after the grace");

    // without a grace: at once
    w = [SFYTWatcher watch:@{@(ff): @"firefox"} grace:0 log:gLog];
    usleep(300000);
    [w closeLifeline];
    CHECK(endsWithin(ff, 1), "no grace: ended at once");

    // a pid that runs another program: left alone
    w = [SFYTWatcher watch:@{@(xv): @"firefox"} grace:0 log:gLog];
    usleep(300000);
    [w closeLifeline];
    CHECK(endsWithin(w.pid, 2), "watcher done");
    CHECK(alive(xv), "a pid running another executable is not ended");

    // cancel: the watcher goes, nothing is ended
    w = [SFYTWatcher watch:@{@(xv): @"Xvfb"} grace:0 log:gLog];
    usleep(300000);
    pid_t wp = w.pid;
    [w cancel];
    usleep(500000);
    CHECK(kill(wp, 0) != 0, "cancelled watcher gone");
    CHECK(alive(xv), "cancel ends nothing");

    kill(xv, SIGKILL); waitpid(xv, NULL, 0);
    [[NSFileManager defaultManager] removeItemAtPath:gDir error:nil];
    if (fails) fprintf(stderr, "%d failure(s)\n", fails);
    return fails ? 1 : 0;
} }
