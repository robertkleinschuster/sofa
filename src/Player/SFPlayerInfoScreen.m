#import "SFPlayerInfoScreen.h"
#import "SFPlayerScreen+Private.h"
#import "SFDownloads.h"
#import "SFFollows.h"
#import "SFWatchLater.h"
#import "SFLibrary.h"
#import "SFNet.h"

static NSString *const kRunningBadge = @"Läuft";

void SFToggleFollow(SFNavigator *n, SFItem *folder, SFTheme *theme) {
    SFFollows *fo = [SFFollows shared];
    NSString *fid = folder.identifier, *ftitle = folder.title.length ? folder.title : @"Sendung";
    if (!n || !fid) return;
    if (![fo isFollowing:fid]) {
        [fo follow:folder];
        BOOL yt = [folder.identifier hasPrefix:@"ytchannel:"];
        [n toast:[NSString stringWithFormat:@"Du folgst „%@“ – neue %@ erscheinen unter „Neue Folgen“", ftitle, yt ? @"Videos" : @"Folgen"]];
        return;
    }
    SFDownloads *dl = [SFDownloads shared];
    dispatch_block_t unfollow = ^{
        [fo unfollow:fid];
        [n toast:[NSString stringWithFormat:@"Du folgst „%@“ nicht mehr", ftitle]];
    };
    if (![dl isSubscribed:fid]) { unfollow(); return; }
    // Also ends "Automatisch herunterladen": only with confirmation (destructive)
    SFMenuOption *no = [SFMenuOption option:@"Abbrechen" action:^{}];
    SFMenuOption *yes = [SFMenuOption option:@"Nicht mehr folgen" action:unfollow];
    [n push:[[SFMenuScreen alloc] initWithTitle:[NSString stringWithFormat:@"„%@“ nicht mehr folgen?", ftitle]
                                        subtitle:@"Neue Folgen werden dann nicht mehr automatisch geladen. Vorhandene Downloads bleiben."
                                         options:@[no, yes] theme:theme]];
}

@implementation SFPlayerInfoScreen {
    __weak SFPlayerScreen *_player;
    __weak SFNavigator *_nav;      // kept: after removal self.navigator may still be needed for cleanup
    SFItem *_item;                 // the player's item this panel shows (identity: changes -> rebuild)
    NSDictionary *_details;        // YouTube watch page: description, channel, channelID, avatar, date
    NSArray *_related;             // YouTube recommendations (nil = not (yet) known)
    NSArray *_showEpisodes;        // online show (ZDF/ARD/ORF ...): episodes from its show page
    NSString *_showTitle;
    NSMapTable *_handlers;         // shown tile -> block (OK on a video tile of a shelf)
    BOOL _refreshQueued;
}

- (instancetype)initWithPlayer:(SFPlayerScreen *)player {
    // Always a dark look over the video (the light ORF theme would put dark text on the dim video)
    SFTheme *t = player.theme.light || !player.theme ? [SFTheme themeNamed:@"home"] : player.theme;
    if ((self = [super initWithLoader:nil theme:t])) {
        _player = player;
        self.overlay = YES;
        self.showsHero = YES;
        self.heroPlotLines = 6;
        _handlers = [NSMapTable strongToStrongObjectsMapTable];
        __weak SFPlayerInfoScreen *ws = self;
        self.onSelect = ^(SFItem *item, NSArray *shelfItems, NSUInteger index) { [ws choose:item]; };
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(playerChanged:) name:SFPlayerStateNotification object:player];
        [nc addObserver:self selector:@selector(scheduleRefresh) name:SFDownloadsDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(scheduleRefresh) name:SFFollowsDidChangeNotification object:nil];
        SFLog(@"info: panel for %@", player.item.identifier ?: player.item.title);
        [self loadForItem:player.item];
    }
    return self;
}

#pragma mark Data

