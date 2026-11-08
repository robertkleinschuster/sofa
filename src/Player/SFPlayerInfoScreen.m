#import "SFPlayerInfoScreen+Private.h"
#import "SFDownloads.h"
#import "SFFollows.h"
#import "SFWatchLater.h"
#import "SFLibrary.h"
#import "SFNet.h"
#import "SFFollowAction.h"

static NSString *const kRunningBadge = @"Läuft";

@implementation SFPlayerInfoScreen

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
    _actionOrder = [NSMutableArray new];   // a new video: its actions take their places afresh
    [self setPage:[self buildPage] keepFocus:NO];
    [self loadShowEpisodesFor:it];
    // the app's details + recommendations (YouTube: watch page) - never a spinner: absent until it arrives
    Class<SFApp> app = [SFAppRegistry appForItem:it];
    if (![app respondsToSelector:@selector(watchDetailsForItem:done:)]) return;
    __weak SFPlayerInfoScreen *ws = self;
    [app watchDetailsForItem:it done:^(NSArray *related, NSDictionary *details) {
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
    // apps with their own recommendations (watchDetailsForItem:) show those instead
    if ([[SFAppRegistry appForItem:it] respondsToSelector:@selector(watchDetailsForItem:done:)] || it.kind != SFItemVideo || ![SFNet isOnline]) return;
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
    // no title: the Mediathek show pages name themselves (ORF lists name no show)
    SFPageLoader loader = SFShowPageLoader(it.showRef, nil);
    if (!loader) return;
    loader(^(SFPage *page, NSError *e) {
        SFMain(^{
            SFPlayerInfoScreen *s = ws;
            if (!s || s->_item != it || !page) return;
            // the show page names the show: remembered on the item like its ref ("Zur Sendung „…“", hero)
            if (!it.channel.length && page.title.length) { it.channel = page.title; [s refresh]; }
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
    // the app's own page names the video as its uploader did (YouTube lists: a localized title)
    NSString *title = [_details[@"title"] length] ? _details[@"title"] : it.title;
    h.heroTitle = title.length ? title : @"Video";
    h.heroMeta = meta.count ? [meta componentsJoinedByString:@"  ·  "] : @" ";
    h.plot = it.plot.length ? it.plot : _details[@"description"];
    return h;
}

// The running video with what the app's details added (show ref for "Zum Kanal"/"Folgen")
- (SFItem *)enrichedItem {
    SFItem *it = _item;
    NSString *ref = _details[@"showRef"];
    if (it.showRef || !ref) return it;
    SFItem *c = [it copy];
    c.showRef = ref;
    if (!c.channel.length) c.channel = _details[@"channel"];
    return c;
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
