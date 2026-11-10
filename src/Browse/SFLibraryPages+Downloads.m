// SFLibraryPages – downloads page (offline inventory), the tile that opens it, and "Platz schaffen".
#import "SFLibraryPages.h"
#import "SFDownloads.h"
#import "SFIconArt.h"
#import "SFStore.h"
#import "SFMenuScreen.h"
#import "SFPlayerScreen.h"

static NSString *SFVideos(NSUInteger n) { return [NSString stringWithFormat:@"%lu %@", (unsigned long)n, n == 1 ? @"Video" : @"Videos"]; }

@implementation SFLibraryPages (Downloads)

#pragma mark Downloads (offline inventory, like "Downloads" in YouTube Premium)

+ (SFPageLoader)downloadsLoader:(NSString *)source {
    return ^(SFPageDone done) {
        SFDownloads *dl = [SFDownloads shared];
        NSMutableArray *shelves = [NSMutableArray new];
        BOOL mixed = !source;   // Sofa's own page: every app's downloads - each says where it comes from
        NSMutableArray *active = [NSMutableArray new];
        for (SFItem *i in [dl active]) {
            if (source && ![i.source isEqualToString:source]) continue;
            SFItem *c = [i copy];
            c.showsSourceMark = mixed;
            double p = 0;
            SFDLState st = [dl stateFor:c.identifier progress:&p];
            c.subtitle = SFDotJoin(c.channel, st == SFDLRunning ? @"wird geladen" : dl.storageFull ? @"wartet auf Platz" : @"wartet");
            [active addObject:c];
        }
        // storage first when it is full (the queue waits for room), otherwise after the content
        SFShelf *storage = [SFShelf shelf:@"Speicher" style:SFTileStyleLandscape items:@[[self roomTile]]];
        if (dl.storageFull) [shelves addObject:storage];
        if (active.count) [shelves addObject:[SFShelf shelf:dl.storageFull ? @"Wartet auf Platz" : @"Wird geladen" style:SFTileStyleLandscape items:active]];
        // given up: the user decides (OK held: "Erneut herunterladen" or "Entfernen") - never retried by itself
        NSMutableArray *failed = [NSMutableArray new];
        for (SFItem *i in [dl failed:source]) {
            SFItem *c = [i copy];
            c.showsSourceMark = mixed;
            c.subtitle = SFDotJoin(c.channel, [dl failureOf:c.identifier]);
            c.plot = [NSString stringWithFormat:@"Download fehlgeschlagen: %@\nOK gedrückt halten: erneut herunterladen oder entfernen.", [dl failureOf:c.identifier]];
            [failed addObject:c];
        }
        if (failed.count) [shelves addObject:[SFShelf shelf:@"Fehlgeschlagen" style:SFTileStyleLandscape items:failed]];
        NSArray *latest = [[NSArray alloc] initWithArray:[[SFLibrary shared] recentDownloads:40 source:source] copyItems:YES];
        for (SFItem *e in latest) { e.subtitle = SFDotJoin(e.channel, SFFormatDateShort(e.date)); e.showsSourceMark = mixed; }
        if (latest.count) [shelves addObject:[SFShelf shelf:@"Zuletzt geladen" style:SFTileStyleLandscape items:latest]];
        NSMutableArray *shows = [NSMutableArray new];
        for (SFShow *sh in [[SFLibrary shared] showsForSource:source]) [shows addObject:[self showTile:sh]];
        if (shows.count) [shelves addObject:[SFShelf grid:@"Sendungen und Kanäle" style:SFTileStyleLandscape items:shows]];
        if (!dl.storageFull && (latest.count || shows.count)) [shelves addObject:storage];
        SFPage *p = [SFPage page:@"Downloads" theme:source ?: @"home" shelves:shelves];
        p.subtitle = [dl storageSummary:source];
        if (!shelves.count)
            p.emptyText = @"Noch keine Downloads.\nBei einem Video OK gedrückt halten und „Herunterladen“ wählen.";
        done(p, nil);
    };
}

// tile image with a download symbol in app colours
static NSString *SFDownloadsArt(NSString *source) { return SFIconArt(@"download", source); }

