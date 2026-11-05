// SFDateFromISO8601: offsets, Z, fractions, no zone = UTC, date only = local day, garbage = nil.
// Raw strings as the source APIs send them (ARD broadcastedOn, ZDF editorialDate, CCC, YouTube RSS).
#import <Foundation/Foundation.h>
#import "SFCore.h"
BOOL SFDevMode = NO;
int main(void){ @autoreleasepool {
  NSDictionary *cases = @{
    @"2026-05-21T20:50:00Z": @1779396600, @"2026-05-23T10:57:37.307Z": @1779533857.307,
    @"2021-02-22T18:25:00.000000+00:00": @1614018300, @"2008-01-01T01:00:00.000+01:00": @1199145600,
    @"2026-10-24T23:45:10+00:00": @1792885510, @"2026-11-05T05:13:00+0100": @1793851980,
    @"2026-11-04T23:15:00-05:30": @1793853900, @"2026-11-05T05:13": @1793855580 };
  int bad = 0;
  for (NSString *k in cases) { NSDate *d = SFDateFromISO8601(k); double want = [cases[k] doubleValue];
    BOOL ok = d && fabs(d.timeIntervalSince1970 - want) < 0.01; if (!ok) bad++;
    printf("%s %-36s -> %.3f (want %.3f)\n", ok ? "ok  " : "FAIL", k.UTF8String, d.timeIntervalSince1970, want); }
  NSDate *day = SFDateFromISO8601(@"2026-10-31");
  NSDateComponents *c = [[NSCalendar currentCalendar] components:NSHourCalendarUnit|NSDayCalendarUnit fromDate:day];
  printf("%s date-only -> local day %ld hour %ld\n", c.day == 31 && c.hour == 0 ? "ok  " : "FAIL", (long)c.day, (long)c.hour);
  for (NSString *b in @[@"", @"gestern", @"2026-13", @"2026-11-05X", @"2026-11-05T5:1"]) { if (SFDateFromISO8601(b)) { bad++; printf("FAIL accepted %s\n", b.UTF8String);} }
  printf(bad ? "FAILED\n" : "all ok\n"); return bad;
}}
