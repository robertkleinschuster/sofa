#import "SFYTFeeds.h"
#import "SFApp.h"
#import "SFYTInnerTube.h"
#import "SFYTParser.h"
#import "SFYTBreaker.h"

// At most `max` calls per 30 min for one purpose; YES = this one may go.
static BOOL withinBudget(NSMutableArray *recent, NSUInteger max) {
    @synchronized (recent) {
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        while (recent.count && now - [recent.firstObject doubleValue] > 1800) [recent removeObjectAtIndex:0];
        if (recent.count >= max) return NO;
        [recent addObject:@(now)];
        return YES;
    }
}
static NSMutableArray *gAvatarCalls;   // avatars: 5 per 30 min
static NSMutableSet *gAvatarTried;     // channels asked for their avatar since launch (once each)

@implementation SFYTFeeds

+ (void)initialize {
    if (self != [SFYTFeeds class]) return;
    gAvatarCalls = [NSMutableArray new]; gAvatarTried = [NSMutableSet new];
}

// the channel's long videos: its "UULF" uploads playlist (no Shorts), as the playlist page shows
// them. Not kept in the response cache (~1 MB answer): the follow keeps the parsed newest ones.
+ (void)feed:(NSString *)cid done:(void (^)(NSArray *, NSError *))done {
    if (![cid hasPrefix:@"UC"]) { done(nil, SFError(@"Unbekannter Kanal")); return; }
    SFYTCallBackground(@"browse", @{@"browseId": [@"VLUULF" stringByAppendingString:[cid substringFromIndex:2]]}, 0, ^(id j, NSError *e) {
        NSArray *items = j ? [self videosInUploads:j] : nil;
        SFMain(^{ done(items, items ? nil : e); });
    });
}

+ (NSArray *)videosInUploads:(id)browse {
    NSMutableArray *videos = [NSMutableArray new];
    for (SFItem *i in [SFYTParser itemsIn:browse continuation:NULL channels:nil]) if (i.kind == SFItemVideo) [videos addObject:i];
    return videos;
}

// A followed channel without a usable picture asks once per launch - its header is the channel
// page's own answer (cached a day), on a budget of its own: a library adopted with many such
// channels heals over a few hours without a burst.
+ (void)avatar:(NSString *)cid done:(void (^)(NSString *))done {
    BOOL ask;
    @synchronized (gAvatarTried) {
        ask = [cid hasPrefix:@"UC"] && ![gAvatarTried containsObject:cid] && ![SFYTBreaker shared].blockedUntil && withinBudget(gAvatarCalls, 5);
        if (ask) [gAvatarTried addObject:cid];
    }
    if (!ask) { SFMain(^{ done(nil); }); return; }
    SFYTCallBackground(@"browse", @{@"browseId": cid}, 86400, ^(id j, NSError *e) {
        if (!j) @synchronized (gAvatarTried) { [gAvatarTried removeObject:cid]; }   // no answer: ask again later
        NSString *avatar = [SFYTParser channelHeaderIn:j][@"avatar"];
        SFLog(@"youtube: avatar of %@ %@", cid, avatar.length ? @"found" : j ? @"not in the header" : @"not loaded");
        SFMain(^{ done(avatar); });
    });
}

+ (void)devFeed:(NSString *)cid {
    [self feed:cid done:^(NSArray *items, NSError *e) {
        for (SFItem *i in items) SFLog(@"dev: ytfeed %@ %@ %@", SFRefID(i.identifier), i.date, i.title);
        SFLog(@"dev: ytfeed end (%lu items%@)", (unsigned long)items.count, e ? [@", " stringByAppendingString:e.localizedDescription] : @"");
    }];
}
@end
