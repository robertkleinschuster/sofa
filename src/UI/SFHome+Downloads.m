// SFHome – Downloads-Seite (Offline-Bestand) und die Kachel, die sie öffnet.
#import "SFHome+Private.h"
#import "SFDownloads.h"
#import "SFIconArt.h"

@implementation SFHome (Downloads)

#pragma mark Downloads (Offline-Bestand, wie „Downloads“ bei YouTube Premium)

+ (SFPageLoader)downloadsLoader:(NSString *)source {
    return ^(SFPageDone done) {
        SFDownloads *dl = [SFDownloads shared];
        NSMutableArray *shelves = [NSMutableArray new];
        NSMutableArray *active = [NSMutableArray new];
        for (SFItem *i in [dl active]) {
            if (source && ![i.source isEqualToString:source]) continue;
            SFItem *c = [i copy];
            double p = 0;
            SFDLState st = [dl stateFor:c.identifier progress:&p];
            c.subtitle = [NSString stringWithFormat:@"%@ · %@", c.channel ?: @"", st == SFDLRunning ? @"wird geladen" : @"wartet"];
            [active addObject:c];
        }
        if (active.count) [shelves addObject:[SFShelf shelf:@"Wird geladen" style:SFTileStyleLandscape items:active]];
        NSArray *latest = [[NSArray alloc] initWithArray:[[SFLibrary shared] latestEpisodes:40 source:source] copyItems:YES];
        for (SFItem *e in latest) e.subtitle = [NSString stringWithFormat:@"%@ · %@", e.channel ?: @"", SFFormatDateShort(e.date)];
        if (latest.count) [shelves addObject:[SFShelf shelf:@"Zuletzt geladen" style:SFTileStyleLandscape items:latest]];
        NSMutableArray *shows = [NSMutableArray new];
        for (SFShow *sh in [[SFLibrary shared] showsForSource:source]) [shows addObject:[self showTile:sh]];
        if (shows.count) [shelves addObject:[SFShelf grid:@"Sendungen und Kanäle" style:SFTileStyleLandscape items:shows]];
        SFPage *p = [SFPage page:@"Downloads" theme:source ?: @"home" shelves:shelves];
        p.subtitle = [dl storageSummary:source];
        if (!shelves.count)
            p.emptyText = @"Noch keine Downloads.\nBei einem Video OK gedrückt halten und „Herunterladen“ wählen –\nbei einer Sendung „Neue Folgen automatisch laden“.";
        done(p, nil);
    };
}

// Kachelbild mit Download-Symbol in App-Farben
static NSString *SFDownloadsArt(NSString *source) { return SFIconArt(@"download", source); }

// Kachel, die die Downloads-Seite öffnet (Home: alle Quellen, in Apps: nur diese Quelle)
+ (SFItem *)downloadsTile:(NSString *)source {
    SFDownloads *dl = [SFDownloads shared];
    SFItem *i = [SFItem new];
    i.kind = SFItemFolder;
    i.identifier = source ? [@"downloads:" stringByAppendingString:source] : @"downloads:";
    i.title = @"Downloads";
    NSUInteger running = 0;
    for (SFItem *a in [dl active]) if (!source || [a.source isEqualToString:source]) running++;
    i.subtitle = running ? [NSString stringWithFormat:@"%lu %@ · %@", (unsigned long)running, running == 1 ? @"wird geladen" : @"werden geladen", [dl storageSummary:source]]
                         : [dl storageSummary:source];
    i.plot = [dl deletesWatched]
        ? @"Heruntergeladene Videos – auch ohne Internet. Automatisch geladene Folgen verschwinden einen Tag nach dem Ansehen von selbst."
        : @"Heruntergeladene Videos – auch ohne Internet. Hier siehst du, was gerade geladen wird, und verwaltest deine Sendungen.";
    i.themeName = source ?: @"home";
    i.source = source;
    if (!source) { i.style = SFTileStyleApp; i.tint = SFHex(0x2c3e50); }
    else { i.style = SFTileStyleWide; i.image = SFDownloadsArt(source); }
    i.pageLoader = [self downloadsLoader:source];
    return i;
}

@end
