#import "SFBrowseScreen+Private.h"

@implementation SFBrowseScreen (Context)

#pragma mark Kontextmenü

- (void)showContextMenuFor:(SFItem *)it shelfItems:(NSArray *)items index:(NSUInteger)idx {
    NSMutableArray *opts = [NSMutableArray new];
    __weak SFBrowseScreen *ws = self;
    SFNavigator *nav = self.navigator;
    if (it.kind == SFItemVideo || it.kind == SFItemLive) {
        double p = [[SFStore shared] progressFor:it.identifier];
        // Kopiergeschützt: kein irreführendes „Abspielen“/Merken/Laden, nur die ehrliche Erklärung (Auswahl schließt)
        if (it.drm) {
            SFMenuOption *o = [SFMenuOption option:@"Kopiergeschützt (DRM)" action:nil];
            o.detail = @"nicht abspielbar";
            [opts addObject:o];
        } else [opts addObject:[SFMenuOption option:(p > 0 && p < 1) ? @"Fortsetzen" : @"Abspielen" action:^{ SFOpenItem(nav, it, items, idx); }]];
        if (p > 0 && p < 1 && !it.drm) {
            [opts addObject:[SFMenuOption option:@"Von Anfang abspielen" action:^{
                SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:it queue:items index:idx];
                ps.startFromBeginning = YES;
                [nav push:ps];
            }]];
        }
        if (it.kind == SFItemVideo && !it.drm && it.identifier && p < 1) {   // eigene Merkliste, für alle Apps
            SFWatchLater *wl = [SFWatchLater shared];
            BOOL in = [wl contains:it.identifier];
            [opts addObject:[SFMenuOption option:in ? @"Aus „Später ansehen“ entfernen" : @"Später ansehen" action:^{
                if (in) { [wl remove:it.identifier]; [nav toast:@"Aus „Später ansehen“ entfernt"]; }
                else { [wl add:it]; [nav toast:@"Gemerkt – steht unter „Später ansehen“"]; }
            }]];
        }
        if (it.kind == SFItemVideo && !it.drm) {   // Offline-Schicht: Download ist eine Option des Inhalts
            SFDownloads *dl = [SFDownloads shared];
            double dp = 0;
            SFDLState ds = [dl stateFor:it.identifier progress:&dp];
            NSString *ident = it.identifier;
            if (ds == SFDLQueued || ds == SFDLRunning) {
                SFMenuOption *o = [SFMenuOption option:@"Download abbrechen" action:^{ [dl remove:ident]; [nav toast:@"Download abgebrochen"]; }];
                o.detail = ds == SFDLRunning ? [NSString stringWithFormat:@"%d %%", (int)round(dp * 100)] : @"wartet";
                [opts addObject:o];
            } else if (ds == SFDLDone || it.localPath) {
                if (ds == SFDLDone) [opts addObject:[SFMenuOption option:@"Download löschen" action:^{ [dl remove:ident]; [nav toast:@"Download gelöscht"]; [ws reload]; }]];
            } else if (it.resolverRef || it.resolver) {
                [opts addObject:[SFMenuOption option:@"Herunterladen" action:^{ [dl download:it]; [nav toast:@"Wird heruntergeladen – auch offline verfügbar"]; }]];
            }
        }
        if (it.kind == SFItemVideo && !it.drm) {
            BOOL w = p >= 1;
            [opts addObject:[SFMenuOption option:w ? @"Als ungesehen markieren" : @"Als gesehen markieren" action:^{
                [[SFStore shared] setWatched:!w forItem:it];
                [ws refreshTiles];
                if (!w) [ws reload];
            }]];
            if (p > 0 && p < 1) {
                [opts addObject:[SFMenuOption option:@"Aus „Weiterschauen“ entfernen" action:^{
                    [[SFStore shared] removeFromContinue:it.identifier];
                    [ws reload];
                }]];
            }
        }
        // Zur Sendung / zum Kanal der Folge (online, wie bei der Quelle) – nicht, wenn man schon dort ist
        SFPageLoader showPage = it.showRef && ![it.showRef isEqualToString:self.folderIdentifier] ? SFShowPageLoader(it.showRef, it.channel) : nil;
        if (showPage) {
            BOOL yt = [it.showRef hasPrefix:@"ytchannel:"];
            NSString *name = it.channel.length ? it.channel : nil;
            [opts addObject:[SFMenuOption option:name ? [NSString stringWithFormat:@"%@ „%@“", yt ? @"Zum Kanal" : @"Zur Sendung", name] : (yt ? @"Zum Kanal" : @"Zur Sendung") action:^{
                SFItem *f = [SFItem new];
                f.kind = SFItemFolder; f.identifier = it.showRef; f.title = it.channel; f.themeName = it.themeName ?: it.source;
                f.pageLoader = showPage;
                SFOpenItem(nav, f, nil, 0);
            }]];
        }
        // ohne gespeicherte Kennung: beim Auswählen bei der Quelle nachschlagen (nicht auf der Kanalseite selbst)
        SFShowRefLookup lookup = !showPage && !it.showRef && ![self.folderIdentifier hasPrefix:@"ytchannel:"] ? SFShowRefLookupFor(it.source) : nil;
        if (lookup && it.kind == SFItemVideo) {
            NSString *name = it.channel.length ? it.channel : nil;
            [opts addObject:[SFMenuOption option:name ? [NSString stringWithFormat:@"Zum Kanal „%@“", name] : @"Zum Kanal" action:^{
                lookup(it, ^(NSString *ref) {
                    if (nav.top != ws) return;   // inzwischen woanders (z. B. Wiedergabe gestartet)
                    SFPageLoader pl = ref ? SFShowPageLoader(ref, it.channel) : nil;
                    if (!pl) { [nav toast:@"Kanal nicht gefunden"]; return; }
                    SFItem *f = [SFItem new];
                    f.kind = SFItemFolder; f.identifier = ref; f.title = it.channel; f.themeName = it.themeName ?: it.source;
                    f.pageLoader = pl;
                    SFOpenItem(nav, f, nil, 0);
                });
            }]];
        }
        SFShow *show = !showPage && !lookup && it.channel ? [[SFLibrary shared] showNamed:it.channel source:it.source] : nil;
        if (show && ![_page.title isEqualToString:show.name]) {
            [opts addObject:[SFMenuOption option:[NSString stringWithFormat:@"Zu „%@“", show.name] action:^{
                SFItem *f = [SFItem new];
                f.kind = SFItemFolder; f.themeName = show.source;
                f.pageLoader = [SFHome showLoader:show.name source:show.source];
                SFOpenItem(nav, f, nil, 0);
            }]];
        }
    } else if (it.kind == SFItemFolder) {
        [opts addObject:[SFMenuOption option:@"Öffnen" action:^{ SFOpenItem(nav, it, items, idx); }]];
        SFDownloads *dl = [SFDownloads shared];
        if ([it.identifier hasPrefix:@"downloads:"]) {   // Einstellungen der Offline-Schicht
            BOOL on = [dl deletesWatched];
            SFMenuOption *o = [SFMenuOption option:@"Gesehenes löschen" action:^{
                [dl setDeletesWatched:!on];
                [nav toast:!on ? @"Abo-Folgen werden 1 Tag nach dem Ansehen gelöscht – spart Platz"
                               : @"Gesehene Abo-Folgen bleiben erhalten"];
            }];
            o.detail = on ? @"An" : @"Aus";
            [opts addObject:o];
        }
        if ([it.identifier hasPrefix:@"show:"]) {   // Sendung im Offline-Bestand
            NSString *ch = it.channel ?: it.title, *src = it.source;
            NSString *sid = [dl subscriptionIDForChannel:ch source:src];
            if (sid) {
                SFMenuOption *o = [SFMenuOption option:@"Automatisch laden" action:^{
                    [dl unsubscribe:sid]; [nav toast:@"Automatisch laden aus – vorhandene Folgen bleiben"];
                }];
                o.detail = @"An";
                [opts addObject:o];
            }
            SFShow *sh = [[SFLibrary shared] showNamed:ch source:src];
            NSUInteger n = sh.episodes.count;
            SFMenuOption *del = [SFMenuOption option:@"Alle Downloads löschen" action:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    SFMenuOption *yes = [SFMenuOption option:[NSString stringWithFormat:@"Ja, %lu %@ löschen", (unsigned long)n, n == 1 ? @"Folge" : @"Folgen"] action:^{
                        if (sid) [dl unsubscribe:sid];
                        [dl removeAllOfChannel:ch source:src];
                        [nav toast:[NSString stringWithFormat:@"„%@“ gelöscht", ch]];
                    }];
                    SFMenuOption *no = [SFMenuOption option:@"Abbrechen" action:^{}];
                    [nav push:[[SFMenuScreen alloc] initWithTitle:[NSString stringWithFormat:@"„%@“ löschen?", ch]
                                                         subtitle:sid ? @"Die Folgen werden gelöscht und nicht mehr automatisch geladen." : @"Die Folgen werden vom Mac gelöscht."
                                                          options:@[no, yes] theme:ws.theme]];
                });
            }];
            del.detail = [NSString stringWithFormat:@"%lu %@", (unsigned long)n, n == 1 ? @"Folge" : @"Folgen"];
            [opts addObject:del];
        }
        // Folgen = Kern (Neue Folgen, Meine Sendungen); Automatisch herunterladen = optionaler Zusatz
        SFFollows *fo = [SFFollows shared];
        if ([fo canFollow:it]) {
            BOOL following = [fo isFollowing:it.identifier];
            [opts addObject:[SFMenuOption option:following ? @"Nicht mehr folgen" : @"Folgen" action:^{
                if (following) { [fo unfollow:it.identifier]; [nav toast:[NSString stringWithFormat:@"„%@“ entfernt", it.title]]; }
                else { [fo follow:it]; [nav toast:[NSString stringWithFormat:@"Du folgst „%@“ – neue Folgen erscheinen unter „Neue Folgen“", it.title]]; }
            }]];
        }
        if ([dl canSubscribe:it]) {
            BOOL on = [dl isSubscribed:it.identifier];
            SFMenuOption *o = [SFMenuOption option:@"Automatisch herunterladen" action:^{
                if (on) { [dl unsubscribe:it.identifier]; [nav toast:@"Automatisch herunterladen aus – vorhandene Folgen bleiben"]; }
                else { [dl subscribe:it]; [nav toast:[NSString stringWithFormat:@"Neue Folgen von „%@“ werden heruntergeladen – auch offline verfügbar", it.title]]; }
            }];
            o.detail = on ? @"An" : @"Aus";
            [opts addObject:o];
        }
    }
    if (!opts.count) return;
    NSString *sub = it.channel && ![it.channel isEqualToString:it.title] ? it.channel : it.subtitle;
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:it.title subtitle:sub options:opts theme:self.theme];
    [nav push:m];
}

- (void)refreshTiles {
    for (SFRow *r in _rows) for (SFTileLayer *tl in r.tiles.allValues) [tl refreshProgress];
}

@end
