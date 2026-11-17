// sources: src/Core/SFRest.m src/Core/SFFanLink.m
// flags: -Isrc/Player -Isrc/Framework -Isrc/Library
// SFRest's state machine (review 2026-11-17): screen off/on, switch off, keys, playback before rest
// (a video playing on behind a dark screen is no rest), quick in/out, the context the daemon hears,
// and the thermal level from a mock daemon.
#import "../../src/Core/SFRest.h"
#import "SFCore.h"
#import "SFFanLink.h"
#import <AppKit/AppKit.h>
#include <sys/socket.h>
#include <sys/un.h>
BOOL SFDevMode = YES;

// fakes: what SFRest asks
NSString *const SFPlayerStateNotification = @"fixture-player";
static BOOL nightStop;
BOOL SFNightStopEnabled(void) { return nightStop; }
void SFSetNightStopEnabled(BOOL on) { nightStop = on; }
@interface SFVolume : NSObject @end
@implementation SFVolume
+ (BOOL)muted { return NO; }
+ (float)volume { return 0.4f; }
@end
@interface FakePlayer : NSObject
@property BOOL paused;
- (BOOL)isPaused;
@end
@implementation FakePlayer
- (BOOL)isPaused { return self.paused; }
@end

static int fails;
static void expect(BOOL ok, NSString *what) { if (!ok) { fails++; printf("FAIL %s\n", what.UTF8String); } }
static void spin(NSTimeInterval s) { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]]; }
static void screens(BOOL asleep) {
    [[[NSWorkspace sharedWorkspace] notificationCenter] postNotificationName:asleep ? NSWorkspaceScreensDidSleepNotification
                                                                            : NSWorkspaceScreensDidWakeNotification object:nil];
}
static FakePlayer *player;
static void play(BOOL playing) { player.paused = !playing; [[NSNotificationCenter defaultCenter] postNotificationName:SFPlayerStateNotification object:player]; }
static void closePlayer(void) { [[NSNotificationCenter defaultCenter] postNotificationName:SFPlayerStateNotification object:player userInfo:@{@"closed": @YES}]; }

int main(void) {
    @autoreleasepool {
        expect(!SFRestShouldRest(NO, NO, NO) && SFRestShouldRest(YES, NO, NO) && SFRestShouldRest(NO, YES, NO), @"rest: screen off or switched off");
        expect(!SFRestShouldRest(YES, NO, YES) && !SFRestShouldRest(NO, YES, YES), @"never while playing");
        expect([SFRestContextFor(YES, YES) isEqual:@"playback"] && [SFRestContextFor(YES, NO) isEqual:@"ruhe"] && [SFRestContextFor(NO, NO) isEqual:@"idle"],
               @"context: playback before rest before idle");

        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"rest-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("SOFA_FAND_DIR", dir.fileSystemRepresentation, 1);
        int d = socket(AF_UNIX, SOCK_DGRAM, 0);
        struct sockaddr_un a = {0}; a.sun_family = AF_UNIX;
        strcpy(a.sun_path, [dir stringByAppendingPathComponent:@"hint.sock"].fileSystemRepresentation);
        bind(d, (struct sockaddr *)&a, (socklen_t)SUN_LEN(&a));
        struct timeval tv = {0, 300000}; setsockopt(d, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        __block struct sockaddr_un sofa; __block socklen_t sl = 0;
        NSString *(^lastHint)(void) = ^NSString *{   // the newest context the mock daemon got
            NSString *ctx = nil; char buf[600]; ssize_t n;
            struct sockaddr_un f; socklen_t fl = sizeof f;
            while ((n = recvfrom(d, buf, sizeof buf, 0, (struct sockaddr *)&f, &fl)) > 0) {
                ctx = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buf length:(NSUInteger)n] options:0 error:nil][@"ctx"];
                sofa = f; sl = fl; fl = sizeof f;
            }
            return ctx;
        };
        __block int changes = 0;
        [[NSNotificationCenter defaultCenter] addObserverForName:SFRestDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) { changes++; }];
        player = [FakePlayer new];

        [SFRest start];
        spin(0.2);
        expect(![SFRest resting] && [lastHint() isEqual:@"idle"], @"start: awake, idle");
        screens(YES); spin(0.1);
        expect([SFRest resting] && [lastHint() isEqual:@"ruhe"], @"screen off: rest");
        screens(NO); spin(0.1);
        expect(![SFRest resting] && [lastHint() isEqual:@"idle"], @"screen on: awake");

        int before = changes;
        for (int i = 0; i < 25; i++) { screens(YES); screens(NO); }
        spin(0.3);
        expect(![SFRest resting] && changes - before == 50 && [lastHint() isEqual:@"idle"], @"quick in/out: ends awake, every edge told");

        play(YES); spin(0.1);
        expect([lastHint() isEqual:@"playback"], @"playing: playback");
        screens(YES); spin(0.1);
        expect(![SFRest resting] && [lastHint() isEqual:@"playback"], @"screen off while playing: no rest (M5)");
        play(NO); spin(0.1);
        expect([SFRest resting] && [lastHint() isEqual:@"ruhe"], @"paused behind the dark screen: rest");
        play(YES); spin(0.1);
        expect(![SFRest resting], @"playing again (phone): awake");
        closePlayer(); spin(0.1);
        expect([SFRest resting], @"closed behind the dark screen: rest");
        screens(NO); spin(0.1);
        expect(![SFRest resting], @"screen on: awake");

        [SFRest noteSwitchedOff]; spin(0.1);
        expect([SFRest resting], @"switched off: rest at once");
        [SFRest noteKey]; spin(0.1);
        expect(![SFRest resting], @"a key with the screen on: awake");
        [SFRest noteKey];
        expect(![SFRest resting], @"a key while awake: nothing");

        play(YES); spin(0.1);
        [SFRest noteSwitchedOff]; spin(0.1);
        expect(![SFRest resting], @"switched off while still playing: not yet");
        closePlayer(); spin(0.1);
        expect([SFRest resting] && [lastHint() isEqual:@"ruhe"], @"the player closed by switching off: rest");
        screens(NO); spin(0.1);

        // thermal level from the daemon's answer
        expect([SFRest thermalLevel] == 0 && ![SFRest backgroundDeferred], @"no daemon answer: level 0");
        expect(sl > 0, @"the mock daemon knows Sofa's address");
        const char *warm = "{\"v\":1,\"level\":1,\"cpu_c\":70}";
        sendto(d, warm, strlen(warm), 0, (struct sockaddr *)&sofa, sl);
        spin(0.3);
        expect([SFRest thermalLevel] == 1 && [SFRest backgroundDeferred], @"warm: background deferred");
        const char *junk = "{\"v\":1,\"level\":";
        sendto(d, junk, strlen(junk), 0, (struct sockaddr *)&sofa, sl);
        spin(0.3);
        expect([SFRest thermalLevel] == 1, @"a broken datagram keeps the last level (no flapping)");
        const char *cool = "{\"v\":1,\"level\":0}";
        sendto(d, cool, strlen(cool), 0, (struct sockaddr *)&sofa, sl);
        spin(0.3);
        expect([SFRest thermalLevel] == 0, @"cooled down");
        close(d);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    if (!fails) printf("rest ok\n");
    return fails ? 1 : 0;
}
