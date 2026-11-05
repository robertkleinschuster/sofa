// Home screen (app tiles, continue watching, new episodes …), history and the start pages of the
// source apps. Settings/phone: SFHome+Settings.m; downloads page: SFHome+Downloads.m.
#import "SFHome+Private.h"
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
            [apps addObject:[self downloadsTile:nil]];
            [apps addObject:[self historyTile]];
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
                if ([f.source isEqualToString:@"youtube"]) { f.style = SFTileStyleCircle; [channels addObject:f]; }
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
    [self reloadOnLibraryChange:s];
    return s;
}

+ (void)reloadOnLibraryChange:(SFBrowseScreen *)s {
    s.reloadNotification = SFLibraryDidChangeNotification;   // the screen manages the observer itself
}

+ (SFItem *)showTile:(SFShow *)sh {
    SFItem *i = [SFItem new];
    i.kind = SFItemFolder;
    i.identifier = [@"show:" stringByAppendingString:sh.name];
    i.title = sh.name;
    i.channel = sh.name;
    i.subtitle = SFDotJoin([NSString stringWithFormat:@"%lu %@", (unsigned long)sh.episodes.count, sh.episodes.count == 1 ? @"Folge" : @"Folgen"], SFFormatDateShort(sh.latest));
    i.image = [sh.source isEqualToString:@"youtube"] ? (sh.poster ?: ((SFItem *)sh.episodes.firstObject).image) : ((SFItem *)sh.episodes.firstObject).image;
    i.backdrop = ((SFItem *)sh.episodes.firstObject).image;
    i.plot = ((SFItem *)sh.episodes.firstObject).title ? [NSString stringWithFormat:@"Neueste Folge: %@", ((SFItem *)sh.episodes.firstObject).title] : nil;
    i.date = sh.latest;
    i.source = sh.source;
    i.themeName = sh.source;
    i.pageLoader = [self showLoader:sh.name source:sh.source];
    return i;
}

+ (SFPageLoader)showLoader:(NSString *)showName source:(NSString *)source {
    return ^(SFPageDone done) {
        [[SFLibrary shared] whenReady:^{
            SFShow *sh = [[SFLibrary shared] showNamed:showName source:source];
            if (!sh) { done(nil, SFError(@"Sendung nicht mehr vorhanden.")); return; }
            NSMutableArray *shelves = [NSMutableArray new];
            NSMutableArray *started = [NSMutableArray new];
            for (SFItem *e in sh.episodes) {
                double p = [[SFStore shared] progressFor:e.identifier];
                if (p > 0 && p < 1) [started addObject:e];
            }
            if (started.count) [shelves addObject:[SFShelf shelf:@"Weiterschauen" style:SFTileStyleLandscape items:started]];
            [shelves addObject:[SFShelf grid:[NSString stringWithFormat:@"Alle Folgen (%lu)", (unsigned long)sh.episodes.count]
                                       style:SFTileStyleLandscape items:sh.episodes]];
            SFPage *p = [SFPage page:sh.name theme:sh.source shelves:shelves];
            p.backdrop = sh.fanart;
            done(p, nil);
        }];
    };
}

#pragma mark History (everything played, to find it again)

+ (SFPageLoader)historyLoader {
    return ^(SFPageDone done) {
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDate *today = [cal startOfDayForDate:[NSDate date]];
        NSDate *yesterday = [today dateByAddingTimeInterval:-86400], *week = [today dateByAddingTimeInterval:-6 * 86400];
        NSArray *names = @[@"Heute", @"Gestern", @"Diese Woche", @"Früher"];
        NSMutableArray *groups = [NSMutableArray arrayWithArray:@[[NSMutableArray new], [NSMutableArray new], [NSMutableArray new], [NSMutableArray new]]];
        static NSDateFormatter *tf;
        if (!tf) { tf = [NSDateFormatter new]; tf.dateFormat = @"HH:mm"; }
        for (NSDictionary *h in [[SFStore shared] history:300]) {
            SFItem *e = [h[@"item"] copy];
            NSDate *when = [NSDate dateWithTimeIntervalSince1970:[h[@"updated"] doubleValue]];
            NSInteger g = [when compare:today] != NSOrderedAscending ? 0 : [when compare:yesterday] != NSOrderedAscending ? 1 : [when compare:week] != NSOrderedAscending ? 2 : 3;
            NSString *state = [h[@"watched"] boolValue] ? @"gesehen"
                            : ([h[@"pos"] doubleValue] > 0 && e.duration > 0 ? [NSString stringWithFormat:@"noch %@", SFFormatDuration(MAX(0, e.duration - [h[@"pos"] doubleValue]))] : nil);
            NSString *when2 = g < 2 ? [tf stringFromDate:when] : SFFormatDateShort(when);
            NSMutableArray *sub = [NSMutableArray new];
            if (e.channel.length) [sub addObject:e.channel];
            [sub addObject:when2];
            if (state) [sub addObject:state];
            e.subtitle = [sub componentsJoinedByString:@" · "];
            e.style = SFTileStyleLandscape;
            [groups[g] addObject:e];
        }
        NSMutableArray *shelves = [NSMutableArray new];
        for (NSUInteger g = 0; g < 4; g++) if ([groups[g] count])
            [shelves addObject:g < 3 ? [SFShelf shelf:names[g] style:SFTileStyleLandscape items:groups[g]] : [SFShelf grid:names[g] style:SFTileStyleLandscape items:groups[g]]];
        SFPage *p = [SFPage page:@"Verlauf" theme:@"home" shelves:shelves];
        if (!shelves.count) p.emptyText = @"Noch nichts angesehen. Alles, was du abspielst, findest du hier wieder.";
        done(p, nil);
    };
}