// New item (panel opened, autoplay/queue moved on while open): reset and fetch what is missing.
- (void)loadForItem:(SFItem *)it {
    _item = it;
    _details = nil; _related = nil; _showEpisodes = nil; _showTitle = nil;
    [self setPage:[self buildPage] keepFocus:NO];
    [self loadShowEpisodesFor:it];
    // YouTube: description, channel and recommendations in ONE cached request (the same "next"
    // call autoplay uses) - only for an online-capable video, never a spinner: absent until it arrives
    if (![it.source isEqualToString:@"youtube"] || it.externalID.length != 11 || ![SFNet isOnline]) return;
    __weak SFPlayerInfoScreen *ws = self;
    [SFYouTube watchPageFor:it.externalID done:^(NSArray *related, NSDictionary *details) {
        SFPlayerInfoScreen *s = ws;
        if (!s || s->_item != it) return;   // panel closed or the player moved on
        s->_details = details;
        s->_related = related;
        SFLog(@"info: %lu recommendations, description %@", (unsigned long)related.count, details[@"description"] ? @"yes" : @"no");
        [s refresh];
    }];
}

// Mediathek video streamed online: its show's other episodes, from the same show page "Zur Sendung"
// opens (registered loader for item.showRef). Downloaded shows use the library instead (episodesShelf).
- (void)loadShowEpisodesFor:(SFItem *)it {
    if ([it.source isEqualToString:@"youtube"] || it.kind != SFItemVideo || ![SFNet isOnline]) return;
    if ([[SFLibrary shared] showNamed:it.channel source:it.source].episodes.count >= 2) return;
    __weak SFPlayerInfoScreen *ws = self;
    if (!it.showRef.length) {
        // list items without a show reference (ORF highlights): ask the source once, then load
        SFShowRefLookup lookup = SFShowRefLookupFor(it.source);
        if (!lookup) return;
        lookup(it, ^(NSString *ref) {
            SFPlayerInfoScreen *s = ws;
            if (!s || s->_item != it || !ref.length) return;
            it.showRef = ref;          // remembered on the item: "Zur Sendung" opens it directly now
            [s loadShowEpisodesFor:it];
            [s refresh];
        });
        return;
    }
    // no title: the Mediathek show pages name themselves (`channel` can be just the genre, e.g. ORF lists)
    SFPageLoader loader = SFShowPageLoader(it.showRef, nil);
    if (!loader) return;
    loader(^(SFPage *page, NSError *e) {
        SFMain(^{
            SFPlayerInfoScreen *s = ws;
            if (!s || s->_item != it || !page) return;
            NSMutableArray *eps = [NSMutableArray new];
            NSMutableSet *seen = [NSMutableSet new];
            for (SFShelf *sh in page.shelves) for (SFItem *x in sh.items) {
                if (x.kind != SFItemVideo || !x.identifier || [seen containsObject:x.identifier] || eps.count >= 40) continue;
                [seen addObject:x.identifier]; [eps addObject:x];
            }
            if (eps.count < 2) return;
            s->_showEpisodes = eps;
            s->_showTitle = page.title.length ? page.title : it.channel;
            SFLog(@"info: %lu episodes of %@", (unsigned long)eps.count, s->_showTitle);
            [s refresh];
        });
    });
}

// Closed (MENU, chosen entry) but not yet deallocated: no more work, no requests for later items
- (BOOL)isShown {
    SFNavigator *nav = self.navigator ?: _nav;
    return nav && [nav.stack containsObject:self];
}

- (void)playerChanged:(NSNotification *)n {
    if (![self isShown]) return;
    SFPlayerScreen *p = _player;
    if (!p || [n.userInfo[@"closed"] boolValue]) { [self leave]; return; }
    if (p.item != _item) { [self loadForItem:p.item]; return; }
    [self scheduleRefresh];   // e.g. tracks became available once the engine is ready
}

// State notifications come in bursts (buffering, rate): coalesce
- (void)scheduleRefresh {
    if (_refreshQueued) return;
    _refreshQueued = YES;
    __weak SFPlayerInfoScreen *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SFPlayerInfoScreen *s = ws;
        if (!s) return;
        s->_refreshQueued = NO;
        [s refresh];
    });
}

static NSString *SFSig(SFItem *i) {
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%lu|%d", i.identifier ?: @"", i.title ?: @"", i.badge ?: @"", i.heroMeta ?: @"",
            (unsigned long)i.plot.length, i.tint != nil];
}

