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

        // batches while resting/warm: ~2 h by day, 4-6 h by night, +/-20 %; skipNight: the morning after
        expect([SFRefreshBatchAfter(noon, 0.5, NO, vie) timeIntervalSinceDate:noon] == 2 * 3600, @"batch by day: 2 h");
        expect([SFRefreshBatchAfter(noon, 0, NO, vie) timeIntervalSinceDate:noon] == 0.8 * 2 * 3600, @"batch by day: -20 %");
        expect([SFRefreshBatchAfter(late, 0.5, NO, vie) timeIntervalSinceDate:late] == 5 * 3600, @"batch by night: 5 h");
        expect([SFRefreshBatchAfter(late, 0, NO, vie) timeIntervalSinceDate:late] == 4 * 3600, @"batch by night: at least 4 h");
        expect(fabs([SFRefreshBatchAfter(late, 0.999, NO, vie) timeIntervalSinceDate:late] - 6 * 3600) < 30, @"batch by night: at most 6 h");
        NSDate *six = at(@"2026-11-07T06:00:00+01:00");
        expect([SFRefreshBatchAfter(late, 0, YES, vie) isEqualToDate:six], @"skipNight from 23:00: 6:00 the next morning");
        expect([SFRefreshBatchAfter(at(@"2026-11-07T02:00:00+01:00"), 0.5, YES, vie) isEqualToDate:[six dateByAddingTimeInterval:900]], @"skipNight at 2:00: 6:00 + r * 30 min");
        NSDate *evening = at(@"2026-11-06T21:30:00+01:00");   // + 2 h = 23:30: night
        expect([SFRefreshBatchAfter(evening, 0.5, YES, vie) isEqualToDate:[six dateByAddingTimeInterval:900]], @"skipNight: a batch falling into the night waits for the morning");
        expect([SFRefreshBatchAfter(evening, 0.5, NO, vie) timeIntervalSinceDate:evening] == 2 * 3600, @"without skipNight it runs at 23:30");

        // the batching step of SFFollows: wait for the batch, run every due follow in it, then the next
        BOOL inBatch = NO; NSDate *batchAt = nil;
        NSDate *due = [noon dateByAddingTimeInterval:-600];   // overdue
        NSDate *w = SFRefreshBatchStep(due, due, noon, YES, &inBatch, &batchAt, 0.5, NO, vie);
        expect(!inBatch && [batchAt timeIntervalSinceDate:noon] == 2 * 3600 && [w isEqualToDate:batchAt], @"batched: an overdue follow waits for the batch");
        NSDate *firstBatch = batchAt;
        w = SFRefreshBatchStep(due, due, [noon dateByAddingTimeInterval:60], YES, &inBatch, &batchAt, 0.9, NO, vie);
        expect([batchAt isEqualToDate:firstBatch] && [w isEqualToDate:firstBatch], @"replanning before the batch keeps its time");
        NSDate *t = firstBatch; inBatch = YES;   // the batch's first check started (SFFollows' checkDue)
        w = SFRefreshBatchStep(t, [t dateByAddingTimeInterval:-30], t, YES, &inBatch, &batchAt, 0.5, NO, vie);
        expect(inBatch && [w isEqualToDate:t], @"in the batch: the next due follow goes on");
        NSDate *later = [t dateByAddingTimeInterval:3600];
        w = SFRefreshBatchStep(later, later, t, YES, &inBatch, &batchAt, 0.5, NO, vie);
        expect(!inBatch && [batchAt timeIntervalSinceDate:t] == 2 * 3600 && [w isEqualToDate:batchAt], @"the first not yet due ends the batch: the next one in 2 h");
        w = SFRefreshBatchStep(due, due, noon, NO, &inBatch, &batchAt, 0.5, NO, vie);
        expect(!inBatch && !batchAt && [w isEqualToDate:due], @"awake and cool: the plain plan, state cleared");
    }
    if (!fails) printf("refreshplan ok\n");
    return fails ? 1 : 0;
}
