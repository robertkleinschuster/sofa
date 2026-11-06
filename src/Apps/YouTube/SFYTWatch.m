#import "SFYTWatch.h"
#import "SFApp.h"
#import "SFYTInnerTube.h"
#import "SFYTParser.h"
#import "SFYTPages.h"
#import "SFStore.h"

@implementation SFYTWatch

// docs/youtube.md §3.4: related videos + metadata the browse lists lack (description, channel ID, avatar)
+ (void)watchPageFor:(NSString *)vid done:(void (^)(NSArray *, NSDictionary *))done {
    if (vid.length != 11) { SFMain(^{ done(@[], nil); }); return; }
    SFYTCall(@"next", @{@"videoId": vid}, 1800, ^(id j, NSError *e) {
        NSArray *related = [SFYTPages shown:[SFYTParser relatedIn:j video:vid]];
        NSDictionary *details = [SFYTParser watchDetailsIn:j];
        SFMain(^{ done(related, details); });
    });
}

+ (void)upNextFor:(NSString *)vid done:(void (^)(SFItem *))done {
    [self watchPageFor:vid done:^(NSArray *related, NSDictionary *details) {
        SFItem *pick = nil;
        for (SFItem *i in related) if (![[SFStore shared] watched:i.identifier]) { pick = i; break; }   // already watched
        done(pick);
    }];
}

+ (void)fillDetails:(SFItem *)item done:(dispatch_block_t)done {
    if (item.localPath || !item.externalID) { if (done) done(); return; }
    SFYTCall(@"player", @{@"videoId": item.externalID, @"contentCheckOk": @YES, @"racyCheckOk": @YES}, 3600, ^(id j, NSError *e) {
        NSDictionary *vd = dict(dict(j)[@"videoDetails"]);
        if (vd) {
            item.title = str(vd[@"title"]) ?: item.title;
            item.channel = str(vd[@"author"]);
            item.subtitle = item.channel;
            item.plot = str(vd[@"shortDescription"]);
            item.duration = [str(vd[@"lengthSeconds"]) doubleValue];
            if ([vd[@"isLive"] boolValue] || ([vd[@"isLiveContent"] boolValue] && item.duration == 0)) {
                item.kind = SFItemLive; item.badge = @"LIVE";
                item.resolverRef = [@"ytlive:" stringByAppendingString:item.externalID];
            }
            item.image = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", item.externalID];
            item.backdrop = SFYTBackdrop(item.externalID);
        }
        if (done) done();
    });
}

+ (void)channelOf:(NSString *)vid done:(void (^)(NSString *))done {
    SFYTCall(@"player", @{@"videoId": vid}, 86400, ^(id j, NSError *e) {
        NSString *cid = str(SFYTPath(j, @"videoDetails.channelId"));
        SFMain(^{ done([cid hasPrefix:@"UC"] ? cid : nil); });
    });
}

+ (void)resolveChannelURL:(NSString *)url done:(void (^)(NSString *))done {
    SFYTCall(@"navigation/resolve_url", @{@"url": url}, 86400, ^(id j, NSError *e) {
        NSString *be = str(SFYTPath(j, @"endpoint.browseEndpoint.browseId"));
        SFMain(^{ done([be hasPrefix:@"UC"] ? be : nil); });
    });
}
@end
