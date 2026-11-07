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

// title, channel, description of a video known only by its ID (phone queue, dev): from the watch page
// ("next", as a browser opening it) - never a player request of our own: that is the engine's job,
// with a PO token, when the video actually plays (and brings the duration then)
+ (void)fillDetails:(SFItem *)item done:(dispatch_block_t)done {
    if (item.localPath || !item.externalID) { if (done) done(); return; }
    SFLog(@"youtube: details of %@", item.externalID);   // one watch page per video (test-playback 8c counts them)
    SFYTCall(@"next", @{@"videoId": item.externalID}, 1800, ^(id j, NSError *e) {
        NSDictionary *d = [SFYTParser watchDetailsIn:j];
        if (d.count) {
            item.title = d[@"title"] ?: item.title;
            item.channel = d[@"channel"] ?: item.channel;
            item.subtitle = item.channel;
            item.plot = d[@"description"] ?: item.plot;
            if ([d[@"channelID"] length]) item.showRef = [@"ytchannel:" stringByAppendingString:d[@"channelID"]];
            if ([d[@"live"] boolValue]) {
                item.kind = SFItemLive; item.badge = @"LIVE";
                item.resolverRef = [@"ytlive:" stringByAppendingString:item.externalID];
            }
            item.image = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", item.externalID];
            item.backdrop = SFYTBackdrop(item.externalID);
        }
        SFMain(^{ if (done) done(); });
    });
}

+ (void)channelOf:(NSString *)vid done:(void (^)(NSString *))done {
    SFYTCall(@"next", @{@"videoId": vid}, 1800, ^(id j, NSError *e) {   // the same cached answer as the info panel
        NSString *cid = [SFYTParser watchDetailsIn:j][@"channelID"];
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
