// sources: src/Library/SFPrebufferReader.m src/Core/SFHTTPBudget.m src/Core/SFLocalHTTP.m src/Core/SFWebSocket.m
// flags: -Isrc/Library -I/opt/local/include -L/opt/local/lib -lmpv
// SFPrebufferReader: a cancelled request reads nothing; a local 180 s file (ffmpeg) is read
// bounded at the resume position; a stalled source gives up at once on cancel.
#import "SFPrebufferReader.h"
#import "SFLocalHTTP.h"
#include <math.h>
BOOL SFDevMode = NO;
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); fflush(stdout); if (!c) bad++; }

static NSString *Fixture(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"prebufferreader-%d.mp4", getpid()]];
    NSTask *t = [NSTask launchedTaskWithLaunchPath:@"/opt/local/bin/ffmpeg" arguments:@[
        @"-hide_banner", @"-loglevel", @"error", @"-y", @"-f", @"lavfi", @"-i", @"testsrc=size=320x180:rate=10",
        @"-f", @"lavfi", @"-i", @"sine=frequency=440", @"-t", @"180", @"-c:v", @"libx264", @"-preset", @"ultrafast",
        @"-c:a", @"aac", @"-movflags", @"+faststart", path]];
    [t waitUntilExit];
    return path;
}

int main(void) { @autoreleasepool {
    NSString *file = Fixture();
    NSURL *url = [NSURL fileURLWithPath:file];
    SFPrebufferRead *cancelled = [SFPrebufferRead new];
    cancelled.cancelled = YES;
    expect([[SFPrebufferReader readURL:url audio:nil position:70 request:cancelled][@"reason"] isEqual:@"cancelled"],
           "a cancelled request reads nothing");
    NSDictionary *b = [SFPrebufferReader readURL:url audio:nil position:70 request:[SFPrebufferRead new]];
    double ahead = [b[@"buffered"] doubleValue];
    expect([b[@"reason"] isEqual:@"bounded"] && fabs([b[@"position"] doubleValue] - 70) < 1 && ahead >= 8 && ahead <= 15,
           "a local file: bounded read-ahead (8-15 s) at the resume position");
    [[NSFileManager defaultManager] removeItemAtPath:file error:nil];

    // a source that answers its headers and then nothing: the cancel ends the read at once
    SFLocalHTTP *s = [[SFLocalHTTP alloc] initWithName:@"prebuffer-cancel-test" queue:dispatch_queue_create("prebuffer-cancel-test", DISPATCH_QUEUE_SERIAL)
                                                maxBody:0 handler:^(SFHTTPExchange *x) {
        x.onClose = ^{ (void)x; };   // explicit ownership until the reader's cancel closes the socket
        [x begin:200 headers:@{@"Content-Length": @"2097152", @"Content-Type": @"video/mp4"}];
    }];
    if (![s startPreferringPort:0]) { expect(NO, "the stalled source listens"); return 1; }
    SFPrebufferRead *request = [SFPrebufferRead new];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ request.cancelled = YES; });
    NSTimeInterval start = [NSDate timeIntervalSinceReferenceDate];
    NSURL *stalled = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/stalled.mp4", s.port]];
    NSDictionary *result = [SFPrebufferReader readURL:stalled audio:nil position:30 request:request];
    double elapsed = [NSDate timeIntervalSinceReferenceDate] - start;
    [s stop];
    printf("     cancelled after %.3f s\n", elapsed);
    expect([result[@"reason"] isEqual:@"cancelled"] && elapsed < 3, "a stalled media open ends on cancel");
    return bad ? 1 : 0;
} }
