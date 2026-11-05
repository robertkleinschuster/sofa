// Home screen (app tiles, continue watching, new episodes …) and the frame of the apps' start
// pages. Settings: SFHome+Settings.m. Library pages (shows, history, downloads): src/Browse.
#import "SFHome.h"
#import "SFLibraryPages.h"
#import "SFStore.h"
#import "SFApp.h"
#import "SFSearch.h"
#import "SFWatchLater.h"
#import "SFDownloads.h"
#import "SFFollows.h"

@implementation SFHome

+ (SFItem *)appTile:(Class<SFApp>)app {
    SFItem *i = [SFItem new];
    i.kind = SFItemAction;
    i.identifier = [@"app:" stringByAppendingString:[app appIdentifier]];
    i.title = [app appName];
    i.plot = [app appSummary];
    i.themeName = [app appIdentifier];
    i.tint = [app homeTileColor];
    i.logo = [app appIdentifier];
    i.logoVariant = [app homeTileLogoVariant];
    i.style = SFTileStyleApp;
    return i;
}

// Rows mixed from several apps say where each item comes from (the app's logo on the tile).
static NSArray *marked(NSArray *items) {
    NSMutableArray *r = [NSMutableArray new];
    for (SFItem *i in items) { SFItem *c = [i copy]; c.showsSourceMark = YES; [r addObject:c]; }
    return r;
}

// Sofa's own home sections + the apps' contributions (docs/architecture.md, Home composition)
+ (NSArray *)homeSections {
    NSMutableArray *r = [NSMutableArray new];
    // --- mine: what I am watching, what is new in what I follow
    [r addObject:[SFHomeSection section:@"continue" title:@"Weiterschauen" priority:SFHomePriorityContinue style:SFTileStyleLandscape items:^NSArray *{
        return marked([[SFStore shared] continueWatching:20 source:nil]);
    }]];
    // followed content (follows concept): stream new episodes, pages online; downloads live in the tile "Downloads"
    [r addObject:[SFHomeSection section:@"new" title:@"Neue Folgen" priority:SFHomePriorityNew style:SFTileStyleLandscape items:^NSArray *{
        NSArray *latest = [[SFFollows shared] latest:40 source:nil];
        if (latest.count) return marked(latest);
        // nothing followed yet / first refresh running: show downloaded content
        latest = [[NSArray alloc] initWithArray:[[SFLibrary shared] latestEpisodes:40 source:nil] copyItems:YES];
        for (SFItem *e in latest) e.subtitle = SFDotJoin(e.channel, SFFormatDateShort(e.date));
        return marked(latest);
    }]];
    // --- the apps (and Sofa's own places)
    [r addObject:[SFHomeSection section:@"apps" title:nil priority:SFHomePriorityApps style:SFTileStyleApp items:^NSArray *{
        NSMutableArray *apps = [NSMutableArray new];
        for (Class app in [SFAppRegistry apps]) [apps addObject:[self appTile:app]];
        [apps addObject:[SFLibraryPages downloadsTile:nil]];
        [apps addObject:[SFLibraryPages historyTile]];
        [apps addObject:[self settingsTile]];
        return apps;
    }]];
    // --- discover: what the apps feature, merged across apps (SFHomeFeatures)
    [r addObject:[SFHomeSection section:@"live" title:@"Jetzt live" priority:SFHomePriorityLive style:SFTileStyleLandscape items:^NSArray *{
        return [[SFHomeFeatures shared] itemsForTopic:SFHomeTopicLive];
    }]];
    [r addObject:[SFHomeSection section:@"news" title:@"Nachrichten" priority:SFHomePriorityNews style:SFTileStyleLandscape items:^NSArray *{
        return [[SFHomeFeatures shared] itemsForTopic:SFHomeTopicNews];
    }]];
    [r addObject:[SFHomeSection section:@"highlights" title:@"Highlights" priority:SFHomePriorityHighlights style:SFTileStyleLandscape items:^NSArray *{
        return [[SFHomeFeatures shared] itemsForTopic:SFHomeTopicHighlights];
    }]];
    // --- my lists
    [r addObject:[SFHomeSection section:@"later" title:@"Später ansehen" priority:SFHomePriorityWatchLater style:SFTileStyleLandscape items:^NSArray *{
        return marked([[SFWatchLater shared] items:nil]);
    }]];
    // followed shows; apps whose shows are channels present theirs in their own section (homeSections)
    [r addObject:[SFHomeSection section:@"follows" title:@"Meine Sendungen" priority:SFHomePriorityFollows style:SFTileStyleLandscape items:^NSArray *{
        NSMutableArray *tv = [NSMutableArray new];
        for (SFItem *f in [[SFFollows shared] follows:nil]) {
            if (SFSourceShowsAreChannels(f.source)) continue;
            f.style = SFTileStyleLandscape; [tv addObject:f];
        }
        return marked(tv);
    }]];
    for (Class<SFApp> app in [SFAppRegistry apps])
        if ([app respondsToSelector:@selector(homeSections)]) [r addObjectsFromArray:[app homeSections]];
    return r;
}

+ (SFScreen *)homeScreen {
    SFBrowseScreen *s = [[SFBrowseScreen alloc] initWithLoader:^(SFPageDone done) {
        [[SFLibrary shared] whenReady:^{
            NSArray *shelves = [SFHomeSection shelvesFrom:[self homeSections]];
            SFPage *p = [SFPage page:nil theme:@"home" shelves:shelves];
            done(p, nil);
        }];
    } theme:[SFTheme themeNamed:@"home"]];
    s.showsHero = YES;
    __weak SFBrowseScreen *ws = s;
    s.onSelect = ^(SFItem *item, NSArray *items, NSUInteger idx) {
        if ([item.identifier hasPrefix:@"app:"] && !item.action) {
            [ws.navigator push:[SFHome appScreen:item.themeName]];
            return;
        }
        SFOpenItem(ws.navigator, item, items, idx);
    };
    [SFLibraryPages reloadOnLibraryChange:s];
    [s addReloadNotification:SFHomeFeaturesDidChangeNotification];   // live/highlights rows refreshed
    return s;
}

// An app's start page: the app's own shelves (SFApp homeLoader) framed by the shell – followed
// shows/new episodes (unless the app shows them itself), "Später ansehen", the "Suche" tile and
// the header search button.
+ (SFScreen *)appScreen:(NSString *)source {
    Class<SFApp> app = [SFAppRegistry appNamed:source];
    if (!app) return [self homeScreen];   // unknown/removed app (stale restore key, dev command)
    SFTheme *t = [SFTheme themeNamed:source];
    SFPageLoader online = [app homeLoader];
    if (!([app respondsToSelector:@selector(homeIncludesFollows)] && [app homeIncludesFollows]))
        online = [SFLibraryPages withLocalShows:online source:source];
    online = SFWithWatchLater(online, source);   // shelf "Später ansehen" (own watch list)
    online = SFWithSearchTile(online, source);   // tile "Suche"
    SFBrowseScreen *c = [[SFBrowseScreen alloc] initWithLoader:online theme:t];
    c.showsHero = YES;
    if (SFHasSearch(source)) c.searchSource = source;   // button "Suche" in the header
    c.restoreKey = [@"app:" stringByAppendingString:source];
    [SFLibraryPages reloadOnLibraryChange:c];   // keep the downloads shelf current
    return c;
}
@end
