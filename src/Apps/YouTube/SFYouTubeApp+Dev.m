// YouTube's dev commands (sofa-dev FIFO, SFApp handleDevCommand).
#import "SFYouTubeApp.h"
#import "SFYTPages.h"
#import "SFYTWatch.h"
#import "SFYTFeeds.h"
#import "SFYTParser.h"
#import "SFYTBreaker.h"
#import "SFPairScreen.h"
#import "SFPlayerScreen.h"
#import "SFBrowseScreen.h"

// One line per parsed item, keys sorted; dates as age in hours (InnerTube gives relative dates,
// so the age is what stays stable between runs) - tools/test-yt-parse compares it with the
// recorded output of tests/fixtures/youtube.
static NSString *canonicalItem(SFItem *i) {
    NSMutableDictionary *d = [[i dictionaryRepresentation] mutableCopy];
    [d removeObjectForKey:@"date"];
    if (i.date) d[@"ageHours"] = @(lround(-i.date.timeIntervalSinceNow / 3600));
    NSMutableArray *parts = [NSMutableArray new];
    for (NSString *k in [d.allKeys sortedArrayUsingSelector:@selector(compare:)]) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, d[k]]];
    return [parts componentsJoinedByString:@" | "];
}
static NSString *parseDump(NSString *kind, NSData *data) {
    id j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSMutableString *o = [NSMutableString new];
    NSArray *items = @[]; NSMutableArray *channels = [NSMutableArray new]; NSString *cont = nil;
    if ([kind isEqualToString:@"feed"]) items = [SFYTFeeds videosInUploads:j];
    else if ([kind isEqualToString:@"header"]) [o appendFormat:@"avatar %@\n", [SFYTParser channelHeaderIn:j][@"avatar"]];
    else items = [SFYTParser itemsIn:j continuation:&cont channels:channels];
    for (SFItem *i in items) [o appendFormat:@"item %@\n", canonicalItem(i)];
    for (SFItem *c in channels) [o appendFormat:@"channel %@\n", canonicalItem(c)];
    [o appendFormat:@"continuation %@\n", cont.length ? @"yes" : @"no"];
    return o;
}

@implementation SFYouTubeApp (Dev)

+ (BOOL)handleDevCommand:(NSString *)cmd arg:(NSString *)arg host:(id<SFPlayerHost>)host {
    SFNavigator *nav = [host nav];
    if ([cmd isEqualToString:@"open"] && [arg isEqualToString:@"pair"]) {   // pairing code screen
        [nav push:[[SFPairScreen alloc] initWithTheme:[SFTheme themeNamed:@"youtube"]]];
    } else if ([cmd isEqualToString:@"open"] && [arg hasPrefix:@"ytchannel:"]) {   // any channel page: ytchannel:<ID>[|<title>]
        SFItem *f = [SFItem new]; f.kind = SFItemFolder; f.themeName = @"youtube"; f.source = @"youtube";
        NSArray *pt = [[arg substringFromIndex:10] componentsSeparatedByString:@"|"];
        f.pageLoader = [SFYTPages channelLoader:pt[0] title:pt.count > 1 ? pt[1] : @"Kanal"];
        SFOpenItem(nav, f, nil, 0);
    } else if ([cmd isEqualToString:@"ytparse"] && arg) {   // parser golden test: ytparse <list|feed|header> <in.json> <out.txt>
        NSArray *a = [arg componentsSeparatedByString:@" "];
        if (a.count != 3) { SFLog(@"dev: ytparse needs <kind> <in> <out>"); return YES; }
        [parseDump(a[0], [NSData dataWithContentsOfFile:a[1]]) writeToFile:a[2] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        SFLog(@"dev: ytparse written %@", a[2]);
    } else if ([cmd isEqualToString:@"open"] && [arg hasPrefix:@"yt:"]) {   // play a video from the start (startup tests)
        SFItem *it = [SFYTPages itemForVideoID:[arg substringFromIndex:3] title:nil thumb:nil];
        [SFYTWatch fillDetails:it done:^{
            SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:it queue:nil index:0];
            ps.startFromBeginning = YES;
            [host presentPlayer:ps];
        }];
    } else if ([cmd isEqualToString:@"play"] && [arg hasPrefix:@"ytlive:"]) {   // like a "Jetzt live" tile (no resume, live end handling)
        SFItem *it = [SFItem new];
        it.kind = SFItemLive; it.identifier = arg; it.title = arg; it.resolverRef = arg;
        SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:it queue:nil index:0];
        ps.startFromBeginning = YES;
        [host presentPlayer:ps];
    } else if ([cmd isEqualToString:@"lounge"] && arg) {   // simulate a phone command: lounge <cmd> <json>
        NSRange sp = [arg rangeOfString:@" "];
        NSString *lc = sp.location == NSNotFound ? arg : [arg substringToIndex:sp.location];
        id j = sp.location == NSNotFound ? @{} : [NSJSONSerialization JSONObjectWithData:[[arg substringFromIndex:sp.location + 1] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        SFYTRemoteCommand(host, lc, [j isKindOfClass:[NSDictionary class]] ? j : @{});
    } else if ([cmd isEqualToString:@"ytfeed"] && [arg hasPrefix:@"UC"]) {   // feed of a channel with its dates (RSS exact vs relative)
        [SFYTFeeds devFeed:arg];
    } else if ([cmd isEqualToString:@"ytblock"] && arg) {   // simulate a bot-check pause for <secs> (this instance only)
        [[SFYTBreaker shared] simulateBlockForTesting:arg.doubleValue];
    } else return NO;
    return YES;
}
@end
