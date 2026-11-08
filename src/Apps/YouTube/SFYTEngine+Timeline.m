// SFYTEngine (Timeline) - what of a session's video is on disk, in time, for the player's timeline.
// The tracks' segment indexes come from the engine once their init segments arrived and stay in the
// item's manifest ("index", by track identity) - a stored session has them without the engine.
// Video and main audio both must be on disk for a time to count.
#import "SFYTEngine+Private.h"
#import "SFJSON.h"
#import "SFYTTimeline.h"
#import "SFDownloads.h"
#import "SFMediaStore.h"

static SFMediaStore *Store(void) { return [SFDownloads shared].mediaStore; }

// the manifest's ranges: video and audio intersected; nil without both indexes
static NSArray *RangesOf(NSDictionary *m, NSDictionary *index) {
    NSArray *all = nil;
    for (NSString *k in @[@"video", @"audio"]) {
        NSDictionary *t = dict(m[k]);
        NSString *tid = str(t[@"id"]);
        NSArray *ix = tid ? index[tid] : nil;
        if (![ix isKindOfClass:[NSArray class]] || !ix.count) return nil;
        NSArray *r = SFYTStoredRanges(ix, [t[@"total"] longLongValue], [m[@"duration"] doubleValue], [Store() extentsOf:tid]);
        all = all ? SFRangesIntersect(all, r) : r;
    }
    return all;
}

@implementation SFYTEngine (Timeline)

- (void)storedRangesOfSession:(NSString *)sid done:(void (^)(NSArray *))done {
    NSString *vid = sid ? [self videoOfSession:sid] : nil;
    if (!vid.length) { done(nil); return; }
    NSString *item = [@"yt:" stringByAppendingString:vid];
    BOOL stored = [self isStoredSession:sid];
    SFBackground(^{   // the manifest and extents: the store's queue
        NSDictionary *m = [Store() manifestOf:item];
        NSDictionary *have = dict(m[@"index"]) ?: @{};
        NSArray *r = RangesOf(m, have);
        if (r || stored || !m) { SFMain(^{ done(r); }); return; }
        // not both indexes yet: ask the engine (known once each track's init segment arrived)
        [self request:@"index" args:@[sid] timeout:5 done:^(id v, NSError *e) {
            NSDictionary *got = dict(v);
            NSMutableDictionary *byId = [have mutableCopy];
            for (NSString *key in got) {
                NSString *tid = str([self trackInfo:key session:sid][@"id"]);
                NSMutableArray *ix = [NSMutableArray new];
                for (NSDictionary *en in [got[key] isKindOfClass:[NSArray class]] ? got[key] : @[])
                    if ([en isKindOfClass:[NSDictionary class]] && en[@"off"] && en[@"ms"]) [ix addObject:@[en[@"off"], en[@"ms"]]];
                if (tid && ix.count) byId[tid] = ix;
            }
            SFBackground(^{
                if (byId.count > have.count) {   // kept for the next time and for the stored session
                    NSMutableDictionary *mm = [[Store() manifestOf:item] mutableCopy];
                    if (mm) { mm[@"index"] = byId; [Store() setManifest:mm forItem:item]; }
                }
                NSArray *rr = RangesOf(m, byId);
                SFMain(^{ done(rr); });
            });
        }];
    });
}

@end
