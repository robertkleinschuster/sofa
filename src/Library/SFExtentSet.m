#import "SFExtentSet.h"

@implementation SFExtentSet {
    NSMutableArray *_r;   // @[@start, @end], sorted by start, disjoint and not touching
}

- (instancetype)init { if ((self = [super init])) _r = [NSMutableArray new]; return self; }

+ (instancetype)setWithRanges:(NSArray *)ranges {
    SFExtentSet *s = [self new];
    for (NSArray *r in ranges) if (r.count == 2) [s addStart:[r[0] longLongValue] end:[r[1] longLongValue]];
    return s;
}

- (id)copyWithZone:(NSZone *)zone { return [SFExtentSet setWithRanges:_r]; }

static long long S(NSArray *r) { return [r[0] longLongValue]; }
static long long E(NSArray *r) { return [r[1] longLongValue]; }

// the first range whose end reaches `x` (end >= x): where a range starting at x would merge or go
- (NSUInteger)firstEndingAtOrAfter:(long long)x {
    NSUInteger lo = 0, hi = _r.count;
    while (lo < hi) { NSUInteger mid = (lo + hi) / 2; if (E(_r[mid]) < x) lo = mid + 1; else hi = mid; }
    return lo;
}

- (void)addStart:(long long)start end:(long long)end {
    if (end <= start) return;
    NSUInteger i = [self firstEndingAtOrAfter:start];
    long long s = start, e = end;
    NSUInteger j = i;
    while (j < _r.count && S(_r[j]) <= e) { s = MIN(s, S(_r[j])); e = MAX(e, E(_r[j])); j++; }   // overlapping or touching
    [_r replaceObjectsInRange:NSMakeRange(i, j - i) withObjectsFromArray:@[@[@(s), @(e)]]];
}

- (void)removeStart:(long long)start end:(long long)end {
    if (end <= start) return;
    NSMutableArray *out = [NSMutableArray new];
    for (NSArray *r in _r) {
        if (E(r) <= start || S(r) >= end) { [out addObject:r]; continue; }
        if (S(r) < start) [out addObject:@[r[0], @(start)]];
        if (E(r) > end) [out addObject:@[@(end), r[1]]];
    }
    _r = out;
}

- (BOOL)coversStart:(long long)start end:(long long)end {
    if (end <= start) return YES;
    NSUInteger i = [self firstEndingAtOrAfter:end];   // the range that must hold `end`...
    // ...touching ones are merged, so one range has to span all of it
    for (NSUInteger k = (i > 0 ? i - 1 : 0); k < MIN(_r.count, i + 1); k++)
        if (S(_r[k]) <= start && E(_r[k]) >= end) return YES;
    return NO;
}

- (long long)contiguousFrom:(long long)start {
    NSUInteger i = [self firstEndingAtOrAfter:start + 1];
    if (i < _r.count && S(_r[i]) <= start) return E(_r[i]) - start;
    return 0;
}

- (NSArray *)missingFrom:(long long)start to:(long long)end {
    NSMutableArray *gaps = [NSMutableArray new];
    long long at = start;
    for (NSUInteger i = [self firstEndingAtOrAfter:start + 1]; i < _r.count && at < end; i++) {
        if (S(_r[i]) > at) [gaps addObject:@[@(at), @(MIN(S(_r[i]), end))]];
        at = MAX(at, E(_r[i]));
    }
    if (at < end) [gaps addObject:@[@(at), @(end)]];
    return gaps;
}

- (NSArray *)ranges { return [_r copy]; }
- (long long)bytes { long long n = 0; for (NSArray *r in _r) n += E(r) - S(r); return n; }
@end
