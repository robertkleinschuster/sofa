#import "SFStats.h"
#import "SFStore.h"

static NSString *SFStatsDay(NSDate *d) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:d];
}

static void SFStatsSetup(void) {
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        SFStore *st = [SFStore shared];
        [st run:@"DELETE FROM stats WHERE day < ?" args:@[SFStatsDay([NSDate dateWithTimeIntervalSinceNow:-180 * 86400])]];
    });
}

void SFCount(NSString *event) {
    if (!event.length) return;
    SFStatsSetup();
    [[SFStore shared] run:@"INSERT INTO stats (day, event, n) VALUES (?, ?, 1) ON CONFLICT(day, event) DO UPDATE SET n = n + 1"
                     args:@[SFStatsDay([NSDate date]), event]];
}

NSDictionary *SFStatsTotals(NSInteger days) {
    SFStatsSetup();
    NSMutableDictionary *r = [NSMutableDictionary new];
    for (NSDictionary *row in [[SFStore shared] rows:@"SELECT event, SUM(n) AS n FROM stats WHERE day >= ? GROUP BY event ORDER BY event"
                                                args:@[SFStatsDay([NSDate dateWithTimeIntervalSinceNow:-days * 86400])]])
        r[row[@"event"]] = row[@"n"];
    return r;
}
