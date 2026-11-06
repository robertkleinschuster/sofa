// The SFApp adapter of YouTube: who it is and what it contributes; the work is in its modules
// (SFYouTubeApp.h). Playback hooks: SFYouTubeApp+Playback.m, dev commands: SFYouTubeApp+Dev.m.
#import "SFYouTubeApp.h"
#import "SFYTPages.h"
#import "SFYTWatch.h"
#import "SFYTFeeds.h"
#import "SFYTParser.h"
#import "SFStore.h"
#import "SFYTSabr.h"
#import "SFYTBreaker.h"
#import "SFLounge.h"
#import "SFFollows.h"
#import "SFNet.h"

@implementation SFYouTubeApp

+ (NSString *)appIdentifier { return @"youtube"; }
+ (NSString *)appName { return @"YouTube"; }
+ (NSString *)appSummary { return @"Deine Kanäle, neue Videos, Suche"; }
+ (NSArray *)refPrefixes { return @[@"yt", @"ytlive", @"ytchannel", @"ytplaylist", @"ytfollow", @"ytautodl"]; }
+ (NSArray *)showRefPrefixes { return @[@"ytchannel"]; }
+ (NSColor *)homeTileColor { return SFHex(0xffffff); }
+ (NSInteger)homeTileLogoVariant { return 0; }
+ (NSString *)searchPlaceholder { return @"Videos und Kanäle suchen"; }
+ (BOOL)homeIncludesFollows { return YES; }
+ (BOOL)showsAreChannels { return YES; }   // channels, new videos and downloads are part of homeLoader
+ (void)configureTheme:(SFTheme *)t {
    // Dark, red accents, rounded 16:9 tiles.
    t.wordmark = @"YouTube"; t.logo = @"youtube"; t.logoVariant = 1;
    t.background = SFHex(0x0f0f0f);
    t.backgroundTop = SFHex(0x181818);
    t.surface = SFHex(0x272727);
    t.text = SFHex(0xf1f1f1);
    t.textDim = SFHex(0xaaaaaa);
    t.accent = SFHex(0xff0033);
    t.accentText = SFHex(0xffffff);
    t.focus = SFHex(0xffffff);
    t.corner = 14;
    t.wordmarkColor = t.text; t.progressColor = t.accent;
    t.focusText = SFHex(0x111111);   // white focus
    t.headerMark = SFHeaderMarkPlayPill;
}

+ (void)start {
    [self removeYTDLPLeftovers];
    if (!SFDevMode) [[SFYTSabr shared] start];   // warm session + BotGuard before the first click
}

// yt-dlp was removed on 2026-11-06 (docs/youtube.md): what it kept on disk goes too - its updated
// copies, caches (with the bot-check file's old place), resolved-URL cache and update stamp.
// Idempotent; costs a few stat calls once there is nothing left.
+ (void)removeYTDLPLeftovers {
    NSFileManager *fm = [NSFileManager defaultManager];
    // the bot-check file lived in that cache folder: a running pause moves along (unless the new
    // place already has a state) - losing it sent a request during a pause (2026-11-06 11:11)
    NSString *oldBlock = [[SFSharedCacheDir() stringByAppendingPathComponent:@"yt-dlp"] stringByAppendingPathComponent:@"youtube-block.json"];
    if ([fm fileExistsAtPath:oldBlock] && ![fm fileExistsAtPath:[SFYTBreaker filePath]] && [fm moveItemAtPath:oldBlock toPath:[SFYTBreaker filePath] error:nil])
        SFLog(@"yt: bot-check state moved to %@", [SFYTBreaker filePath].lastPathComponent);
    for (NSString *p in @[[SFAppSupportDir() stringByAppendingPathComponent:@"yt-dlp"], [SFAppSupportDir() stringByAppendingPathComponent:@"yt-dlp.new"],
                          [SFAppSupportDir() stringByAppendingPathComponent:@"yt-dlp.old"], [SFCacheDir() stringByAppendingPathComponent:@"yt-dlp"],
                          [SFSharedCacheDir() stringByAppendingPathComponent:@"yt-dlp"], [SFCacheDir() stringByAppendingPathComponent:@"yt-resolved.json"]])
        if ([fm fileExistsAtPath:p] && [fm removeItemAtPath:p error:nil]) SFLog(@"yt: removed yt-dlp leftover %@", p.lastPathComponent);
    // the PO token server's own log (bgutil, before the sidecar): only the real app wrote it
    NSString *potLog = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Sofa-potserver.log"];
    if (!SFDevInstanceName() && [fm fileExistsAtPath:potLog] && [fm removeItemAtPath:potLog error:nil]) SFLog(@"yt: removed yt-dlp leftover %@", potLog.lastPathComponent);
    if ([[SFStore shared] setting:@"ytdlp.updated"]) [[SFStore shared] setSetting:nil forKey:@"ytdlp.updated"];
}