+ (SFItem *)historyTile {
    SFItem *i = [SFItem new];
    i.kind = SFItemFolder;
    i.identifier = @"history:";
    i.title = @"Verlauf";
    i.subtitle = @"Zuletzt angesehen";
    i.plot = @"Alles, was du zuletzt abgespielt hast – aus allen Apps, nach Tagen sortiert. So findest du Videos schnell wieder.";
    i.themeName = @"home";
    i.style = SFTileStyleApp; i.tint = SFHex(0x34495e);
    i.pageLoader = [self historyLoader];
    return i;
}

// Add followed content to a Mediathek's online start page (follows concept):
//   Weiterschauen · Neue Folgen (followed shows, streamed) · Meine Sendungen (+ downloads tile at the end) · Mediathek …
// Downloads are only a state of a video (fast start, offline) – not a world of their own.
+ (SFPageLoader)withLocalShows:(SFPageLoader)online source:(NSString *)source {
    return ^(SFPageDone done) {
        online(^(SFPage *page, NSError *err) {
            [[SFLibrary shared] whenReady:^{
                SFFollows *fo = [SFFollows shared];
                NSMutableArray *mine = [NSMutableArray new];
                for (SFItem *f in [fo follows:source]) { f.style = SFTileStyleWide; [mine addObject:f]; }
                SFDownloads *dl = [SFDownloads shared];
                BOOL anyDL = [dl bytesUsedFor:source] > 0;
                for (SFItem *a in [dl active]) if ([a.source isEqualToString:source]) anyDL = YES;
                if (anyDL) [mine addObject:[self downloadsTile:source]];
                NSArray *news = [fo latest:30 source:source];
                if (!page && !mine.count) { done(nil, err); return; }
                SFPage *p = page ?: [SFPage page:nil theme:source shelves:@[]];
                NSMutableArray *sh = [p.shelves mutableCopy] ?: [NSMutableArray new];
                NSUInteger at = sh.count ? 1 : 0;   // the app opens on its own content
                for (NSUInteger k = 0; k < sh.count; k++) if ([[sh[k] title] isEqualToString:@"Weiterschauen"]) at = k + 1;
                if (mine.count) [sh insertObject:[SFShelf shelf:@"Meine Sendungen" style:SFTileStyleWide items:mine] atIndex:MIN(at, sh.count)];
                if (news.count) [sh insertObject:[SFShelf shelf:@"Neue Folgen" style:SFTileStyleLandscape items:news] atIndex:MIN(at, sh.count)];
                if (!page && err) p.emptyText = @"Die Mediathek ist gerade nicht erreichbar.";
                p.shelves = sh;
                done(p, nil);
            }];
        });
    };
}

// An app's start page: the app's own shelves (SFApp homeLoader) framed by the shell – followed
// shows/new episodes (unless the app shows them itself), "Später ansehen", the "Suche" tile and
// the header search button.
+ (SFScreen *)appScreen:(NSString *)source {
    Class<SFApp> app = [SFAppRegistry appNamed:source];
    SFTheme *t = [SFTheme themeNamed:source];
    SFPageLoader online = [app homeLoader];
    if (!([app respondsToSelector:@selector(homeIncludesFollows)] && [app homeIncludesFollows]))
        online = [self withLocalShows:online source:source];
    online = SFWithWatchLater(online, source);   // shelf "Später ansehen" (own watch list)
    online = SFWithSearchTile(online, source);   // tile "Suche"
    SFBrowseScreen *c = [[SFBrowseScreen alloc] initWithLoader:online theme:t];
    c.showsHero = YES;
    if (SFHasSearch(source)) c.searchSource = source;   // button "Suche" in the header
    c.restoreKey = [@"app:" stringByAppendingString:source];
    [self reloadOnLibraryChange:c];   // keep the downloads shelf current
    return c;
}
@end
