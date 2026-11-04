#import "SFPower.h"
#import "SFScreen.h"
#import "SFMenuScreen.h"
#import "SFStore.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>

NSString *const SFPowerWillTurnOffNotification = @"SFPowerWillTurnOffNotification";

static NSTimer *gSleepTimer, *gWarnTimer;
static NSDate *gFireDate;
static __weak SFNavigator *gNav;

@implementation SFPower

+ (void)announceOff {
    [[NSNotificationCenter defaultCenter] postNotificationName:SFPowerWillTurnOffNotification object:nil];
    [[SFStore shared] flush];
}

+ (void)displayOff {
    [self announceOff];
    if (SFDevMode) { SFLog(@"power: (dev) display off simulated"); [gNav toast:@"(Dev) Bildschirm aus"]; return; }
    SFLog(@"power: display off");
    // Like "pmset displaysleepnow": send the IODisplayWrangler into the idle state
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        io_registry_entry_t r = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler");
        if (r) {
            kern_return_t kr = IORegistryEntrySetCFProperty(r, CFSTR("IORequestIdle"), kCFBooleanTrue);
            IOObjectRelease(r);
            if (kr == KERN_SUCCESS) return;
        }
        [NSTask launchedTaskWithLaunchPath:@"/usr/bin/pmset" arguments:@[@"displaysleepnow"]];
    });
}

+ (void)systemSleep {
    [self announceOff];
    if (SFDevMode) { SFLog(@"power: (dev) sleep simulated"); [gNav toast:@"(Dev) Ruhezustand"]; return; }
    SFLog(@"power: sleep");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTask launchedTaskWithLaunchPath:@"/usr/bin/pmset" arguments:@[@"sleepnow"]];
    });
}

+ (NSDate *)sleepTimerFireDate { return gFireDate; }

+ (void)setSleepTimerMinutes:(NSInteger)minutes {
    [gSleepTimer invalidate]; gSleepTimer = nil;
    [gWarnTimer invalidate]; gWarnTimer = nil;
    gFireDate = nil;
    if (minutes <= 0) { SFLog(@"power: sleep timer off"); return; }
    NSTimeInterval secs = minutes * 60;
    gFireDate = [NSDate dateWithTimeIntervalSinceNow:secs];
    gSleepTimer = [NSTimer scheduledTimerWithTimeInterval:secs target:self selector:@selector(sleepTimerFired) userInfo:nil repeats:NO];
    if (secs > 90)
        gWarnTimer = [NSTimer scheduledTimerWithTimeInterval:secs - 60 target:self selector:@selector(sleepTimerWarn) userInfo:nil repeats:NO];
    SFLog(@"power: sleep timer %ld min", (long)minutes);
}

+ (void)sleepTimerWarn { [gNav toast:@"Sleep-Timer: Bildschirm geht in 1 Minute aus"]; }

+ (void)sleepTimerFired {
    gSleepTimer = nil; gFireDate = nil;
    [self displayOff];
}

+ (NSString *)timerDetail {
    if (!gFireDate) return @"Aus";
    NSInteger m = (NSInteger)ceil([gFireDate timeIntervalSinceNow] / 60.0);
    return [NSString stringWithFormat:@"noch %ld min", (long)MAX(1, m)];
}

+ (void)showSleepTimerMenuOn:(SFNavigator *)nav {
    NSMutableArray *opts = [NSMutableArray new];
    for (NSNumber *m in @[@30, @60, @90, @120]) {
        [opts addObject:[SFMenuOption option:[NSString stringWithFormat:@"%@ Minuten", m] action:^{
            [self setSleepTimerMinutes:m.integerValue];
            [nav toast:[NSString stringWithFormat:@"Bildschirm geht in %@ Minuten aus", m]];
        }]];
    }
    if (gFireDate) [opts addObject:[SFMenuOption option:@"Sleep-Timer ausschalten" action:^{
        [self setSleepTimerMinutes:0];
        [nav toast:@"Sleep-Timer aus"];
    }]];
    [nav push:[[SFMenuScreen alloc] initWithTitle:@"Sleep-Timer" subtitle:[self timerDetail] options:opts theme:nav.top.theme]];
}

+ (void)showPowerMenuOn:(SFNavigator *)nav {
    gNav = nav;
    SFMenuOption *off = [SFMenuOption option:@"Bildschirm ausschalten" action:^{ [self displayOff]; }];
    SFMenuOption *timer = [SFMenuOption option:@"Sleep-Timer" action:^{
        dispatch_async(dispatch_get_main_queue(), ^{ [self showSleepTimerMenuOn:nav]; });
    }];
    timer.detail = [self timerDetail];
    SFMenuOption *sleep = [SFMenuOption option:@"Ruhezustand" action:^{ [self systemSleep]; }];
    sleep.detail = @"Mac schlafen legen";
    [nav push:[[SFMenuScreen alloc] initWithTitle:@"Energie" subtitle:nil options:@[off, timer, sleep] theme:nav.top.theme]];
}

+ (void)setNavigator:(SFNavigator *)nav { gNav = nav; }
@end
