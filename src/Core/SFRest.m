#import "SFRest.h"
#import "SFCore.h"
#import "SFFanLink.h"
#import "SFSettings.h"
#import "SFVolume.h"
#import "SFPlayerScreen.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>

NSString *const SFRestDidChangeNotification = @"SFRestDidChangeNotification";

static const int kHintTTL = 90;               // three beats: the daemon falls back after that
// tests shorten them (dev instances: SOFA_REST_BEAT, SOFA_FAND_FRESH, SOFA_OFF_CHECK)
static NSTimeInterval Beat(void) { return SFDevSeconds(@"SOFA_REST_BEAT", 30); }        // hint heartbeat (each answered with the state)
static NSTimeInterval StateFresh(void) { return SFDevSeconds(@"SOFA_FAND_FRESH", 120); } // no answer for this long: level 0
static NSTimeInterval OffCheck(void) { return SFDevSeconds(@"SOFA_OFF_CHECK", 8); }      // "Ausschalten": did the screen go off?
// whether the screen is off; dev instances: never theirs (tests set a probe)
// CGDisplayIsAsleep alone missed it after an update relaunch with the screen off (2026-11-17: it said
// awake, the display wrangler stood at power state 0) - the wrangler's state counts too (4 on, 3 dim)
static BOOL WranglerOff(void) {
    io_registry_entry_t r = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (!r) return NO;
    CFTypeRef pm = IORegistryEntryCreateCFProperty(r, CFSTR("IOPowerManagement"), kCFAllocatorDefault, 0);
    IOObjectRelease(r);
    BOOL off = NO;
    if (pm && CFGetTypeID(pm) == CFDictionaryGetTypeID()) {
        CFNumberRef n = CFDictionaryGetValue(pm, CFSTR("CurrentPowerState"));
        int state = 4;
        if (n && CFGetTypeID(n) == CFNumberGetTypeID() && CFNumberGetValue(n, kCFNumberIntType, &state)) off = state < 3;
    }
    if (pm) CFRelease(pm);
    return off;
}
static BOOL RealDisplayAsleep(void) { return !SFDevMode && (CGDisplayIsAsleep(CGMainDisplayID()) || WranglerOff()); }
static BOOL (*gDisplayAsleep)(void) = RealDisplayAsleep;
void SFRestSetDisplayProbe(BOOL (*probe)(void)) { gDisplayAsleep = probe ?: RealDisplayAsleep; }

BOOL SFRestShouldRest(BOOL screensAsleep, BOOL switchedOff, BOOL playing) {
    return !playing && (screensAsleep || switchedOff);
}
NSString *SFRestContextFor(BOOL resting, BOOL playing) {
    return playing ? SFFanContextPlayback : resting ? SFFanContextRest : SFFanContextIdle;
}

static BOOL gStarted, gResting, gPlaying, gScreensAsleep, gSwitchedOff;
static NSInteger gLevel;
static NSUInteger gOffGeneration;      // a later switch-off or wake makes an earlier screen check moot
static NSTimeInterval gStateAt;        // when the daemon's last state arrived (Sofa's clock)
static NSDictionary *gState;
static NSString *gSentContext;
static NSTimer *gBeat;

@implementation SFRest

+ (BOOL)resting { return gResting; }
+ (NSInteger)thermalLevel { return gLevel; }
+ (BOOL)backgroundDeferred { return gLevel >= 1; }
+ (BOOL)nightStopEnabled { return SFNightStopEnabled(); }
+ (void)setNightStopEnabled:(BOOL)on { SFSetNightStopEnabled(on); [self changed]; }

+ (BOOL)isNight {
    NSInteger h = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
    return h >= 23 || h < 6;
}

