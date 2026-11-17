#import "SFRefreshPlan.h"

// a person's volume (2026-11-07: 135 followed YouTube channels were several hundred page loads a
// day): never more often than every 2 h, a slow channel once a day
const NSTimeInterval SFRefreshMin = 2 * 3600, SFRefreshMax = 24 * 3600;
const NSTimeInterval SFRefreshGapMin = 20;

NSTimeInterval SFRefreshInterval(NSArray *dates) {
    NSMutableArray *d = [NSMutableArray new];
    for (id x in dates) if ([x isKindOfClass:[NSDate class]]) [d addObject:x];
    if (d.count < 3) return 2 * 3600;
    [d sortUsingComparator:^NSComparisonResult(NSDate *a, NSDate *b) { return [b compare:a]; }];   // newest first
    NSMutableArray *gaps = [NSMutableArray new];
    for (NSUInteger i = 0; i + 1 < MIN(d.count, (NSUInteger)11); i++) [gaps addObject:@([d[i] timeIntervalSinceDate:d[i + 1]])];
    [gaps sortUsingSelector:@selector(compare:)];
    double median = [gaps[gaps.count / 2] doubleValue];
    return MAX(SFRefreshMin, MIN(SFRefreshMax, median / 4));
}

NSDate *SFRefreshNextDue(NSArray *dates, NSDate *checked, double r, NSTimeZone *tz) {
    NSTimeInterval iv = SFRefreshInterval(dates) * (0.8 + 0.4 * r);
    NSDate *due = [checked dateByAddingTimeInterval:iv];
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = tz ?: [NSTimeZone localTimeZone];
    if ([cal component:NSCalendarUnitHour fromDate:due] < 6) due = [checked dateByAddingTimeInterval:2 * iv];
    return due;
}

NSTimeInterval SFRefreshGap(double r) { return SFRefreshGapMin * (1 + r); }

NSDate *SFRefreshBatchAfter(NSDate *now, double r, BOOL skipNight, NSTimeZone *tz) {
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = tz ?: [NSTimeZone localTimeZone];
    NSInteger h = [cal component:NSCalendarUnitHour fromDate:now];
    BOOL night = h >= 23 || h < 6;
    NSDate *next = [now dateByAddingTimeInterval:(night ? 5 : 2) * 3600 * (0.8 + 0.4 * r)];
    if (skipNight) {
        NSInteger nh = [cal component:NSCalendarUnitHour fromDate:next];
        if (night || nh >= 23 || nh < 6) {   // the morning after: 6:00 + up to 30 min
            NSDate *six = [cal dateBySettingHour:6 minute:0 second:0 ofDate:(h >= 6 ? [now dateByAddingTimeInterval:86400] : now) options:0];
            next = [six dateByAddingTimeInterval:r * 1800];
        }
    }
    return next;
}

NSDate *SFRefreshBatchStep(NSDate *when, NSDate *due, NSDate *now, BOOL batched, BOOL *inBatch, NSDate **batchAt,
                           double r, BOOL skipNight, NSTimeZone *tz) {
    if (!batched) { *inBatch = NO; *batchAt = nil; return when; }
    if (*inBatch && [due timeIntervalSinceDate:now] <= 0) return when;   // the batch goes on
    if (*inBatch || !*batchAt) *batchAt = SFRefreshBatchAfter(now, r, skipNight, tz);
    *inBatch = NO;
    return [when laterDate:*batchAt];
}
