#import "SFYTOriginalTitles.h"
#import "SFYTEngine.h"
#import "SFYTBreaker.h"
#import "SFModel.h"
#import "SFStore.h"
#import "SFCore.h"
#import "SFApp.h"

// pace: what is shown now every few seconds, the backlog of stored videos far slower (a night's
// ~1600 entries over hours, not a burst); one call at a time either way
static const NSTimeInterval kShownGap = 2.0, kBacklogGap = 15.0, kRetry = 60.0, kStartDelay = 120.0;
static const NSUInteger kMaxShown = 300;   // a long list: its newest part (the rest comes when shown again)

static NSMutableOrderedSet *gShown, *gBacklog;   // video IDs, main queue only
static NSMutableSet *gDone;                      // asked this run (gone, private, no title): not again
static BOOL gBusy, gScheduled;
static NSUInteger gResolved;

@implementation SFYTOriginalTitles

+ (void)initialize {
    if (self != [SFYTOriginalTitles class]) return;
    gShown = [NSMutableOrderedSet new]; gBacklog = [NSMutableOrderedSet new]; gDone = [NSMutableSet new];
}

static NSString *RefOf(NSString *vid) { return [@"yt:" stringByAppendingString:vid]; }

+ (BOOL)known:(NSString *)vid {
    return [gDone containsObject:vid] || [[SFStore shared] originalTitleFor:RefOf(vid)] != nil;
}

+ (void)start {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStartDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSArray *ids = [[SFStore shared] itemIDsWithoutOriginalTitle:@"yt:"];
        for (NSString *ref in ids) { NSString *vid = SFRefID(ref); if (vid.length == 11) [gBacklog addObject:vid]; }
        if (ids.count) SFLog(@"yt titles: %lu stored videos to ask oEmbed for", (unsigned long)gBacklog.count);
        [self schedule:0];
    });
}

+ (void)want:(NSString *)vid {
    if (vid.length != 11) return;
    SFMain(^{
        if ([self known:vid] || [gShown containsObject:vid]) return;
        if (gShown.count >= kMaxShown) [gShown removeObjectAtIndex:0];
        [gShown addObject:vid];
        [gBacklog removeObject:vid];
        [self schedule:0];
    });
}

+ (void)wantItems:(NSArray *)items {
    for (SFItem *i in items)
        if (i.kind == SFItemVideo && [SFRefPrefix(i.identifier) isEqualToString:@"yt"]) [self want:SFRefID(i.identifier)];
}

+ (void)schedule:(NSTimeInterval)delay {
    if (gBusy || gScheduled || (!gShown.count && !gBacklog.count)) return;
    gScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gScheduled = NO;
        [self next];
    });
}

+ (void)next {
    if (gBusy) return;
    NSTimeInterval held = [SFYTBreaker shared].blockedUntil - [NSDate date].timeIntervalSince1970;
    if (held > 0) { [self schedule:MIN(held + 5, 3600)]; return; }   // a bot check: nothing until it is over
    BOOL shown = gShown.count > 0;
    NSMutableOrderedSet *q = shown ? gShown : gBacklog;
    NSString *vid = shown ? q.lastObject : q.firstObject;   // shown: the latest list first
    if (!vid) return;
    [q removeObject:vid];
    if ([self known:vid]) { [self schedule:0]; return; }
    gBusy = YES;
    [[SFYTEngine shared] oembed:vid done:^(NSInteger status, NSString *title) {
        SFMain(^{
            gBusy = NO;
            if (!status) {   // no answer (engine starting, network): again later, in its place
                if (shown) [gShown addObject:vid]; else [gBacklog insertObject:vid atIndex:0];
                [self schedule:kRetry];
                return;
            }
            [gDone addObject:vid];
            if (title.length) {
                NSString *ref = RefOf(vid);
                [[SFStore shared] setOriginalTitle:title forID:ref];
                gResolved++;
                if (gResolved % 50 == 0) SFLog(@"yt titles: %lu asked this run, %lu left", (unsigned long)gResolved, (unsigned long)(gShown.count + gBacklog.count));
            }   // gone or private (no title): the list's title stays
            [self schedule:gShown.count ? kShownGap : kBacklogGap];
        });
    }];
}
@end
