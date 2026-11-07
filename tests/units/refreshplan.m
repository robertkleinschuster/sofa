// sources: src/Library/SFRefreshPlan.m
// SFRefreshPlan: how often a followed show/channel is checked again.
#import "../../src/Library/SFRefreshPlan.h"
#import "SFCore.h"
BOOL SFDevMode = NO;

static NSDate *at(NSString *iso) { return SFDateFromISO8601(iso); }

static int fails;
static void expect(BOOL ok, NSString *what) { if (!ok) { fails++; printf("FAIL %s\n", what.UTF8String); } }
static NSArray *every(NSTimeInterval gap, int n, NSDate *from) {
    NSMutableArray *a = [NSMutableArray new];
    for (int i = 0; i < n; i++) [a addObject:[from dateByAddingTimeInterval:-gap * i]];
    return a;
}

int main(void) {
    @autoreleasepool {
        NSDate *now = at(@"2026-11-06T08:00:00+01:00");
        NSTimeZone *vie = [NSTimeZone timeZoneWithName:@"Europe/Vienna"];
        expect(SFRefreshInterval(every(7 * 86400, 10, now)) == SFRefreshMax && SFRefreshMax == 24 * 3600, @"weekly uploads: the longest interval, once a day");
        expect(SFRefreshInterval(every(86400, 10, now)) == 6 * 3600, @"daily: 6 h");
        expect(SFRefreshInterval(every(8 * 3600, 10, now)) == 2 * 3600, @"three a day: 2 h");
        expect(SFRefreshInterval(every(600, 10, now)) == SFRefreshMin, @"news ticker: never more often than 2 h");
        expect(SFRefreshInterval(@[now]) == 2 * 3600, @"unknown rhythm: 2 h");
        NSMutableArray *outlier = [every(8 * 3600, 9, now) mutableCopy];
        [outlier addObject:[now dateByAddingTimeInterval:-400 * 86400]];
        expect(SFRefreshInterval(outlier) == 2 * 3600, @"median: one old gap does not stretch it");
        expect(SFRefreshInterval([every(8 * 3600, 10, now) reverseObjectEnumerator].allObjects) == 2 * 3600, @"any order");

        NSDate *noon = at(@"2026-11-06T12:00:00+01:00");
        NSDate *lo = SFRefreshNextDue(every(8 * 3600, 10, now), noon, 0, vie), *hi = SFRefreshNextDue(every(8 * 3600, 10, now), noon, 0.999, vie);
        expect([lo timeIntervalSinceDate:noon] == 0.8 * 2 * 3600, @"variation: -20 %");
        expect(fabs([hi timeIntervalSinceDate:noon] - 1.2 * 2 * 3600) < 10, @"variation: +20 %");
        NSDate *late = at(@"2026-11-06T23:00:00+01:00");   // + 2 h (r 0.5 -> exactly the interval) = 01:00: night
        expect([SFRefreshNextDue(every(8 * 3600, 10, now), late, 0.5, vie) timeIntervalSinceDate:late] == 2 * 2 * 3600, @"night: twice the interval");
        expect(SFRefreshGap(0) == SFRefreshGapMin && SFRefreshGap(0.999) < 2 * SFRefreshGapMin, @"gap 20-40 s");
    }
    if (!fails) printf("refreshplan ok\n");
    return fails ? 1 : 0;
}
