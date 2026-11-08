#import "SFYTTimeline.h"
#import "SFExtentSet.h"
#import "SFCore.h"

NSArray *SFYTStoredRanges(NSArray *index, long long total, double duration, SFExtentSet *have) {
    NSMutableArray *r = [NSMutableArray new];
    for (NSUInteger i = 0; i < index.count; i++) {
        BOOL last = i + 1 == index.count;
        if (last && (total <= 0 || duration <= 0)) break;
        long long from = [index[i][0] longLongValue], to = last ? total : [index[i + 1][0] longLongValue];
        double t0 = [index[i][1] doubleValue] / 1000, t1 = last ? duration : [index[i + 1][1] doubleValue] / 1000;
        if (to > from && t1 > t0 && [have coversStart:from end:to]) SFRangesAppend(r, t0, t1);
    }
    return r;
}