// Rebuild the page model and apply only what changed: same shelves -> changed rows in place
// (no flicker, focus stays), otherwise a full rebuild that keeps the focus.
- (void)refresh {
    if (!_player || _player.item != _item || ![self isShown]) return;
    SFPage *np = [self buildPage];
    SFPage *cur = self.page;
    BOOL same = cur && cur.shelves.count == np.shelves.count;
    for (NSUInteger i = 0; same && i < np.shelves.count; i++) {
        SFShelf *a = cur.shelves[i], *b = np.shelves[i];
        same = [(a.title ?: @"") isEqualToString:(b.title ?: @"")] && a.items.count == b.items.count;
    }
    if (!same) { [self setPage:np keepFocus:YES]; return; }
    for (NSUInteger i = 0; i < np.shelves.count; i++) {
        SFShelf *a = cur.shelves[i], *b = np.shelves[i];
        BOOL changed = NO;
        for (NSUInteger k = 0; k < a.items.count && !changed; k++) changed = ![SFSig(a.items[k]) isEqualToString:SFSig(b.items[k])];
        if (changed) [self replaceItemsOfShelf:a with:b.items];
        else for (NSUInteger k = 0; k < a.items.count; k++) {   // same look: keep the shown tiles, take the new handlers
            id h = [_handlers objectForKey:b.items[k]];
            if (h) [_handlers setObject:h forKey:a.items[k]];
        }
    }
}

#pragma mark Page

- (SFItem *)hero {   // what the hero shows for the running video
    SFItem *it = _item;
    NSMutableArray *meta = [NSMutableArray new];
    NSString *ch = it.channel.length ? it.channel : _details[@"channel"];
    if (ch.length && ![ch isEqualToString:it.title]) [meta addObject:ch];
    NSDate *d = it.date ?: _details[@"date"];
    if (d) [meta addObject:SFFormatDateShort(d)];
    if (it.kind == SFItemLive) [meta addObject:@"Live"];
    else {
        NSTimeInterval dur = [_player duration];
        if (dur > 0) [meta addObject:SFFormatDuration(dur)];
    }
    SFItem *h = [SFItem new];
    h.heroTitle = it.title.length ? it.title : @"Video";
    h.heroMeta = meta.count ? [meta componentsJoinedByString:@"  ·  "] : @" ";
    h.plot = it.plot.length ? it.plot : _details[@"description"];
    return h;
}

// The running video with what the watch page added (channel ID for "Zum Kanal"/"Folgen")
- (SFItem *)enrichedItem {
    SFItem *it = _item;
    NSString *cid = _details[@"channelID"];
    if (it.showRef || !cid) return it;
    SFItem *c = [it copy];
    c.showRef = [@"ytchannel:" stringByAppendingString:cid];
    if (!c.channel.length) c.channel = _details[@"channel"];
    return c;
}

- (SFItem *)button:(NSString *)ident title:(NSString *)title hero:(SFItem *)hero action:(dispatch_block_t)action {
    SFItem *b = [SFItem new];
    b.kind = SFItemAction; b.style = SFTileStyleButton;
    b.identifier = [@"info:" stringByAppendingString:ident];
    b.title = title;
    b.heroTitle = hero.heroTitle; b.heroMeta = hero.heroMeta; b.plot = hero.plot;   // hero keeps showing the video
    b.action = action;
    return b;
}

- (SFPage *)buildPage {
    [_handlers removeAllObjects];
    SFPage *page = [SFPage page:_item.title theme:self.theme.identifier shelves:@[]];
    SFPlayerScreen *p = _player;
    if (!p || !_item) return page;
    SFItem *hero = [self hero];
    NSMutableArray *shelves = [NSMutableArray new];
    NSArray *actions = [self actionsWithHero:hero];
    [shelves addObject:[SFShelf shelf:nil style:SFTileStyleButton items:actions]];
    SFShelf *q = [self queueShelf];
    if (q) [shelves addObject:q];
    SFShelf *eps = [self episodesShelf];
    if (eps) [shelves addObject:eps];
    SFShelf *rec = [self recommendationsShelf];
    if (rec) [shelves addObject:rec];
    page.shelves = shelves;
    return page;
}