#pragma mark Pages

+ (SFPageLoader)homeLoader { return [SFYTPages homeLoader]; }
+ (SFPageLoader)searchLoader:(NSString *)q { return [SFYTPages searchLoader:q]; }
+ (void)suggestions:(NSString *)prefix done:(void (^)(NSArray *))done { [SFYTPages suggestions:prefix done:done]; }
+ (SFPageLoader)listLoader:(NSString *)ref title:(NSString *)title {
    return [SFRefPrefix(ref) isEqualToString:@"ytplaylist"] ? [SFYTPages playlistLoader:SFRefID(ref) title:title] : nil;
}
+ (SFPageLoader)showPageLoader:(NSString *)ref title:(NSString *)title {
    return [SFRefPrefix(ref) isEqualToString:@"ytchannel"] ? [SFYTPages channelLoader:SFRefID(ref) title:title] : nil;
}

#pragma mark Items

+ (SFItem *)itemForRef:(NSString *)ref title:(NSString *)title image:(NSString *)image {
    NSString *vid = SFRefID(ref);
    if (![SFRefPrefix(ref) isEqualToString:@"yt"] || vid.length != 11) return nil;
    return [SFYTPages itemForVideoID:vid title:title thumb:image];
}

+ (void)updateStoredItem:(SFItem *)i {
    NSString *vid = [SFRefPrefix(i.identifier) isEqualToString:@"yt"] ? SFRefID(i.identifier) : nil;
    if (!vid.length) return;
    if (!i.image) i.image = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", vid];
    // stored entries carry the small tile picture as backdrop -> TV resolution; a local picture (download) stays
    if (!i.backdrop || [i.backdrop hasPrefix:@"https://i.ytimg.com/vi/"]) i.backdrop = SFYTBackdrop(vid);
}

// description, channel and recommendations in ONE cached request (the same "next" call autoplay
// uses) - only for an online-capable video
+ (void)watchDetailsForItem:(SFItem *)item done:(void (^)(NSArray *, NSDictionary *))done {
    if (item.externalID.length != 11 || ![SFNet isOnline]) return;
    [SFYTWatch watchPageFor:item.externalID done:^(NSArray *related, NSDictionary *details) {
        NSMutableDictionary *d = [details mutableCopy];
        NSString *cid = details[@"channelID"];
        if ([cid hasPrefix:@"UC"]) d[@"showRef"] = [@"ytchannel:" stringByAppendingString:cid];
        done(related, d);
    }];
}

+ (void)upNextForItem:(SFItem *)item done:(void (^)(SFItem *))done {
    if (item.externalID.length != 11) { done(nil); return; }
    [SFYTWatch upNextFor:item.externalID done:done];
}

#pragma mark Channels (shows)

+ (void)feed:(NSString *)ref done:(void (^)(NSArray *, NSError *))done { [SFYTFeeds feed:SFRefID(ref) done:done]; }
// feed checks and downloads wait during a bot-check pause (no request, no attempt used up)
+ (NSTimeInterval)backgroundPausedUntil { return [SFYTBreaker shared].blockedUntil; }
+ (void)showImage:(NSString *)ref done:(void (^)(NSString *))done { [SFYTFeeds avatar:SFRefID(ref) done:done]; }