+ (void)start {
    if (gStarted) return;
    gStarted = YES;
    NSNotificationCenter *ws = [[NSWorkspace sharedWorkspace] notificationCenter], *nc = [NSNotificationCenter defaultCenter];
    [ws addObserver:self selector:@selector(screensSlept:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [ws addObserver:self selector:@selector(screensWoke:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    [nc addObserver:self selector:@selector(playerChanged:) name:SFPlayerStateNotification object:nil];
    // launched while the screen is off (autostart, crash restart): resting from the start
    if (gDisplayAsleep()) gScreensAsleep = YES;
    gResting = SFRestShouldRest(gScreensAsleep, gSwitchedOff, gPlaying);
    SFFanStart(^(NSDictionary *s) { [self received:s]; });
    gBeat = [NSTimer scheduledTimerWithTimeInterval:Beat() target:self selector:@selector(beat) userInfo:nil repeats:YES];
    gBeat.tolerance = 5;   // lets macOS coalesce the wake-up with others
    [self beat];
    SFLog(@"rest: started (%@)", gResting ? @"resting" : @"awake");
}

+ (void)changed { [[NSNotificationCenter defaultCenter] postNotificationName:SFRestDidChangeNotification object:nil]; }

// every input changes one fact; whether Sofa rests follows from all of them (SFRestShouldRest)
+ (void)update:(NSString *)why {
    BOOL rest = SFRestShouldRest(gScreensAsleep, gSwitchedOff, gPlaying);
    if (rest != gResting) {
        gResting = rest;
        SFLog(@"rest: %@ (%@)", rest ? @"resting" : @"awake", why);
        [self changed];
    }
    [self hint];
}

+ (void)screensSlept:(NSNotification *)n { gScreensAsleep = YES; [self update:gPlaying ? @"screen off - playing on, not resting" : @"screen off"]; }
+ (void)screensWoke:(NSNotification *)n { gScreensAsleep = NO; gSwitchedOff = NO; gOffGeneration++; [self update:@"screen on"]; }

+ (void)noteSwitchedOff {
    gSwitchedOff = YES;
    NSUInteger gen = ++gOffGeneration;
    [self update:@"switched off"];
    if (SFDevMode && !SFDevEnv(@"SOFA_OFF_CHECK")) return;   // dev instances: the real screen is not theirs (their dev command wakes)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(OffCheck() * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != gOffGeneration || !gSwitchedOff || gDisplayAsleep()) return;
        gSwitchedOff = NO;
        [self update:@"the screen stayed on"];
    });
}

+ (void)noteKey {
    if (!gSwitchedOff && !gScreensAsleep) return;
    if (gDisplayAsleep()) return;   // the key wakes the screen: screensWoke follows
    gSwitchedOff = NO; gScreensAsleep = NO; gOffGeneration++;
    [self update:@"key"];
}

+ (void)playerChanged:(NSNotification *)n {
    SFPlayerScreen *p = n.object;
    BOOL playing = ![n.userInfo[@"closed"] boolValue] && [p respondsToSelector:@selector(isPaused)] && !p.isPaused;
    if (playing == gPlaying) return;
    gPlaying = playing;
    [self update:playing ? @"playing" : @"playback paused or ended"];
}

+ (void)hint {
    NSString *ctx = SFRestContextFor(gResting, gPlaying);
    float v = [SFVolume muted] ? 0 : [SFVolume volume];   // -1 not adjustable / -2 headphones: unknown
    SFFanSendHint(ctx, gPlaying ? v : -1, kHintTTL);
    if (![ctx isEqualToString:gSentContext]) { gSentContext = ctx; SFLog(@"rest: context %@", ctx); }
}

+ (void)received:(NSDictionary *)s {
    gState = s; gStateAt = [NSDate date].timeIntervalSince1970;
    [self setLevel:[s[@"level"] integerValue]];
}

// a missing answer keeps the last level until it is stale (the daemon restarting must not flip
// background work on and off - its own hysteresis stays intact)
+ (void)beat {
    [self hint];
    if (gStateAt && [NSDate date].timeIntervalSince1970 - gStateAt > StateFresh()) {
        gStateAt = 0; gState = nil; [self setLevel:0];
        SFFanCheckSocket();   // our socket path removed (a cleanup tool)? bound again
    }
}

+ (void)setLevel:(NSInteger)level {
    if (level == gLevel) return;
    SFLog(@"rest: thermal level %ld -> %ld (cpu %@ °C, gpu %@ °C, hdd %@ °C, psu %@ °C, %@)%@", (long)gLevel, (long)level,
          gState[@"cpu_c"] ?: @"?", gState[@"gpu_c"] ?: @"?", gState[@"hdd_c"] ?: @"?", gState[@"psu_c"] ?: @"?", gState[@"mode"] ?: @"?",
          gState ? @"" : @" - no answer from the fan daemon");
    gLevel = level;
    [self changed];
}
@end
