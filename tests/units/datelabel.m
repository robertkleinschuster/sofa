// sources:
// SFFormatDateShortAt (hitch 2026-11-08: a home refresh spent ~150 ms on the main thread in ICU
// calendar math for tile dates): the local-day arithmetic gives exactly the calendar's labels -
// across DST changes, midnight, year ends - and a refresh's worth of labels is cheap.
#import "SFCore.h"
BOOL SFDevMode = NO;
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }

// the reference: what the calendar says (the former implementation)
static NSString *Reference(NSDate *d, NSDate *now) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *today = [cal startOfDayForDate:now], *day = [cal startOfDayForDate:d];
    NSInteger diff = [cal components:NSCalendarUnitDay fromDate:day toDate:today options:0].day;
    if (diff == 0) return @"Heute";
    if (diff == 1) return @"Gestern";
    if (diff > 1 && diff < 7) return [NSString stringWithFormat:@"vor %ld Tagen", (long)diff];
    if (diff == -1) return @"TV morgen";
    NSDateFormatter *df = [NSDateFormatter new];
    df.locale = [NSLocale localeWithLocaleIdentifier:@"de_AT"];
    BOOL same = [cal component:NSCalendarUnitYear fromDate:d] == [cal component:NSCalendarUnitYear fromDate:today];
    df.dateFormat = same ? @"d. MMM" : @"d. MMM yyyy";
    NSString *s = [df stringFromDate:d];
    return diff < 0 ? [@"TV am " stringByAppendingString:s] : s;
}

static NSDate *Local(int y, int mo, int d, int h, int mi) {
    NSDateComponents *c = [NSDateComponents new];
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi;
    return [[NSCalendar currentCalendar] dateFromComponents:c];
}

int main(void){ @autoreleasepool {
  [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneWithName:@"Europe/Vienna"]];
  [NSTimeZone resetSystemTimeZone];
  setenv("TZ", "Europe/Vienna", 1); tzset();
  // "now"s around DST changes, midnight and the year end; dates every 7 h over three weeks around each
  NSArray *nows = @[Local(2026, 3, 29, 1, 30), Local(2026, 3, 29, 12, 0), Local(2026, 10, 25, 0, 10),
                    Local(2026, 10, 25, 23, 50), Local(2026, 11, 8, 0, 0), Local(2026, 11, 8, 23, 59),
                    Local(2027, 1, 1, 0, 5), Local(2026, 12, 31, 23, 55)];
  int checked = 0, wrong = 0;
  for (NSDate *now in nows)
    for (int h = -21 * 24; h <= 3 * 24; h += 7) {
      NSDate *d = [now dateByAddingTimeInterval:h * 3600.0];
      NSString *a = SFFormatDateShortAt(d, now), *b = Reference(d, now);
      checked++;
      if (![a isEqual:b]) { wrong++; if (wrong < 5) printf("     %s vs %s (now %s, d %s)\n", a.UTF8String, b.UTF8String, now.description.UTF8String, d.description.UTF8String); }
    }
  printf("     %d labels compared\n", checked);
  expect(wrong == 0, "local-day labels equal the calendar's (DST, midnight, year end)");
  expect([SFFormatDateShortAt(Local(2026, 11, 7, 23, 59), Local(2026, 11, 8, 0, 1)) isEqual:@"Gestern"], "two minutes apart across midnight: Gestern");
  expect([SFFormatDateShortAt(Local(2026, 11, 9, 20, 15), Local(2026, 11, 8, 12, 0)) isEqual:@"TV morgen"], "tomorrow's broadcast: TV morgen");
  expect([SFFormatDateShortAt(Local(2025, 12, 30, 9, 0), Local(2026, 1, 10, 9, 0)) isEqual:@"30. Dez. 2025"], "last year: with the year");
  expect([SFFormatDateShortAt(nil, [NSDate date]) isEqual:@""], "no date: empty");
  // a home refresh: ~600 tiles over ~60 distinct days - against the calendar way in the same process,
  // rounds alternating and the best of each kept (an absolute bound fails under test-all's load)
  NSDate *now = [NSDate date];
  double best = 1e9, bestRef = 1e9;
  for (int round = 0; round < 3; round++) {
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    for (int i = 0; i < 600; i++) SFFormatDateShortAt([now dateByAddingTimeInterval:-(i % 60) * 86400.0 - 3600], now);
    NSTimeInterval t1 = [NSDate timeIntervalSinceReferenceDate];
    for (int i = 0; i < 600; i++) Reference([now dateByAddingTimeInterval:-(i % 60) * 86400.0 - 3600], now);
    NSTimeInterval t2 = [NSDate timeIntervalSinceReferenceDate];
    best = MIN(best, (t1 - t0) * 1000); bestRef = MIN(bestRef, (t2 - t1) * 1000);
  }
  printf("     600 labels in %.1f ms (the calendar way: %.1f ms)\n", best, bestRef);
  expect(best * 3 < bestRef, "a refresh's worth of labels: at least 3x cheaper than the calendar way");
  return bad ? 1 : 0;
}}
