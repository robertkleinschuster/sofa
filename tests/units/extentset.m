// sources: src/Library/SFExtentSet.m
// flags: -Isrc/Library
// SFExtentSet: coalescing (overlap, touch, bridge), cover checks across one and several ranges,
// the contiguous run from a point, the gaps of a window, removal splitting a range, persisted form.
#import <Foundation/Foundation.h>
#import "SFExtentSet.h"
BOOL SFDevMode = NO;
static int bad = 0;
#define CHECK(c, m) do { if (!(c)) { fprintf(stderr, "FAIL %s (%s:%d)\n", m, __FILE__, __LINE__); bad++; } } while (0)
static NSString *P(NSArray *a) { NSMutableArray *o = [NSMutableArray new]; for (NSArray *r in a) [o addObject:[NSString stringWithFormat:@"%@-%@", r[0], r[1]]]; return [o componentsJoinedByString:@","]; }
int main(void) { @autoreleasepool {
    SFExtentSet *s = [SFExtentSet new];
    [s addStart:100 end:200]; [s addStart:300 end:400]; [s addStart:0 end:10];
    CHECK([P(s.ranges) isEqual:@"0-10,100-200,300-400"], "sorted, separate ranges");
    [s addStart:200 end:250];
    CHECK([P(s.ranges) isEqual:@"0-10,100-250,300-400"], "a touching range merges");
    [s addStart:240 end:310];
    CHECK([P(s.ranges) isEqual:@"0-10,100-400"], "a bridging range merges both neighbours");
    [s addStart:120 end:130];
    CHECK([P(s.ranges) isEqual:@"0-10,100-400"] && s.bytes == 310, "an inner range changes nothing");
    [s addStart:50 end:50];
    CHECK(s.ranges.count == 2, "an empty range is no range");
    CHECK([s coversStart:100 end:400] && [s coversStart:150 end:160] && [s coversStart:0 end:10], "covered windows");
    CHECK(![s coversStart:5 end:105] && ![s coversStart:390 end:401] && ![s coversStart:10 end:100], "windows across a gap");
    CHECK([s contiguousFrom:150] == 250 && [s contiguousFrom:10] == 0 && [s contiguousFrom:0] == 10 && [s contiguousFrom:400] == 0, "contiguous run from a point");
    CHECK([P([s missingFrom:0 to:500]) isEqual:@"10-100,400-500"], "gaps of a window");
    CHECK([P([s missingFrom:120 to:300]) isEqual:@""], "no gap inside a range");
    CHECK([P([s missingFrom:5 to:105]) isEqual:@"10-100"], "a gap inside the window only");
    [s removeStart:150 end:160];
    CHECK([P(s.ranges) isEqual:@"0-10,100-150,160-400"], "removal splits a range");
    SFExtentSet *t = [SFExtentSet setWithRanges:@[@[@300, @400], @[@0, @50], @[@40, @120]]];
    CHECK([P(t.ranges) isEqual:@"0-120,300-400"], "persisted form in any order, coalesced");
    SFExtentSet *c = [t copy]; [c addStart:120 end:300];
    CHECK([P(c.ranges) isEqual:@"0-400"] && [P(t.ranges) isEqual:@"0-120,300-400"], "a copy is independent");
    return bad ? 1 : 0;
} }