- (NSArray *)actionsWithHero:(SFItem *)hero {
    SFPlayerScreen *p = _player;
    SFItem *it = [self enrichedItem];
    __weak SFNavigator *nav = self.navigator;   // blocks live in the page: no strong path back to the navigator
    __weak SFPlayerInfoScreen *ws = self;
    __weak SFPlayerScreen *wp = p;
    NSMutableArray *a = [NSMutableArray new];
    BOOL live = it.kind == SFItemLive;

    // Audio / subtitles (only when there is a choice); the choices are taken fresh when chosen
    if ([p tracksAvailable]) {
        for (NSString *type in @[@"audio", @"sub"]) {
            NSArray *choices = [p trackChoices:type];
            if (choices.count < 2) continue;
            BOOL audio = [type isEqualToString:@"audio"];
            NSString *name = audio ? @"Ton" : @"Untertitel";
            [a addObject:[self button:type title:[NSString stringWithFormat:@"%@: %@", name, [p currentChoice:choices]] hero:hero action:^{
                SFPlayerScreen *pl = wp;
                if (![pl tracksAvailable]) return;
                NSArray *c = [pl trackChoices:type];
                if (c.count) [pl showChoices:c type:type title:name on:ws.navigator ?: nav];
            }]];
        }
    }
    // Downloaded file: online there are all audio and subtitle tracks
    if ([p canSwitchToStream]) {
        [a addObject:[self button:@"online" title:@"Online abspielen" hero:hero action:^{ [wp switchToStream]; }]];
    }
    // Channel / show page; leaving the video for it replaces the player (progress is saved)
    SFShowLink *link = [SFShowLink linkFor:it here:nil pageTitle:nil];
    if (link) {
        [a addObject:[self button:@"show" title:link.title hero:hero action:^{
            SFNavigator *n = ws.navigator ?: nav;
            [link openOn:n stillValid:^BOOL { return ws && n.top == ws; } present:^(SFScreen *screen) {
                SFPlayerScreen *pl = wp;
                if (pl && [n.stack containsObject:pl]) { [n popAbove:pl]; [n replaceTop:screen]; }
                else [n push:screen];
            }];
        }]];
    }
    // Follow the channel / show (needs its identifier; YouTube: known once the watch page arrived)
    SFItem *folder = [link.folder copy];
    SFFollows *fo = [SFFollows shared];
    if (folder && [fo canFollow:folder]) {
        if (!folder.image.length && _details[@"avatar"]) folder.image = _details[@"avatar"];
        BOOL following = [fo isFollowing:folder.identifier];
        SFItem *b = [self button:@"follow" title:following ? @"✓  Gefolgt" : @"Folgen" hero:hero action:^{
            SFToggleFollow(ws.navigator ?: nav, folder, ws.theme);
        }];
        if (!following) b.tint = self.theme.accent;
        [a addObject:b];
    }
    // Download state of this video (offline layer)
    if (!live && !it.drm && it.identifier) {
        SFDownloads *dl = [SFDownloads shared];
        double dp = 0;
        SFDLState ds = [dl stateFor:it.identifier progress:&dp];
        NSString *ident = it.identifier;
        if (ds == SFDLQueued || ds == SFDLRunning) {
            NSString *t = ds == SFDLRunning ? [NSString stringWithFormat:@"Download abbrechen (%d %%)", (int)round(dp * 100)] : @"Download abbrechen (wartet)";
            [a addObject:[self button:@"download" title:t hero:hero action:^{
                [dl remove:ident];
                [(ws.navigator ?: nav) toast:@"Download abgebrochen"];
            }]];
        } else if (ds == SFDLDone) {
            [a addObject:[self button:@"download" title:@"Download löschen" hero:hero action:^{
                SFNavigator *n = ws.navigator ?: nav;
                // Destructive and possibly the very file that is playing: ask, naming the video - and
                // say so when the copy is irreplaceable (kept, or no longer online), as the context menu does
                BOOL kept = [dl isKept:ident], gone = [dl onlineStateFor:ident] == 0;
                SFMenuOption *no = [SFMenuOption option:@"Abbrechen" action:^{}];
                SFMenuOption *yes = [SFMenuOption option:kept || gone ? @"Ja, endgültig löschen" : @"Ja, Download löschen" action:^{
                    [dl remove:ident];
                    [n toast:kept || gone ? @"Download gelöscht" : @"Download gelöscht – das Video bleibt online verfügbar"];
                }];
                NSString *sub = gone ? [NSString stringWithFormat:@"„%@“ ist nicht mehr online – die Kopie hier ist die einzige.", it.title]
                              : kept ? [NSString stringWithFormat:@"„%@“ ist als „Behalten“ markiert.", it.title] : it.title;
                SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:@"Download löschen?" subtitle:sub options:@[no, yes] theme:ws.theme];
                m.subtitleLines = 4;
                [n push:m];
            }]];
        } else if (it.resolverRef || it.resolver) {
            SFItem *dlItem = [it copy];
            dlItem.streamOnly = NO;
            [a addObject:[self button:@"download" title:@"Herunterladen" hero:hero action:^{
                [dl download:dlItem];
                [(ws.navigator ?: nav) toast:@"Wird heruntergeladen – auch offline verfügbar"];
            }]];
        }
    }
    // Shared watch-later list
    if (!live && !it.drm && it.identifier && it.kind == SFItemVideo) {
        SFWatchLater *wl = [SFWatchLater shared];
        BOOL in = [wl contains:it.identifier];
        SFItem *wlItem = [it copy];
        wlItem.streamOnly = NO;
        NSString *ident = it.identifier;
        [a addObject:[self button:@"later" title:in ? @"✓  Später ansehen" : @"Später ansehen" hero:hero action:^{
            SFNavigator *n = ws.navigator ?: nav;
            if ([wl contains:ident]) { [wl remove:ident]; [n toast:@"Aus „Später ansehen“ entfernt"]; }
            else { [wl add:wlItem]; [n toast:@"Gemerkt – steht unter „Später ansehen“"]; }
            [ws refresh];
        }]];
    }
    // Never an empty panel: MENU is the way back, but a visible button teaches it
    if (!a.count) [a addObject:[self button:@"back" title:@"Zurück zum Video" hero:hero action:^{ [ws leave]; }]];
    return a;
}

