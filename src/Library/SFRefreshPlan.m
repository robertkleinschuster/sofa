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
