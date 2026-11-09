// sources: src/Library/SFPrebufferPlan.m src/Core/SFModel.m
// flags: -Isrc/Library -Isrc/Core -Isrc/Framework
// SFPrebufferPlan: at most three unique candidates - focus first, recent unfinished items at their
// resume position, usage affinity over suggestion order; watched/live/duplicates out, bad positions 0.
#import "SFPrebufferPlan.h"
#import <math.h>
BOOL SFDevMode = NO;
// SFModel links against the registry; the selection policy never looks anything up
@interface SFAppRegistry : NSObject
@end
@implementation SFAppRegistry
@end
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }

static SFItem *Item(NSString *identifier, NSString *channel) {
    SFItem *i = [SFItem new];
    i.identifier = identifier; i.kind = SFItemVideo; i.source = @"test"; i.channel = channel; i.duration = 1000;
    return i;
}
static NSString *IDAt(NSArray *r, NSUInteger n) { return n < r.count ? [r[n][@"item"] identifier] : nil; }

int main(void) { @autoreleasepool {
    SFItem *a = Item(@"test:a", @"A"), *b = Item(@"test:b", @"B"), *c = Item(@"test:c", @"A"), *d = Item(@"test:d", @"C"), *live = Item(@"test:live", @"A");
    live.kind = SFItemLive;
    NSArray *history = @[@{@"item": b, @"updated": @10000, @"pos": @400, @"watched": @NO},
                         @{@"item": a, @"updated": @9000, @"pos": @0, @"watched": @YES}];
    NSArray *r = [SFPrebufferPlan candidates:@[a, b, c, d, live, c] focused:c history:history now:10001];
    expect(r.count == 3, "at most three useful, unique candidates");
    expect([IDAt(r, 0) isEqual:c.identifier], "the focused suggestion first");
    expect([IDAt(r, 1) isEqual:b.identifier] && [r[1][@"position"] doubleValue] == 400, "a recent unfinished item at its resume position");
    expect([IDAt(r, 2) isEqual:d.identifier], "watched, live and duplicate items excluded");

    r = [SFPrebufferPlan candidates:@[d, c] focused:nil history:@[@{@"item": a, @"updated": @10000, @"pos": @0, @"watched": @YES}] now:10001];
    expect([IDAt(r, 0) isEqual:c.identifier], "usage affinity can outweigh suggestion order");
    r = [SFPrebufferPlan candidates:@[] focused:a history:history now:10001];
    expect(r.count && [r[0][@"position"] doubleValue] == 0, "a focused watched item prepares a replay from zero");
    r = [SFPrebufferPlan candidates:@[b] focused:b history:@[@{@"item": b, @"pos": @(NAN), @"updated": @10000}] now:10001];
    expect(r.count && [r[0][@"position"] doubleValue] == 0, "an invalid resume position never reaches the reader");
    expect(![SFPrebufferPlan candidates:@[] focused:nil history:@[] now:10001].count, "empty input: no background work");
    return bad ? 1 : 0;
} }
