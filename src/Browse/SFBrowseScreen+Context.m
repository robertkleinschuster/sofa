#import "SFBrowseScreen+Private.h"
#import "SFLibraryPages.h"

// the page of a channel (show ref of a channel app): its videos need no "Zum Kanal"
static BOOL SFIsChannelPage(NSString *here) { return here && [SFAppRegistry isShowRef:here] && SFShowRefIsChannel(here); }

@implementation SFBrowseScreen (Context)

#pragma mark Context menu

- (void)showContextMenuFor:(SFItem *)it shelfItems:(NSArray *)items index:(NSUInteger)idx {
    NSMutableArray *opts = [NSMutableArray new];
    __weak SFBrowseScreen *ws = self;
    SFNavigator *nav = self.navigator;
    if (it.kind == SFItemVideo || it.kind == SFItemLive) {
        double p = [[SFStore shared] progressFor:it.identifier];
        // copy-protected: no misleading "Abspielen"/save/download, only the honest explanation (choosing closes)
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
        if (it.kind == SFItemVideo && !it.drm && it.identifier && p < 1) {   // own watch list, for all apps
            SFWatchLater *wl = [SFWatchLater shared];
            BOOL in = [wl contains:it.identifier];
            [opts addObject:[SFMenuOption option:in ? @"Aus „Später ansehen“ entfernen" : @"Später ansehen" action:^{
                if (in) { [wl remove:it.identifier]; [nav toast:@"Aus „Später ansehen“ entfernt"]; }
                else { [wl add:it]; [nav toast:@"Gemerkt – steht unter „Später ansehen“"]; }
            }]];
        }
        if (it.kind == SFItemVideo && !it.drm) {   // offline layer: download is an option of the item
            SFDownloads *dl = [SFDownloads shared];
            double dp = 0;
            SFDLState ds = [dl stateFor:it.identifier progress:&dp];
            NSString *ident = it.identifier;
            if (ds == SFDLQueued || ds == SFDLRunning) {
                SFMenuOption *o = [SFMenuOption option:@"Download abbrechen" action:^{ [dl remove:ident]; [nav toast:@"Download abgebrochen"]; }];
                o.detail = ds == SFDLRunning ? [NSString stringWithFormat:@"%d %%", (int)round(dp * 100)] : @"wartet";
                [opts addObject:o];
            } else if (ds == SFDLDone || it.localPath) {
                if (ds == SFDLDone) {
                    BOOL kept = [dl isKept:ident];
                    SFMenuOption *keep = [SFMenuOption option:@"Behalten" action:^{
                        [dl setKept:!kept forIdentifier:ident];
                        [nav toast:!kept ? @"Wird behalten – nie zum Löschen vorgeschlagen" : @"Nicht mehr behalten"];
                    }];
                    keep.detail = kept ? @"An" : @"Aus";
                    [opts addObject:keep];
                    // deleting an irreplaceable copy (kept, or no longer online) asks first
                    BOOL gone = [dl onlineStateFor:ident] == 0;
                    [opts addObject:[SFMenuOption option:@"Download löschen" action:^{
                        if (!kept && !gone) { [dl remove:ident]; [nav toast:@"Download gelöscht"]; [ws reload]; return; }
                        dispatch_async(dispatch_get_main_queue(), ^{
                            SFMenuOption *no = [SFMenuOption option:@"Abbrechen" action:^{}];
                            SFMenuOption *yes = [SFMenuOption option:@"Ja, endgültig löschen" action:^{ [dl remove:ident]; [nav toast:@"Download gelöscht"]; [ws reload]; }];
                            [nav push:[[SFMenuScreen alloc] initWithTitle:@"Download löschen?"
                                                                 subtitle:gone ? @"Dieses Video ist nicht mehr online – die Kopie hier ist die einzige." : @"Dieses Video ist als „Behalten“ markiert."
                                                                  options:@[no, yes] theme:ws.theme]];
                        });
                    }]];
                }
            } else if (it.resolverRef || it.resolver) {
                [opts addObject:[SFMenuOption option:@"Herunterladen" action:^{ [dl download:it told:^(NSString *m) { [nav toast:m]; }]; }]];
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
        // to the episode's show / channel (SFShowLink: online page, looked up channel, or downloaded show)
        SFShowLink *link = [SFShowLink linkFor:it here:self.folderIdentifier pageTitle:_page.title];
        if (link) {
            [opts addObject:[SFMenuOption option:link.title action:^{
                [link openOn:nav stillValid:^BOOL { return nav.top == ws; } present:nil];   // lookup is async: only if still here
            }]];
        }
    } else if (it.kind == SFItemFolder) {
        [opts addObject:[SFMenuOption option:@"Öffnen" action:^{ SFOpenItem(nav, it, items, idx); }]];
        SFDownloads *dl = [SFDownloads shared];
        if ([it.identifier hasPrefix:@"downloads:"]) {   // the offline layer: making room by hand
            SFMenuOption *o = [SFMenuOption option:@"Platz schaffen" action:^{
                dispatch_async(dispatch_get_main_queue(), ^{ SFOpenItem(nav, [SFLibraryPages roomTile], nil, 0); });
            }];
            o.detail = [dl storageSummary:nil];
            [opts addObject:o];
        }
        if ([it.identifier hasPrefix:@"show:"]) {   // show in the offline inventory
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
        // Folgen = core (Neue Folgen, Meine Sendungen); Automatisch herunterladen = optional add-on
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

// A download changed (object = its item id; nil = any): only its tiles - a running download posts
// every few percent, and refreshing every tile of the page each time cost ~50 ms of main thread
// (sample 2026-11-07, home-screen micro-stutter)
- (void)downloadChanged:(NSNotification *)n {
    NSString *changed = [n.object isKindOfClass:[NSString class]] ? n.object : nil;
    if (!changed) { [self refreshTiles]; return; }
    for (SFRow *r in _rows) for (SFTileLayer *tl in r.tiles.allValues)
        if ([tl.item.identifier isEqualToString:changed]) [tl refreshDownload];
}

@end


#pragma mark - Show / channel link

@implementation SFShowLink {
    SFItem *_episode;
    SFShowRefLookup _lookup;     // channel has to be looked up first
    SFShow *_local;              // downloaded show
}

static SFItem *SFShowFolder(SFItem *it, NSString *ref, SFPageLoader page) {
    SFItem *f = [SFItem new];
    f.kind = SFItemFolder; f.identifier = ref; f.title = it.channel;
    f.source = it.source; f.themeName = it.themeName ?: it.source;
    f.pageLoader = page;
    return f;
}

+ (instancetype)linkFor:(SFItem *)it here:(NSString *)here pageTitle:(NSString *)pageTitle {
    if (it.kind != SFItemVideo && it.kind != SFItemLive) return nil;
    SFShowLink *l = [SFShowLink new];
    l->_episode = it;
    NSString *name = it.channel.length ? it.channel : nil;
    // Online page of the show/channel (as at the source) - not when one is already there
    SFPageLoader page = it.showRef && ![it.showRef isEqualToString:here] ? SFShowPageLoader(it.showRef, it.channel) : nil;
    if (page) {
        BOOL yt = SFShowRefIsChannel(it.showRef);
        l->_folder = SFShowFolder(it, it.showRef, page);
        l->_title = name ? [NSString stringWithFormat:@"%@ „%@“", yt ? @"Zum Kanal" : @"Zur Sendung", name] : (yt ? @"Zum Kanal" : @"Zur Sendung");
        return l;
    }
    // No stored reference: look it up at the source when chosen (not on the channel page itself)
    SFShowRefLookup lookup = !it.showRef && !SFIsChannelPage(here) && it.kind == SFItemVideo ? SFShowRefLookupFor(it.source) : nil;
    if (lookup) {
        l->_lookup = lookup;
        // channels (YouTube): the channel name is known; elsewhere the show page names itself once found
        BOOL yt = SFItemShowsAreChannels(it);
        l->_title = yt ? (name ? [NSString stringWithFormat:@"Zum Kanal „%@“", name] : @"Zum Kanal") : @"Zur Sendung";
        return l;
    }
    SFShow *show = name ? [[SFLibrary shared] showNamed:name source:it.source] : nil;
    if (show && ![pageTitle isEqualToString:show.name]) {
        l->_local = show;
        l->_title = [NSString stringWithFormat:@"Zu „%@“", show.name];
        return l;
    }
    return nil;
}

- (void)openOn:(SFNavigator *)nav stillValid:(BOOL (^)(void))stillValid present:(void (^)(SFScreen *))present {
    void (^show)(SFScreen *) = present ?: ^(SFScreen *s) { [nav push:s]; };
    if (_folder) { show(SFBrowseScreenForFolder(_folder, nav.top.theme)); return; }
    if (_local) {
        SFItem *f = [SFItem new];
        f.kind = SFItemFolder; f.themeName = _local.source;
        f.pageLoader = [SFLibraryPages showLoader:_local.name source:_local.source];
        show(SFBrowseScreenForFolder(f, nav.top.theme));
        return;
    }
    if (!_lookup) return;
    SFItem *it = _episode;
    _lookup(it, ^(NSString *ref) {
        if (stillValid && !stillValid()) return;   // the user has moved on (e.g. started playback)
        // outside channel apps the show may be unnamed (ORF lists): the show page names itself
        BOOL ch = SFItemShowsAreChannels(it);
        SFPageLoader pl = ref ? SFShowPageLoader(ref, ch ? it.channel : nil) : nil;
        if (!pl) { [nav toast:ch ? @"Kanal nicht gefunden" : @"Keine Sendungsseite gefunden"]; return; }
        show(SFBrowseScreenForFolder(SFShowFolder(it, ref, pl), nav.top.theme));
    });
}
@end
