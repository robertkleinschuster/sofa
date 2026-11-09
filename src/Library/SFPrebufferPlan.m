#import "SFPrebufferPlan.h"
#include <math.h>

@implementation SFPrebufferPlan
+ (NSArray *)candidates:(NSArray *)suggestions focused:(SFItem *)focused history:(NSArray *)history now:(NSTimeInterval)now {
    NSMutableDictionary *usage = [NSMutableDictionary new], *recent = [NSMutableDictionary new];
    NSUInteger n = 0;
    for (NSDictionary *h in history) {
        if (++n > 100) break;
        SFItem *i = h[@"item"];
        if (![i isKindOfClass:[SFItem class]] || !i.identifier.length) continue;
        if (!recent[i.identifier]) recent[i.identifier] = h; // newest history wins
        double age = MAX(0, now - [h[@"updated"] doubleValue]);
        NSString *channel = [NSString stringWithFormat:@"%@:%@", i.source ?: @"", i.channel ?: @""];
        if (i.channel.length) usage[channel] = @([usage[channel] doubleValue] + exp(-age / (7 * 86400.0)));
    }
    NSMutableArray *pool = [NSMutableArray new];
    if (focused) [pool addObject:focused];
    // Recent unfinished videos are likely resume targets even when not in the current suggestions.
    for (NSDictionary *h in [history subarrayWithRange:NSMakeRange(0, MIN(history.count, (NSUInteger)20))])
        if (![h[@"watched"] boolValue] && [h[@"pos"] doubleValue] > 0 && [h[@"item"] isKindOfClass:[SFItem class]]) [pool addObject:h[@"item"]];
    [pool addObjectsFromArray:[suggestions subarrayWithRange:NSMakeRange(0, MIN(suggestions.count, (NSUInteger)100))]];
    NSMutableSet *seen = [NSMutableSet new];
    NSMutableArray *ranked = [NSMutableArray new];
    n = 0;
    for (SFItem *i in pool) {
        NSUInteger order = n++;
        if (![i isKindOfClass:[SFItem class]] || i.kind != SFItemVideo || i.drm || !i.identifier.length || i.localPath.length || [seen containsObject:i.identifier]) continue;
        [seen addObject:i.identifier];
        NSDictionary *h = recent[i.identifier];
        BOOL focus = [i.identifier isEqualToString:focused.identifier];
        if ([h[@"watched"] boolValue] && !focus) continue;
        double pos = [h[@"pos"] doubleValue];
        if (!isfinite(pos) || pos < 0 || [h[@"watched"] boolValue] || (i.duration > 0 && pos >= i.duration - 2)) pos = 0;
        NSString *channel = [NSString stringWithFormat:@"%@:%@", i.source ?: @"", i.channel ?: @""];
        double score = (focus ? 10000 : 0) + MIN(20, [usage[channel] doubleValue]) * 20;
        if (pos > 0) score += 200 * exp(-MAX(0, now - [h[@"updated"] doubleValue]) / (3 * 86400.0));
        score += 10.0 / (1 + order); // suggestion order is a weak signal; never invent requests
        [ranked addObject:@{@"item": i, @"position": @(pos), @"score": @(score), @"order": @(order)}];
    }
    [ranked sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult r = [b[@"score"] compare:a[@"score"]];
        return r == NSOrderedSame ? [a[@"order"] compare:b[@"order"]] : r;
    }];
    return [ranked subarrayWithRange:NSMakeRange(0, MIN(ranked.count, (NSUInteger)3))];
}
@end
