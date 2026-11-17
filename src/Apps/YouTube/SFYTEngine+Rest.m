// SFYTEngine (Rest) - the engine while Sofa rests (SFRest): its browser keeps running, quiet - every
// process at background priority (the kernel throttles CPU and disk), no focus preloads or
// prebuffer (SFRest), follows in batches (SFFollows). A restart is a fresh youtube.com page and
// BotGuard attestation, and many restarts made YouTube suspicious (NOTES 2026-11-07) - so the
// browser is only ended at night when the user chose "Nachts ganz ruhen" (Energie menu), and not
// while a download fills. Waking (a key, the screen) brings it back at once.
#import "SFYTEngine+Private.h"
#import "SFRest.h"
#import "SFLounge.h"
#import "SFDownloads.h"
#import "SFYTNight.h"

static BOOL gWatching, gNightStopped;
static NSTimer *gNightCheck;
static NSString *gRestoppedNight;   // the night it was ended a second time (SFYTNightKey)

@implementation SFYTEngine (Rest)

- (void)watchRest {
    if (gWatching || SFDevMode) return;   // dev instances: no real rest, their browsers are tests'
    gWatching = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(restChanged:) name:SFRestDidChangeNotification object:nil];
    [self restChanged:nil];
}

- (void)restChanged:(NSNotification *)n {
    BOOL rest = [SFRest resting];
    [self setBrowserBackground:rest];   // the wanted state, always (the browser applies it, also to a later one)
    [gNightCheck invalidate]; gNightCheck = nil;
    if (rest) {
        [self nightCheck];
        // the night begins or ends while resting: look again every half hour
        gNightCheck = [NSTimer scheduledTimerWithTimeInterval:1800 target:self selector:@selector(nightCheck) userInfo:nil repeats:YES];
        gNightCheck.tolerance = 300;
    } else [self nightWake:@"awake"];
}

- (void)nightCheck {
    BOOL want = [SFRest resting] && [SFRest nightStopEnabled] && [SFRest isNight] && ![SFDownloads shared].active.count;
    NSString *night = SFYTNightKey([NSDate date], nil);
    switch (SFYTNightDecide(want, gNightStopped, self.ready, [night isEqualToString:gRestoppedNight], ![SFRest isNight] || ![SFRest nightStopEnabled])) {
        case SFYTNightStop:
            // also a browser some use started again during the night - once (no start/stop cycle)
            if (gNightStopped) gRestoppedNight = night;
            gNightStopped = YES;
            SFLog(@"yt-engine: night rest - browser and phone connection end until the morning");
            [[SFLounge shared] stop];   // its polls would start the browser again (at most 1.5 s: its goodbye to a phone)
            [self restStop];            // the processes end in the background
            break;
        case SFYTNightWake: [self nightWake:@"morning"]; break;
        case SFYTNightNone: break;
    }
}

- (void)nightWake:(NSString *)why {
    if (!gNightStopped) return;
    gNightStopped = NO;
    SFLog(@"yt-engine: night rest over (%@) - starting the browser", why);
    [self start];
    [[SFLounge shared] start];
}
@end