// Shown copy of a video with its OK action
- (SFItem *)tile:(SFItem *)src badge:(NSString *)badge action:(dispatch_block_t)action {
    SFItem *c = [src copy];
    c.style = SFTileStyleLandscape;
    if (badge) c.badge = badge;
    if (action) [_handlers setObject:[action copy] forKey:c];
    return c;
}

// Playlist / phone queue: what autoplay will actually play
- (SFShelf *)queueShelf {
    SFPlayerScreen *p = _player;
    NSArray *q = p.queue;
    NSUInteger idx = p.queueIndex;
    if (!q.count || idx >= q.count) return nil;
    __weak SFPlayerInfoScreen *ws = self;
    __weak SFPlayerScreen *wp = p;
    SFItem *cur = _item;
    NSMutableArray *items = [NSMutableArray new];
    NSUInteger focus = 0;
    BOOL playlist = !p.hasExplicitQueue && cur.playlistID.length;
    if (!p.hasExplicitQueue && !playlist) return nil;   // a plain shelf: autoplay does not follow it
    for (NSUInteger k = 0; k < q.count; k++) {
        SFItem *e = q[k];
        if (playlist && ![e.playlistID isEqualToString:cur.playlistID]) continue;
        if (!playlist && k <= idx) continue;   // phone queue: the upcoming entries
        BOOL running = k == idx && e == cur;
        if (running) focus = items.count;
        [items addObject:[self tile:e badge:running ? kRunningBadge : nil action:^{
            SFPlayerInfoScreen *s = ws; SFPlayerScreen *pl = wp;
            if (running || !pl) { [s leave]; return; }
            if (e.drm) { [s.navigator toast:SFDRMNotice]; return; }
            NSUInteger at = [pl.queue indexOfObjectIdenticalTo:e];
            if (at == NSNotFound) return;   // the queue was replaced meanwhile
            [s leave];
            [pl playQueueIndex:at at:0];
        }]];
    }
    if (!items.count) return nil;
    SFShelf *sh = [SFShelf shelf:playlist ? @"Playlist" : @"Als Nächstes" style:SFTileStyleLandscape items:items];
    sh.focusIndex = focus;
    return sh;
}

