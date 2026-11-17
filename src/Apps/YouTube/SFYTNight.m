#import "SFYTNight.h"

SFYTNightAction SFYTNightDecide(BOOL want, BOOL stopped, BOOL ready, BOOL restoppedTonight, BOOL over) {
    if (want && !stopped) return SFYTNightStop;
    if (want && stopped && ready && !restoppedTonight) return SFYTNightStop;
    if (!want && stopped && over) return SFYTNightWake;
    return SFYTNightNone;
}

NSString *SFYTNightKey(NSDate *at, NSTimeZone *tz) {
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = tz ?: [NSTimeZone localTimeZone];
    NSDateComponents *c = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour fromDate:at];
    NSDate *evening = c.hour < 12 ? [at dateByAddingTimeInterval:-86400] : at;   // after midnight: the evening before
    c = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:evening];
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)c.year, (long)c.month, (long)c.day];
}
