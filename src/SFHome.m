#import "SFHome.h"
#import "SFLibrary.h"
#import "SFStore.h"
#import "SFProviderCCC.h"
#import "SFProviderARD.h"
#import "SFProviderZDF.h"
#import "SFProviderORF.h"
#import "SFYouTube.h"
#import "SFSearch.h"
#import "SFDownloads.h"

@implementation SFHome

// Titel, Beschreibung, Kachelfarbe, Logo-Variante (0 original, 1 helle Schrift, 2 weiß)
static NSDictionary *appInfo(void) {
    return @{
        @"youtube": @[@"YouTube", @"Deine Kanäle, neue Videos, Suche", @0xffffff, @0],
        @"zdf":     @[@"ZDF", @"Mediathek, Sendungen und Live-TV", @0x24272d, @0],
        @"ard":     @[@"ARD", @"Das Erste, Dritte, Mediathek", @0x003480, @2],
        @"orf":     @[@"ORF", @"ORF ON, Sendungen und Live", @0xffffff, @0],
        @"ccc":     @[@"media.ccc.de", @"Vorträge vom Chaos Computer Club", @0x0b0d0b, @1],
    };
}

+ (SFItem *)appTile:(NSString *)src {
    NSArray *a = appInfo()[src];
    SFItem *i = [SFItem new];
    i.kind = SFItemAction;
    i.identifier = [@"app:" stringByAppendingString:src];
    i.title = a[0];
    i.plot = a[1];
    i.themeName = src;
    i.tint = SFHex([a[2] unsignedIntValue]);
    i.logo = src;
    i.logoVariant = [a[3] integerValue];
    i.style = SFTileStyleApp;
    return i;
}