// tile that opens the downloads page (Home: all sources, in apps: only this source)
+ (SFItem *)downloadsTile:(NSString *)source {
    SFDownloads *dl = [SFDownloads shared];
    SFItem *i = [SFItem new];
    i.kind = SFItemFolder;
    i.identifier = source ? [@"downloads:" stringByAppendingString:source] : @"downloads:";
    i.title = @"Downloads";
    NSUInteger running = 0;
    for (SFItem *a in [dl active]) if (!source || [a.source isEqualToString:source]) running++;
    i.subtitle = dl.storageFull ? @"Speicher voll – Downloads pausiert"
               : running ? [NSString stringWithFormat:@"%lu %@ · %@", (unsigned long)running, running == 1 ? @"wird geladen" : @"werden geladen", [dl storageSummary:source]]
                         : [dl storageSummary:source];
    i.plot = dl.storageFull
        ? @"Der Speicher ist fast voll – neue Downloads warten. Unter „Platz schaffen“ alte oder gesehene Videos löschen; Sofa löscht nie selbst etwas."
        : @"Heruntergeladene Videos – auch ohne Internet. Sofa löscht nie selbst etwas: Videos können von YouTube und aus den Mediatheken verschwinden.";
    i.themeName = source ?: @"home";
    i.source = source;
    if (!source) { i.style = SFTileStyleApp; i.tint = SFHex(0x2c3e50); }
    else { i.style = SFTileStyleWide; i.image = SFDownloadsArt(source); }
    i.pageLoader = [self downloadsLoader:source];
    return i;
}


#pragma mark Platz schaffen (make room; nothing is ever deleted automatically)

// Videos of a group that bulk deletion may remove: not "Behalten", verified still online (the copy
// of a vanished video is irreplaceable - deleted only one by one, by hand). maxAge: how old the
// online check may be (deleting re-verifies anything older than a day).
static const NSTimeInterval kVerifyBeforeDelete = 86400;
+ (NSDictionary *)roomSplit:(NSArray *)ids { return [self roomSplit:ids maxAge:30 * 86400]; }
+ (NSDictionary *)roomSplit:(NSArray *)ids maxAge:(NSTimeInterval)maxAge {
    SFDownloads *dl = [SFDownloads shared];
    NSMutableArray *ok = [NSMutableArray new];
    NSUInteger gone = 0, unchecked = 0;
    unsigned long long bytes = 0;
    for (NSString *i in ids) {
        if ([dl isKept:i]) continue;
        NSInteger o = [dl onlineStateFor:i maxAge:maxAge];
        if (o == 0) { gone++; continue; }
        if (o < 0) { unchecked++; continue; }
        [ok addObject:i];
        bytes += [dl bytesOf:i];
    }
    return @{@"ids": ok, @"bytes": @(bytes), @"gone": @(gone), @"unchecked": @(unchecked)};
}

+ (unsigned long long)bytesOf:(NSArray *)ids {
    unsigned long long n = 0;
    for (NSString *i in ids) n += [[SFDownloads shared] bytesOf:i];
    return n;
}

// Confirm and delete the deletable part of a group (online check first for what is unchecked).
+ (void)offerDeleting:(NSArray *)ids what:(NSString *)what on:(SFNavigator *)nav {
    SFDownloads *dl = [SFDownloads shared];
    NSDictionary *sp = [self roomSplit:ids maxAge:kVerifyBeforeDelete];
    if ([sp[@"unchecked"] unsignedIntegerValue]) {
        NSUInteger n = [sp[@"unchecked"] unsignedIntegerValue];
        [nav toast:n > 40 ? [NSString stringWithFormat:@"Prüfe bei %@, ob sie noch online sind (ca. %.0f Min.) …", SFVideos(n), ceil(n * 1.6 / 60)]
                          : [NSString stringWithFormat:@"Prüfe bei %@, ob sie noch online sind …", SFVideos(n)]];
        __weak SFNavigator *wn = nav;
        [dl checkOnline:ids maxAge:kVerifyBeforeDelete done:^{
            SFNavigator *sn = wn;
            if (!sn) return;
            // only where the question was asked: never over a video or another page
            SFScreen *top = sn.top;
            if ([top isKindOfClass:[SFBrowseScreen class]] && [((SFBrowseScreen *)top).folderIdentifier hasPrefix:@"room:"])
                [self confirmDeleting:ids what:what on:sn];
            else [sn toast:@"Prüfung fertig – unter „Platz schaffen“ noch einmal wählen"];
        }];
        return;
    }
    [self confirmDeleting:ids what:what on:nav];
}

