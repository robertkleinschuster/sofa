// SFInterleave: the fair merge behind Home's mixed rows (one list per app, ranked).
#import "SFCore.h"
BOOL SFDevMode = NO;

static int fails;
static void expect(NSArray *got, NSArray *want, const char *what) {
    if ([got isEqualToArray:want]) return;
    fails++; printf("FAIL %s: got %s\n", what, [[got componentsJoinedByString:@" "] UTF8String]);
}

int main(void) {
    @autoreleasepool {
        id (^same)(id) = ^id(id e) { return e; };
        expect(SFInterleave(@[@[@"a1", @"a2", @"a3"], @[@"b1"], @[@"c1", @"c2"]], 10, same),
               @[@"a1", @"b1", @"c1", @"a2", @"c2", @"a3"], "round robin, uneven lengths");
        expect(SFInterleave(@[@[@"a1", @"a2"], @[@"b1", @"b2"]], 3, same), @[@"a1", @"b1", @"a2"], "max cuts mid-round");
        expect(SFInterleave(@[@[@"x", @"a2"], @[@"x", @"b2"]], 10, same), @[@"x", @"a2", @"b2"], "duplicate key kept once (first app wins)");
        expect(SFInterleave(@[@[@"a1", @"nokey", @"a3"]], 10, ^id(id e) { return [e isEqual:@"nokey"] ? nil : e; }),
               @[@"a1", @"a3"], "element without key skipped");
        expect(SFInterleave(@[], 10, same), @[], "no lists");
        expect(SFInterleave(@[@[], @[@"b1"]], 0, same), @[], "max 0");
    }
    if (!fails) printf("interleave ok\n");
    return fails ? 1 : 0;
}
