// Library pages of the media core, shared by every app and the home screen: local shows,
// history, and the frame that adds followed shows to an app's start page.
// Downloads + "Platz schaffen": SFLibraryPages+Downloads.m.
#import "SFLibraryPages.h"
#import "SFStore.h"
#import "SFDownloads.h"
#import "SFFollows.h"
#import "SFApp.h"

@implementation SFLibraryPages

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
    i.image = SFSourceShowsAreChannels(sh.source) ? (sh.poster ?: ((SFItem *)sh.episodes.firstObject).image) : ((SFItem *)sh.episodes.firstObject).image;
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

@end
