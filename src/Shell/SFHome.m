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

+ (SFScreen *)homeScreen {
    SFBrowseScreen *s = [[SFBrowseScreen alloc] initWithLoader:^(SFPageDone done) {
        [[SFLibrary shared] whenReady:^{
            NSMutableArray *apps = [NSMutableArray new];
            for (Class app in [SFAppRegistry apps]) [apps addObject:[self appTile:app]];
            [apps addObject:[SFLibraryPages downloadsTile:nil]];
            [apps addObject:[SFLibraryPages historyTile]];
            [apps addObject:[self settingsTile]];
            // Kodi tile removed (user 2026-11-03); phone settings belong in the YouTube app (Mehr → Handy)

            NSMutableArray *shelves = [NSMutableArray new];
            [shelves addObject:[SFShelf shelf:nil style:SFTileStyleApp items:apps]];
            NSArray *cont = [[SFStore shared] continueWatching:20 source:nil];
            if (cont.count) [shelves addObject:[SFShelf shelf:@"Weiterschauen" style:SFTileStyleLandscape items:cont]];
            NSArray *later = [[SFWatchLater shared] items:nil];
            if (later.count) [shelves addObject:[SFShelf shelf:@"Später ansehen" style:SFTileStyleLandscape items:later]];
            // followed content (follows concept): stream new episodes, pages online; downloads live in the tile "Downloads"
            SFFollows *fo = [SFFollows shared];
            NSArray *latest = [fo latest:40 source:nil];
            if (!latest.count) {   // nothing followed yet / first refresh running: show downloaded content
                latest = [[NSArray alloc] initWithArray:[[SFLibrary shared] latestEpisodes:40 source:nil] copyItems:YES];
                for (SFItem *e in latest) e.subtitle = SFDotJoin(e.channel, SFFormatDateShort(e.date));
            }
            if (latest.count) [shelves addObject:[SFShelf shelf:@"Neue Folgen" style:SFTileStyleLandscape items:latest]];
            NSMutableArray *channels = [NSMutableArray new], *tv = [NSMutableArray new];
            for (SFItem *f in [fo follows:nil]) {
                if (SFSourceShowsAreChannels(f.source)) { f.style = SFTileStyleCircle; [channels addObject:f]; }
                else { f.style = SFTileStyleLandscape; [tv addObject:f]; }
            }
            if (tv.count) [shelves addObject:[SFShelf shelf:@"Meine Sendungen" style:SFTileStyleLandscape items:tv]];
            if (channels.count) [shelves addObject:[SFShelf shelf:@"Meine Kanäle" style:SFTileStyleCircle items:channels]];
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
    return s;
}

// An app's start page: the app's own shelves (SFApp homeLoader) framed by the shell – followed
// shows/new episodes (unless the app shows them itself), "Später ansehen", the "Suche" tile and
// the header search button.
+ (SFScreen *)appScreen:(NSString *)source {
    Class<SFApp> app = [SFAppRegistry appNamed:source];
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