+ (SFScreen *)homeScreen {
    SFBrowseScreen *s = [[SFBrowseScreen alloc] initWithLoader:^(SFPageDone done) {
        [[SFLibrary shared] whenReady:^{
            NSMutableArray *apps = [NSMutableArray new];
            for (NSString *src in @[@"youtube", @"zdf", @"ard", @"orf", @"ccc"]) [apps addObject:[self appTile:src]];
            SFItem *kodi = [SFItem new];
            kodi.kind = SFItemAction; kodi.identifier = @"app:kodi"; kodi.title = @"Kodi";
            kodi.plot = @"Das bisherige Media-Center starten";
            kodi.tint = SFHex(0x2a3442); kodi.style = SFTileStyleApp; kodi.themeName = @"home";
            kodi.action = ^{
                [[NSWorkspace sharedWorkspace] launchApplication:@"Kodi"];
            };
            [apps addObject:[self downloadsTile:nil]];
            [apps addObject:kodi];

            NSMutableArray *shelves = [NSMutableArray new];
            [shelves addObject:[SFShelf shelf:nil style:SFTileStyleApp items:apps]];
            NSArray *cont = [[SFStore shared] continueWatching:20 source:nil];
            for (SFItem *e in cont) e.subtitle = [NSString stringWithFormat:@"%@ · noch %@", e.channel ?: @"", SFFormatDuration(MAX(0, e.duration - [[SFStore shared] positionFor:e.identifier]))];
            if (cont.count) [shelves addObject:[SFShelf shelf:@"Weiterschauen" style:SFTileStyleLandscape items:cont]];
            NSArray *latest = [[SFLibrary shared] latestEpisodes:40 source:nil];
            latest = [[NSArray alloc] initWithArray:latest copyItems:YES];
            for (SFItem *e in latest) e.subtitle = [NSString stringWithFormat:@"%@ · %@", e.channel, SFFormatDateShort(e.date)];
            [shelves addObject:[SFShelf shelf:@"Neue Folgen" style:SFTileStyleLandscape items:latest]];
            NSMutableArray *shows = [NSMutableArray new];
            for (SFShow *sh in [[SFLibrary shared] showsForSource:nil]) {
                if (shows.count >= 30) break;
                [shows addObject:[self showTile:sh]];
            }
            [shelves addObject:[SFShelf shelf:@"Sendungen" style:SFTileStyleLandscape items:shows]];
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
    s.reloadNotification = SFLibraryDidChangeNotification;   // Screen verwaltet den Observer selbst
}

+ (SFItem *)showTile:(SFShow *)sh {
    SFItem *i = [SFItem new];
    i.kind = SFItemFolder;
    i.identifier = [@"show:" stringByAppendingString:sh.name];
    i.title = sh.name;
    i.channel = sh.name;
    i.subtitle = [NSString stringWithFormat:@"%lu %@ · %@", (unsigned long)sh.episodes.count, sh.episodes.count == 1 ? @"Folge" : @"Folgen", SFFormatDateShort(sh.latest)];
    i.image = [sh.source isEqualToString:@"youtube"] ? (sh.poster ?: ((SFItem *)sh.episodes.firstObject).image) : ((SFItem *)sh.episodes.firstObject).image;
    i.backdrop = ((SFItem *)sh.episodes.firstObject).image;
    i.plot = ((SFItem *)sh.episodes.firstObject).title ? [NSString stringWithFormat:@"Neueste Folge: %@", ((SFItem *)sh.episodes.firstObject).title] : nil;
    i.date = sh.latest;
    i.source = sh.source;
    i.themeName = sh.source;
    i.pageLoader = [self showLoader:sh.name];
    return i;
}

+ (SFPageLoader)showLoader:(NSString *)showName {
    return ^(SFPageDone done) {
        [[SFLibrary shared] whenReady:^{
            SFShow *sh = [[SFLibrary shared] showNamed:showName];
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

// Kachelbild: Download-Symbol (Kreis + Pfeil + Ablage) in den Farben der App, einmal erzeugt
static NSString *downloadsArt(NSString *source) {
    SFTheme *t = [SFTheme themeNamed:source ?: @"home"];
    NSString *path = [SFCacheDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"downloads-art-v1-%@.png", source ?: @"home"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    const NSInteger W = 1280, H = 720;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H bitsPerSample:8 samplesPerPixel:4
                                                                      hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    NSColor *bg = t.surface ?: t.background, *acc = t.accent ?: [NSColor whiteColor];
    [[[NSGradient alloc] initWithStartingColor:[bg blendedColorWithFraction:0.25 ofColor:acc] endingColor:bg] drawInRect:NSMakeRect(0, 0, W, H) angle:-60];
    CGFloat cx = W / 2.0, cy = H / 2.0 + 40, r = 170;
    [acc setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - r, cy - r, 2 * r, 2 * r)] fill];
    NSColor *fg = t.accentText ?: [NSColor whiteColor];
    [fg setStroke];
    NSBezierPath *p = [NSBezierPath bezierPath];
    p.lineWidth = 26; p.lineCapStyle = NSRoundLineCapStyle; p.lineJoinStyle = NSRoundLineJoinStyle;
    [p moveToPoint:NSMakePoint(cx, cy + 95)]; [p lineToPoint:NSMakePoint(cx, cy - 55)];               // Schaft
    [p moveToPoint:NSMakePoint(cx - 70, cy + 15)]; [p lineToPoint:NSMakePoint(cx, cy - 55)];
    [p lineToPoint:NSMakePoint(cx + 70, cy + 15)];                                                       // Spitze
    [p moveToPoint:NSMakePoint(cx - 85, cy - 105)]; [p lineToPoint:NSMakePoint(cx + 85, cy - 105)];     // Ablage
    [p stroke];
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSPNGFileType properties:@{}] writeToFile:path atomically:YES];
    return path;
}

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
    i.plot = @"Heruntergeladene Videos – auch ohne Internet. Hier siehst du, was gerade geladen wird, und verwaltest Sendungen, die automatisch geladen werden.";
    i.themeName = source ?: @"home";
    i.source = source;
    if (!source) { i.style = SFTileStyleApp; i.tint = SFHex(0x2c3e50); }
    else { i.style = SFTileStyleWide; i.image = downloadsArt(source); }
    i.pageLoader = [self downloadsLoader:source];
    return i;
}

// Online-Startseite um "Meine Sendungen" (lokale Downloads dieser Quelle) ergänzen.
+ (SFPageLoader)withLocalShows:(SFPageLoader)online source:(NSString *)source {
    return ^(SFPageDone done) {
        online(^(SFPage *page, NSError *err) {
            [[SFLibrary shared] whenReady:^{
                NSMutableArray *mine = [NSMutableArray new];
                for (SFShow *sh in [[SFLibrary shared] showsForSource:source]) {
                    SFItem *i = [self showTile:sh]; i.style = SFTileStyleWide; [mine addObject:i];
                }
                if (!page && !mine.count) { done(nil, err); return; }
                SFPage *p = page ?: [SFPage page:nil theme:source shelves:@[]];
                NSMutableArray *sh = [p.shelves mutableCopy] ?: [NSMutableArray new];
                BOOL any = mine.count || [[SFDownloads shared] bytesUsedFor:source] > 0;
                for (SFItem *a in [[SFDownloads shared] active]) if ([a.source isEqualToString:source]) any = YES;
                if (any) {
                    [mine insertObject:[self downloadsTile:source] atIndex:0];
                    // Die App öffnet auf ihren Inhalten: Downloads nach „Weiterschauen“, sonst nach dem ersten Regal
                    NSUInteger at = sh.count ? 1 : 0;
                    for (NSUInteger k = 0; k < sh.count; k++) if ([[sh[k] title] isEqualToString:@"Weiterschauen"]) at = k + 1;
                    [sh insertObject:[SFShelf shelf:@"Downloads" style:SFTileStyleWide items:mine] atIndex:MIN(at, sh.count)];
                }
                if (!page && err) p.emptyText = @"Die Mediathek ist gerade nicht erreichbar.";
                p.shelves = sh;
                done(p, nil);
            }];
        });
    };
}

+ (SFScreen *)appScreen:(NSString *)source {
    SFTheme *t = [SFTheme themeNamed:source];
    SFPageLoader online = nil;
    if ([source isEqualToString:@"ccc"]) online = [SFProviderCCC homeLoader];
    else if ([source isEqualToString:@"youtube"]) online = [SFYouTube homeLoader];   // integriert Downloads selbst
    else if ([source isEqualToString:@"ard"]) online = [self withLocalShows:[SFProviderARD homeLoader] source:source];
    else if ([source isEqualToString:@"zdf"]) online = [self withLocalShows:[SFProviderZDF homeLoader] source:source];
    else if ([source isEqualToString:@"orf"]) online = [self withLocalShows:[SFProviderORF homeLoader] source:source];
    if (online) {
        online = SFWithSearchTile(online, source);   // Kachel „Suche“
        SFBrowseScreen *c = [[SFBrowseScreen alloc] initWithLoader:online theme:t];
        c.showsHero = YES;
        c.restoreKey = [@"app:" stringByAppendingString:source];
        [self reloadOnLibraryChange:c];   // Downloads-Regal aktuell halten
        return c;
    }
    SFBrowseScreen *s = [[SFBrowseScreen alloc] initWithLoader:^(SFPageDone done) {
        [[SFLibrary shared] whenReady:^{
            NSMutableArray *shelves = [NSMutableArray new];
            NSArray *cont = [[SFStore shared] continueWatching:20 source:source];
            for (SFItem *e in cont) e.subtitle = [NSString stringWithFormat:@"%@ · noch %@", e.channel ?: @"", SFFormatDuration(MAX(0, e.duration - [[SFStore shared] positionFor:e.identifier]))];
            if (cont.count) [shelves addObject:[SFShelf shelf:@"Weiterschauen" style:SFTileStyleLandscape items:cont]];
            NSArray *latest = [[SFLibrary shared] latestEpisodes:40 source:source];
            latest = [[NSArray alloc] initWithArray:latest copyItems:YES];
            for (SFItem *e in latest) e.subtitle = [NSString stringWithFormat:@"%@ · %@", e.channel, SFFormatDateShort(e.date)];
            BOOL yt = [source isEqualToString:@"youtube"];
            if (latest.count) [shelves addObject:[SFShelf shelf:yt ? @"Neu in deinen Abos" : @"Neue Folgen" style:SFTileStyleLandscape items:latest]];
            NSMutableArray *shows = [NSMutableArray new];
            for (SFShow *sh in [[SFLibrary shared] showsForSource:source]) {
                SFItem *i = [self showTile:sh];
                if (!yt) { i.style = SFTileStyleWide; }
                [shows addObject:i];
            }
            if (shows.count)
                [shelves addObject:[SFShelf grid:yt ? @"Kanäle" : @"Meine Sendungen" style:yt ? SFTileStyleCircle : SFTileStyleWide items:shows]];
            SFPage *p = [SFPage page:nil theme:source shelves:shelves];
            if (!shelves.count) p.emptyText = @"Noch keine Inhalte. Die Mediathek-Anbindung folgt.";
            done(p, nil);
        }];
    } theme:t];
    s.showsHero = YES;
    s.restoreKey = [@"app:" stringByAppendingString:source];
    [self reloadOnLibraryChange:s];
    return s;
}
@end
