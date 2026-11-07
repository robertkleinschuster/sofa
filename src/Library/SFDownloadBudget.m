#import "SFDownloadBudget.h"

const NSTimeInterval SFDownloadBudgetWindow = 24 * 3600;

NSArray *SFDownloadBudgetRecent(NSArray *starts, NSTimeInterval now) {
    NSIndexSet *keep = [starts indexesOfObjectsPassingTest:^BOOL(NSNumber *t, NSUInteger i, BOOL *stop) {
        return now - t.doubleValue < SFDownloadBudgetWindow;
    }];
    return [[starts objectsAtIndexes:keep] sortedArrayUsingSelector:@selector(compare:)];
}

NSTimeInterval SFDownloadBudgetFreeAt(NSArray *recent, NSUInteger max) {
    if (!max || recent.count < max) return 0;
    return [recent[recent.count - max] doubleValue] + SFDownloadBudgetWindow;
}