// channel of a video without a stored channel ID (older watch-later/continue watching/downloads)
+ (void)showRefForItem:(SFItem *)item done:(void (^)(NSString *))done {
    NSString *vid = item.externalID ?: ([item.identifier hasPrefix:@"yt:"] ? SFRefID(item.identifier) : nil);
    if (vid.length != 11) { done(nil); return; }
    [SFYTWatch channelOf:vid done:^(NSString *cid) { done(cid ? [@"ytchannel:" stringByAppendingString:cid] : nil); }];
}

+ (void)resolveChannelURL:(NSString *)url done:(void (^)(NSString *))done { [SFYTWatch resolveChannelURL:url done:done]; }

#pragma mark Home contributions

// Home "Highlights": the standout new videos of the followed channels - no request: the feeds are
// loaded anyway and their RSS carries each video's views. Standout = far above the channel's usual
// (views / median of its recent videos), so a small channel's hit counts like a big one's;
// at most one per channel, from the last 7 days.
+ (void)homeFeatures:(void (^)(NSDictionary *))done {
    NSMutableDictionary *byChannel = [NSMutableDictionary new];
    for (SFItem *i in [[SFFollows shared] latest:2000 source:[self appIdentifier]]) {
        NSString *k = i.showRef ?: i.channel;
        if (k) byChannel[k] = [(byChannel[k] ?: @[]) arrayByAddingObject:i];
    }
    NSMutableArray *picks = [NSMutableArray new];   // @[score, item]
    NSDate *week = [NSDate dateWithTimeIntervalSinceNow:-7 * 86400];
    for (NSArray *items in byChannel.allValues) {
        NSMutableArray *views = [NSMutableArray new];
        for (SFItem *i in items) if (i.viewCount > 0) [views addObject:@(i.viewCount)];
        if (views.count < 5) continue;   // too little history to say what is usual
        [views sortUsingSelector:@selector(compare:)];
        double median = [views[views.count / 2] doubleValue];
        SFItem *best = nil; double bestScore = 0;
        for (SFItem *i in items) {
            if (i.viewCount <= 0 || !i.date || [i.date compare:week] == NSOrderedAscending) continue;
            // plain ratio: a young video has had less time, so one that already beats the median is a clear signal
            double score = i.viewCount / median;
            if (score > bestScore) { bestScore = score; best = i; }
        }
        if (best && bestScore >= 1.5) [picks addObject:@[@(bestScore), best]];
    }
    [picks sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    NSMutableArray *top = [NSMutableArray new];
    for (NSArray *p in picks) if (top.count < 8) [top addObject:p[1]];
    SFLog(@"home features: youtube %lu standout of %lu channels", (unsigned long)top.count, (unsigned long)byChannel.count);
    done(@{SFHomeTopicHighlights: top});
}

// Home: followed channels as round avatars, after Sofa's own sections
+ (NSArray *)homeSections {
    return @[[SFHomeSection section:@"youtube.channels" title:@"Meine Kanäle" priority:SFHomePriorityApp style:SFTileStyleCircle items:^NSArray *{
        NSArray *f = [[SFFollows shared] follows:[self appIdentifier]];
        for (SFItem *i in f) i.style = SFTileStyleCircle;
        return f;
    }]];
}

#pragma mark Phone remote ("Mit TV verbinden")

+ (void)startRemoteWithHost:(id<SFPlayerHost>)host {
    __weak id<SFPlayerHost> wh = host;
    [SFLounge shared].commandHandler = ^(NSString *cmd, NSDictionary *args) { SFYTRemoteCommand(wh, cmd, args); };
    [SFLounge shared].playerProvider = ^id { return [wh topPlayer]; };
    [[SFLounge shared] start];
}
+ (void)stopRemote { [[SFLounge shared] stop]; }
+ (NSString *)remoteStatus:(BOOL *)paused {
    SFLounge *l = [SFLounge shared];
    if (paused) *paused = l.paused;
    NSArray *n = l.remoteNames;
    return l.paused ? @"Handy pausiert" : n.count ? [@"Handy: " stringByAppendingString:[n componentsJoinedByString:@", "]] : nil;
}
+ (NSString *)remoteStatusNotification { return SFLoungeRemotesDidChangeNotification; }
@end