+ (void)confirmDeleting:(NSArray *)ids what:(NSString *)what on:(SFNavigator *)nav {
    SFDownloads *dl = [SFDownloads shared];
    NSDictionary *sp = [self roomSplit:ids maxAge:kVerifyBeforeDelete];   // only freshly verified ones
    NSArray *del = sp[@"ids"];
    NSUInteger gone = [sp[@"gone"] unsignedIntegerValue], unchecked = [sp[@"unchecked"] unsignedIntegerValue];
    NSMutableArray *notes = [NSMutableArray new];
    if (gone) [notes addObject:[NSString stringWithFormat:@"%@ nicht mehr online", SFVideos(gone)]];
    if (unchecked) [notes addObject:[NSString stringWithFormat:@"%@ nicht prüfbar", SFVideos(unchecked)]];
    if (!del.count) {
        [nav toast:notes.count ? [@"Nichts zu löschen – " stringByAppendingString:[notes componentsJoinedByString:@", "]] : @"Nichts zu löschen"];
        return;
    }
    // e.g. "12 Videos werden gelöscht – gesehen, online weiter abrufbar.\nBleiben: 3 Videos nicht mehr online"
    NSString *sub = [NSString stringWithFormat:@"%@ %@ gelöscht – %@, online weiter abrufbar.%@", SFVideos(del.count),
                     del.count == 1 ? @"wird" : @"werden", what,
                     notes.count ? [@"\nBleiben: " stringByAppendingString:[notes componentsJoinedByString:@", "]] : @""];
    SFMenuOption *no = [SFMenuOption option:@"Abbrechen" action:^{}];
    SFMenuOption *yes = [SFMenuOption option:[NSString stringWithFormat:@"Ja, %@ löschen", SFVideos(del.count)] action:^{
        unsigned long long b = [self bytesOf:del];
        for (NSString *i in del) [dl remove:i];
        SFLog(@"downloads: Platz schaffen: %lu deleted (%@, %llu MB)", (unsigned long)del.count, what, b / 1000000ULL);
        [nav toast:[NSString stringWithFormat:@"%@ frei", SFFormatBytes(b)]];
    }];
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:[NSString stringWithFormat:@"%@ freigeben?", SFFormatBytes([sp[@"bytes"] unsignedLongLongValue])]
                                                 subtitle:sub options:@[no, yes] theme:nav.top.theme];
    m.subtitleLines = 5;
    [nav push:m];
}

// an action tile of the "Platz schaffen" page: a group of downloads with count and size
+ (SFItem *)roomGroup:(NSString *)title ids:(NSArray *)ids symbol:(NSString *)symbol what:(NSString *)what plot:(NSString *)plot {
    SFItem *i = [SFItem new];
    i.kind = SFItemAction;
    i.identifier = [@"room:" stringByAppendingString:title];
    i.title = title;
    NSDictionary *sp = [self roomSplit:ids];
    NSUInteger pending = [sp[@"unchecked"] unsignedIntegerValue];
    i.subtitle = [NSString stringWithFormat:@"%@ · %@%@", SFVideos(ids.count), SFFormatBytes([self bytesOf:ids]),
                  pending ? @"" : [NSString stringWithFormat:@" · %@ löschbar", SFFormatBytes([sp[@"bytes"] unsignedLongLongValue])]];
    i.plot = plot;
    i.image = SFIconArt(symbol, nil);
    i.style = SFTileStyleLandscape;   // title with count and size below the image
    i.themeName = @"home";
    i.action = ^{ SFNavigator *nav = [SFNavigator main]; if (nav) [self offerDeleting:ids what:what on:nav]; };
    return i;
}