// Other episodes: library show (downloads) or the online show page (loadShowEpisodesFor:)
- (SFShelf *)episodesShelf {
    SFItem *cur = _item;
    SFShow *show = cur.channel.length && (cur.localPath || [_player canSwitchToStream]) ? [[SFLibrary shared] showNamed:cur.channel source:cur.source] : nil;
    NSArray *episodes = show.episodes.count >= 2 ? show.episodes : _showEpisodes;
    NSString *name = show.episodes.count >= 2 ? show.name : _showTitle;
    if (episodes.count < 2) return nil;
    __weak SFPlayerInfoScreen *ws = self;
    __weak SFPlayerScreen *wp = _player;
    NSMutableArray *items = [NSMutableArray new];
    NSUInteger focus = 0;
    for (SFItem *e in episodes) {
        BOOL running = (cur.localPath && [e.localPath isEqualToString:cur.localPath]) || (e.identifier && [e.identifier isEqualToString:cur.identifier]);
        if (running) focus = items.count;
        [items addObject:[self tile:e badge:running ? kRunningBadge : nil action:^{
            SFPlayerInfoScreen *s = ws; SFPlayerScreen *pl = wp;
            [s leave];
            if (!running && pl) [pl playItem:e];
        }]];
    }
    SFShelf *sh = [SFShelf shelf:[NSString stringWithFormat:@"Weitere Folgen von „%@“", name] style:SFTileStyleLandscape items:items];
    sh.focusIndex = focus;
    return sh;
}

- (SFShelf *)recommendationsShelf {
    if (!_related.count) return nil;
    __weak SFPlayerInfoScreen *ws = self;
    __weak SFPlayerScreen *wp = _player;
    NSMutableArray *items = [NSMutableArray new];
    for (SFItem *r in _related) {
        [items addObject:[self tile:r badge:nil action:^{
            SFPlayerInfoScreen *s = ws; SFPlayerScreen *pl = wp;
            if (r.drm) { [s.navigator toast:SFDRMNotice]; return; }
            [s leave];
            [pl playItem:r];
        }]];
    }
    return [SFShelf shelf:@"Empfehlungen" style:SFTileStyleLandscape items:items];
}

#pragma mark Input / lifecycle

- (void)choose:(SFItem *)item {
    if (item.kind == SFItemAction) { if (item.action) item.action(); return; }
    dispatch_block_t h = [_handlers objectForKey:item];
    if (h) h();
}

- (void)didAppear {
    [super didAppear];
    if (self.navigator) _nav = self.navigator;
}

// Back from a track choice (or any menu on top): labels may have changed - mpv applies a new
// subtitle track asynchronously, so look again shortly after
- (void)willAppear {
    [super willAppear];
    if (self.page) {
        [self scheduleRefresh];
        __weak SFPlayerInfoScreen *ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws scheduleRefresh]; });
    }
}

static BOOL SFIsCovered(SFNavigator *nav, SFScreen *s) {
    NSArray *st = nav.stack;
    NSUInteger i = [st indexOfObjectIdenticalTo:s];
    if (i == NSNotFound) return NO;
    for (NSUInteger k = i + 1; k < st.count; k++) if ([st[k] isOpaque]) return YES;
    return NO;
}

// Covered by a full screen opened from here (channel page, "Abspielen" in a context menu): the
// video is left behind - remove the panel and the player (saves progress, stops playback), so MENU
// from there goes back to where the video was started instead of to a dead player.
- (void)willDisappear {
    [super willDisappear];
    __weak SFPlayerInfoScreen *ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SFPlayerInfoScreen *s = ws;
        if (!s) return;
        SFNavigator *nav = s->_nav;
        if (!nav) return;
        if (SFIsCovered(nav, s)) [nav removeScreen:s];
        SFPlayerScreen *p = s->_player;
        if (p && SFIsCovered(nav, p)) {
            SFLog(@"info: covered by another screen - leaving the player");
            [nav removeScreen:p];
        }
    });
}

// Close the panel (back to the video); works whether or not it is on top
- (void)leave {
    if (![self isShown]) return;
    SFNavigator *nav = self.navigator ?: _nav;
    SFLog(@"info: panel closed");
    if (nav.top == self) [nav pop];
    else [nav removeScreen:self];
}

- (BOOL)handleKey:(SFKey)key {
    switch (key) {
        case SFKeyMenu:   // straight back to the video (no "scroll up first")
            [self leave];
            return YES;
        case SFKeyPlayPause: {   // controls the video underneath, the panel stays
            SFPlayerScreen *p = _player;
            if (!p) return YES;
            BOOL wasPaused = [p isPaused];
            [p togglePause];
            [self.navigator toast:wasPaused ? @"Wiedergabe läuft" : @"Angehalten"];
            return YES;
        }
        default:
            return [super handleKey:key];
    }
}

@end
