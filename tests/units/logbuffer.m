// sources:
// SFLog in memory: ordinary lines wait (no disk write per line), a failure goes out at once,
// SFLogFlush writes the rest, the delay can be set; nothing is lost or reordered.
#import "SFCore.h"
#include <signal.h>
#include <sys/wait.h>
BOOL SFDevMode = NO;

static int fails;
static void expect(BOOL ok, NSString *what) { if (!ok) { fails++; printf("FAIL %s\n", what.UTF8String); } }
static BOOL has(NSString *s, NSString *part) { return [s rangeOfString:part].location != NSNotFound; }

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "crash")) { SFLog(@"the line before the crash"); sleep(1); raise(SIGSEGV);   /* (the line reaches the buffer, not the file) */ return 0; }
    @autoreleasepool {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"logbuf-%d.log", getpid()]];
        setenv("SOFA_UNIT_LOG", path.fileSystemRepresentation, 1);   // the crashing child inherits it
        NSString *(^text)(void) = ^{ return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @""; };
        SFLog(@"line one");
        SFLog(@"line two");
        usleep(300000);
        expect(!has(text(), @"line one"), @"ordinary lines wait in memory");
        SFLog(@"open failed: something");
        usleep(300000);
        NSString *t = text();
        expect(has(t, @"line one") && has(t, @"line two") && has(t, @"open failed"), @"a failure writes everything waiting at once");
        expect([t rangeOfString:@"line one"].location < [t rangeOfString:@"open failed"].location, @"in order");
        SFLog(@"line three");
        SFLogFlush();
        expect(has(text(), @"line three"), @"SFLogFlush writes the rest");
        SFLogSetDelay(0.2);
        SFLog(@"line four");
        usleep(600000);
        expect(has(text(), @"line four"), @"after the delay the line is written by itself");
        for (int i = 0; i < 2000; i++) SFLog(@"bulk %d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", i);
        SFLogFlush();
        t = text();
        expect(has(t, @"bulk 0 ") && has(t, @"bulk 1999 "), @"a burst larger than the buffer: nothing lost");
        // the delay changing writes what waits (a pending 10-min flush must not hold lines after waking)
        SFLogSetDelay(600);
        SFLog(@"before the change");
        usleep(200000);
        expect(!has(text(), @"before the change"), @"long delay: waits");
        SFLogSetDelay(30);
        usleep(200000);
        expect(has(text(), @"before the change"), @"the delay changed: written at once");
        // a crash writes what waits (the crash handler): this test run again as a child that crashes
        NSTask *child = [NSTask new];
        child.launchPath = [NSProcessInfo processInfo].arguments[0];
        child.arguments = @[@"crash"];
        [child launch]; [child waitUntilExit];
        expect(child.terminationReason == NSTaskTerminationReasonUncaughtSignal && has(text(), @"the line before the crash"), @"a crash: the waiting line is in the file");
        unlink(path.fileSystemRepresentation);
    }
    if (!fails) printf("logbuffer ok\n");
    return fails ? 1 : 0;
}
