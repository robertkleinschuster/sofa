// sources: src/Apps/YouTube/SFYTNight.m
// "Nachts ganz ruhen": stop, a second stop at most once per night, wake in the morning.
#import "../../src/Apps/YouTube/SFYTNight.h"
#import "SFCore.h"
BOOL SFDevMode = NO;

static int fails;
static void expect(BOOL ok, NSString *what) { if (!ok) { fails++; printf("FAIL %s\n", what.UTF8String); } }

int main(void) {
    @autoreleasepool {
        expect(SFYTNightDecide(YES, NO, YES, NO, NO) == SFYTNightStop, @"night, resting, setting on: stop");
        expect(SFYTNightDecide(YES, YES, NO, NO, NO) == SFYTNightNone, @"stopped and still off: nothing");
        expect(SFYTNightDecide(YES, YES, YES, NO, NO) == SFYTNightStop, @"started again by some use: stopped once more");
        expect(SFYTNightDecide(YES, YES, YES, YES, NO) == SFYTNightNone, @"a second time this night: left running (no cycle)");
        expect(SFYTNightDecide(NO, YES, NO, NO, YES) == SFYTNightWake, @"morning: wake");
        expect(SFYTNightDecide(NO, YES, NO, NO, NO) == SFYTNightNone, @"a download fills at night: neither stop nor wake");
        expect(SFYTNightDecide(NO, NO, YES, NO, YES) == SFYTNightNone, @"day, never stopped: nothing");
        NSTimeZone *vie = [NSTimeZone timeZoneWithName:@"Europe/Vienna"];
        NSString *a = SFYTNightKey(SFDateFromISO8601(@"2026-11-17T23:30:00+01:00"), vie);
        NSString *b = SFYTNightKey(SFDateFromISO8601(@"2026-11-18T03:00:00+01:00"), vie);
        NSString *c = SFYTNightKey(SFDateFromISO8601(@"2026-11-18T23:10:00+01:00"), vie);
        expect([a isEqual:@"2026-11-17"] && [a isEqual:b], @"23:30 and 3:00 are the same night");
        expect([c isEqual:@"2026-11-18"], @"the next evening is the next night");
    }
    if (!fails) printf("ytnight ok\n");
    return fails ? 1 : 0;
}