+ (SFPageLoader)roomLoader {
    return ^(SFPageDone done) {
        SFDownloads *dl = [SFDownloads shared];
        SFStore *st = [SFStore shared];
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        NSMutableArray *watched = [NSMutableArray new], *old = [NSMutableArray new];
        NSMutableArray *goneItems = [NSMutableArray new], *keptItems = [NSMutableArray new];
        NSMutableDictionary *byShow = [NSMutableDictionary new];   // "source|channel" -> ids
        for (SFItem *it in [dl items:nil]) {
            NSString *i = it.identifier;
            SFDownloadRecord *r = [dl recordFor:i];
            if (!r) continue;
            SFItem *c = [it copy];
            c.subtitle = SFDotJoin(c.channel, SFFormatBytes([dl bytesOf:i]));
            if ([dl isKept:i]) { [keptItems addObject:c]; continue; }
            if ([dl onlineStateFor:i] == 0) [goneItems addObject:c];
            if ([st progressFor:i] >= 1) [watched addObject:i];
            else if (now - r.added > 180 * 86400) [old addObject:i];
            NSString *k = [NSString stringWithFormat:@"%@|%@", r.source ?: @"", it.channel ?: SFUnsortedChannel];
            if (!byShow[k]) byShow[k] = [NSMutableArray new];
            [byShow[k] addObject:i];
        }
        NSMutableArray *shelves = [NSMutableArray new];
        NSMutableArray *groups = [NSMutableArray new];
        if (watched.count) [groups addObject:[self roomGroup:@"Gesehen" ids:watched symbol:@"check" what:@"gesehen"
            plot:@"Videos, die du fertig angesehen hast. Gelöscht werden nur die, die noch online sind – du kannst sie jederzeit wieder streamen."]];
        if (old.count) [groups addObject:[self roomGroup:@"Älter als 6 Monate" ids:old symbol:@"history" what:@"seit über 6 Monaten ungesehen"
            plot:@"Seit über einem halben Jahr geladen und noch nicht angesehen. Gelöscht werden nur die, die noch online sind."]];
        if (groups.count) [shelves addObject:[SFShelf shelf:@"Aufräumen" style:SFTileStyleLandscape items:groups]];
        // shows by size, largest first: one tile per show (OK = its deletable part)
        NSMutableArray *shows = [NSMutableArray new];
        NSMutableDictionary *size = [NSMutableDictionary new];
        for (NSString *k in byShow) size[k] = @([self bytesOf:byShow[k]]);
        NSArray *keys = [byShow.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [size[b] compare:size[a]];   // largest first
        }];
        for (NSString *k in [keys subarrayWithRange:NSMakeRange(0, MIN(keys.count, 24))]) {
            NSString *name = [k substringFromIndex:[k rangeOfString:@"|"].location + 1];
            NSString *src = [k substringToIndex:[k rangeOfString:@"|"].location];
            SFShow *sh = [[SFLibrary shared] showNamed:name source:src];
            SFItem *t = [self roomGroup:name ids:byShow[k] symbol:@"storage" what:[NSString stringWithFormat:@"aus „%@“", name]
                                  plot:@"Alle Folgen dieser Sendung, die noch online sind, löschen. Behaltene und nicht mehr verfügbare bleiben."];
            if (sh.poster || sh.fanart) t.image = sh.fanart ?: sh.poster;
            t.themeName = src.length ? src : @"home";
            [shows addObject:t];
        }
        if (shows.count) [shelves addObject:[SFShelf shelf:@"Größte Sendungen und Kanäle" style:SFTileStyleLandscape items:shows]];
        if (goneItems.count) {
            for (SFItem *g in goneItems) g.badge = @"NUR HIER";
            [shelves addObject:[SFShelf shelf:@"Nicht mehr online – nur noch hier" style:SFTileStyleLandscape items:goneItems]];
        }
        if (keptItems.count) [shelves addObject:[SFShelf shelf:@"Behalten" style:SFTileStyleLandscape items:keptItems]];
        SFPage *p = [SFPage page:@"Platz schaffen" theme:@"home" shelves:shelves];
        p.subtitle = dl.storageFull ? [[dl storageSummary:nil] stringByAppendingString:@" · Downloads pausiert"] : [dl storageSummary:nil];
        if (!shelves.count) p.emptyText = @"Noch keine Downloads.";
        done(p, nil);
    };
}

+ (SFItem *)roomTile {
    SFDownloads *dl = [SFDownloads shared];
    SFItem *i = [SFItem new];
    i.kind = SFItemFolder;
    i.identifier = @"room:";
    i.title = dl.storageFull ? @"Speicher voll – Platz schaffen" : @"Platz schaffen";
    i.subtitle = [dl storageSummary:nil];
    i.plot = @"Gesehene oder alte Videos gesammelt löschen. Sofa prüft vorher, ob sie noch online sind – was nicht mehr online ist, bleibt. Mit „Behalten“ markierte Videos werden nie vorgeschlagen.";
    i.image = SFIconArt(@"storage", nil);
    i.style = SFTileStyleLandscape;
    i.themeName = @"home";
    i.pageLoader = [self roomLoader];
    return i;
}

// Asked once when the disk becomes full (not over a running video: then right after it).
static BOOL gRoomAsked;
+ (void)watchStorage {
    static id obs;
    if (obs) return;
    obs = [[NSNotificationCenter defaultCenter] addObserverForName:SFDownloadsStorageDidChangeNotification object:nil
                                                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [SFLibraryPages askForRoom]; }];
}

+ (void)askForRoom {
    SFDownloads *dl = [SFDownloads shared];
    if (!dl.storageFull) { gRoomAsked = NO; return; }   // the next time it fills up, ask again
    if (gRoomAsked) return;
    SFNavigator *nav = [SFNavigator main];
    if (!nav || [nav.top isKindOfClass:[SFPlayerScreen class]]) {   // never over a running video
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [SFLibraryPages askForRoom]; });
        return;
    }
    gRoomAsked = YES;
    static __weak SFScreen *shown;   // never a second copy on the stack
    if (shown && [nav.top isEqual:shown]) return;
    SFLog(@"downloads: asking the user to make room");
    SFMenuOption *later = [SFMenuOption option:@"Später" action:^{}];
    SFMenuOption *room = [SFMenuOption option:@"Platz schaffen" action:^{
        dispatch_async(dispatch_get_main_queue(), ^{ SFOpenItem(nav, [SFLibraryPages roomTile], nil, 0); });
    }];
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:@"Speicher fast voll"
                                                 subtitle:[NSString stringWithFormat:@"Neue Downloads warten, bis wieder mehr als %@ frei sind. Sofa löscht nie selbst etwas – du entscheidest, was weg kann.", SFFormatBytes(dl.storageReserve)]
                                                  options:@[room, later] theme:nav.top.theme];
    m.subtitleLines = 5;
    shown = m;
    [nav push:m];
}

@end
