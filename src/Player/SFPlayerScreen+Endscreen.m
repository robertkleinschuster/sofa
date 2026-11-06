// SFPlayerScreen - end cards: the tiles a creator places over the last seconds of a video (other
// videos, a playlist, channels, a follow button), at the creator's positions over the picture.
//
// Data: generic end cards (format: SFApp.h "endCards") in the stream description of the open URL -
// the app converts its own data (YouTube: the SABR sidecar's /open answer). No request of its own
// here, only the thumbnails are loaded (and only once a tile is about to show). Opening goes
// through the app that owns the card's ref.
//
// Remote (7 buttons), never stealing normal playback keys unexpectedly:
//  - tiles appear (subtle) with a hint "[▼] Empfehlungen des Kanals" above them; all keys keep
//    their player meaning, except DOWN, which moves the focus into the tiles - unless the viewer is
//    just adjusting the volume (DOWN within 2 s of a volume step stays volume)
//  - with focus: arrows move spatially between tiles, OK opens (video plays here, playlist plays as
//    playlist, channel -> channel page, follow toggles following), MENU (or UP at the top) goes back
//    to normal playback; Play/Pause keeps working; the hint names what OK will do
//  - the tiles follow the timeline (each element its own window; seeking back hides them, also
//    while paused); at the end of the video the "Als Nächstes" card takes over - unless the
//    viewer is choosing among the tiles: then the end flow waits until they leave the tiles
#import "SFPlayerScreen+Private.h"
#import "SFPlayerInfoScreen.h"
#import "SFBrowseScreen.h"
#import "SFFollows.h"
#import "SFEndTile.h"
#import "SFFollowAction.h"

#pragma mark - Player category

@implementation SFPlayerScreen (Endscreen)

static double SFNum(id v) { return [v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]] ? [v doubleValue] : 0; }
static NSString *SFStr(id v) { return [v isKindOfClass:[NSString class]] && [v length] ? v : nil; }

- (SFTheme *)esTheme { return [SFTheme themeNamed:_item.source ?: @"home"]; }
- (BOOL)esEngaged { return _esFocus >= 0 && _esFocus < (NSInteger)_esTiles.count; }

- (void)esReset {
    [_esLayer removeFromSuperlayer]; _esLayer = nil; _esScrim = nil; _esHint = nil;
    _esTiles = nil; _esData = nil; _esFocus = -1; _esShown = NO; _esEndDeferred = NO;
    _esVideoRect = CGRectZero;
}

// The picture inside the (full-screen) video layer: aspect fit, as mpv draws it
- (CGRect)esComputeVideoRect {
    CGRect b = self.layer.bounds;
    CGSize vs = [_engine respondsToSelector:@selector(videoSize)] ? [_engine videoSize] : CGSizeZero;
    if (!(vs.width > 0 && vs.height > 0)) vs = CGSizeMake(16, 9);
    CGFloat s = MIN(b.size.width / vs.width, b.size.height / vs.height);
    CGFloat w = round(vs.width * s), h = round(vs.height * s);
    return CGRectMake(round((b.size.width - w) / 2), round((b.size.height - h) / 2), w, h);
}

- (void)esBuild:(NSArray *)data {
    [self esReset];
    _esData = data;
    if (!data.count) return;
    NSMutableArray *tiles = [NSMutableArray new];
    for (NSDictionary *e in data) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *st = SFStr(e[@"kind"]), *ref = SFStr(e[@"ref"]);
        BOOL ok = ref && [SFAppRegistry appForRef:ref]
               && ([st isEqualToString:SFEndCardVideo] || [st isEqualToString:SFEndCardPlaylist]
                   || (([st isEqualToString:SFEndCardChannel] || [st isEqualToString:SFEndCardFollow]) && [SFAppRegistry isShowRef:ref]));
        double w = SFNum(e[@"width"]), ar = SFNum(e[@"aspectRatio"]);
        if (!ok || !(w > 0.01) || !(ar > 0.05)) continue;
        SFEndTile *t = [SFEndTile layer];
        t.element = e; t.kind = st;
        t.startS = SFNum(e[@"startMs"]) / 1000.0;
        t.endS = SFNum(e[@"endMs"]) / 1000.0;
        t.opacity = 0;
        [tiles addObject:t];
    }
    _esTiles = tiles;
    if (!tiles.count) return;
    double first = HUGE_VAL;
    for (SFEndTile *t in tiles) first = MIN(first, t.startS);
    SFLog(@"endscreen: %lu tiles from %.1f s", (unsigned long)tiles.count, first);
    _esLayer = [CALayer layer];
    _esScrim = [CALayer layer];
    _esScrim.backgroundColor = [NSColor colorWithDeviceWhite:0 alpha:0.5].CGColor;
    _esScrim.opacity = 0;
    [_esLayer addSublayer:_esScrim];
    for (SFEndTile *t in tiles) [_esLayer addSublayer:t];
    _esHint = [CALayer layer];
    _esHint.opacity = 0;
    [_esLayer addSublayer:_esHint];
    SFNoAnimate(^{ [self.layer insertSublayer:self->_esLayer above:self->_videoHost]; });
    [self esPlace];
}

// Tiles at the creator's positions: fractions of the picture (letterboxing respected); height from
// the element's aspect ratio
- (void)esPlace {
    if (!_esLayer) return;
    _esVideoRect = [self esComputeVideoRect];
    CGRect vr = _esVideoRect;
    SFTheme *th = [self esTheme];
    SFNoAnimate(^{
        if (self->_esLayer.superlayer != self.layer || [self.layer.sublayers indexOfObject:self->_esLayer] != [self.layer.sublayers indexOfObject:self->_videoHost] + 1)
            [self.layer insertSublayer:self->_esLayer above:self->_videoHost];   // relayout re-added the OSD: stay below it
        self->_esLayer.frame = self.layer.bounds;
        self->_esScrim.frame = self.layer.bounds;
        for (SFEndTile *t in self->_esTiles) {
            NSDictionary *e = t.element;
            CGFloat w = SFNum(e[@"width"]) * vr.size.width;
            CGFloat h = w / SFNum(e[@"aspectRatio"]);
            CGRect f = CGRectMake(vr.origin.x + SFNum(e[@"left"]) * vr.size.width, vr.origin.y + SFNum(e[@"top"]) * vr.size.height, w, h);
            if (t.round) f.size.height = f.size.width;   // avatars are circles even with a rounded aspect ratio
            f = CGRectIntegral(f);
            if (CGRectEqualToRect(t.frame, f) && t.sublayers.count) continue;
            BOOL hadImage = t.sublayers.count > 0;
            for (CALayer *l in [t.sublayers copy]) [l removeFromSuperlayer];
            t.transform = CATransform3DIdentity;
            t.frame = f;
            [t buildWithTheme:th];
            if (hadImage || t.shownNow) [t loadImage];
        }
    });
    SFLog(@"endscreen: video rect %@", NSStringFromRect(NSRectFromCGRect(vr)));
    [self esRefreshLook];
}

- (void)esLayout {
    if (!_esLayer) return;
    [self esPlace];
}

// What the end screen shows at the current time; called on every tick (also while paused), after
// seeks, at the end and on relayout. Robust against any order: the data is looked up afresh.
- (void)esUpdate {
    NSArray *data = SFMPVSourceFor(_openURL)[@"endCards"];
    if (![data isKindOfClass:[NSArray class]] || _failed || !_engine) data = nil;
    if (data != _esData) [self esBuild:data];
    if (!_esTiles.count) return;
    if (!CGRectEqualToRect([self esComputeVideoRect], _esVideoRect)) [self esPlace];   // video size known later
    if (!_ended) _esEndDeferred = NO;
    double t = [self currentTime], first = HUGE_VAL;
    for (SFEndTile *x in _esTiles) first = MIN(first, x.startS);
    BOOL engaged = [self esEngaged];
    if (engaged && t < first - 0.5 && !_ended) {   // seeked back before the end screen (phone, restart)
        SFLog(@"endscreen: seeked before the end screen - leaving the tiles");
        [self esLeave:NO];
        engaged = NO;
    }
    BOOL any = NO, changed = NO;
    SFFollows *fo = [SFFollows shared];
    for (SFEndTile *x in _esTiles) {
        BOOL inWindow = t >= x.startS && (x.endS <= 0 || t < x.endS);
        // with focus the tiles stay (the end card waits); otherwise each one follows its own window,
        // and after the end the "up next" card has the screen
        BOOL show = engaged ? (x.shownNow || inWindow) : (!_ended && inWindow);
        if (show != x.shownNow) { x.shownNow = show; changed = YES; if (show) [x loadImage]; }
        if ([x.kind isEqualToString:SFEndCardFollow]) {
            BOOL f = [fo isFollowing:SFStr(x.element[@"ref"])];
            if (f != x.following) { x.following = f; changed = YES; }
        }
        any = any || show;
    }
    if (any != _esShown) {
        _esShown = any;
        SFLog(@"endscreen: %@", any ? [NSString stringWithFormat:@"shown at %.1f s", t] : @"hidden");
    }
    if (changed) [self esRefreshLook];
}

- (void)esRefreshLook {
    BOOL engaged = [self esEngaged];
    for (NSUInteger i = 0; i < _esTiles.count; i++) {
        SFEndTile *t = _esTiles[i];
        [t setLook:engaged focused:engaged && (NSInteger)i == _esFocus bounds:_esVideoRect];
    }
    SFAnimate(0.3, ^{ self->_esScrim.opacity = engaged ? 1 : 0; });
    [self esLayoutHint];
}

// Hint above the visible tiles (below them when there is no room): how to get in, and once inside
// what OK does on the focused tile and how to get back
- (void)esLayoutHint {
    if (!_esHint) return;
    CGRect u = CGRectNull;
    for (SFEndTile *t in _esTiles) if (t.shownNow) u = CGRectUnion(u, t.frame);
    if (CGRectIsNull(u)) { SFAnimate(0.25, ^{ self->_esHint.opacity = 0; }); return; }
    SFTheme *th = [self esTheme];
    BOOL engaged = [self esEngaged];
    NSColor *fg = [NSColor colorWithDeviceWhite:1 alpha:0.92];
    SFNoAnimate(^{
        for (CALayer *l in [self->_esHint.sublayers copy]) [l removeFromSuperlayer];
        CGFloat h = U(50), pad = U(18);
        __block CGFloat x = pad;
        // key cap like the OSD's "[OK] halten: Info"
        void (^key)(NSString *) = ^(NSString *cap) {
            NSFont *kf = [th bold:20];
            CGFloat kw = MAX(U(40), ceil([cap sizeWithAttributes:@{NSFontAttributeName: kf}].width) + U(18));
            CALayer *k = [CALayer layer];
            k.frame = CGRectMake(x, (h - U(32)) / 2, kw, U(32));
            k.borderColor = fg.CGColor; k.borderWidth = U(2); k.cornerRadius = U(7);
            SFLabel *kl = [SFLabel labelWithFont:kf color:fg];
            kl.text = cap; kl.alignment = NSCenterTextAlignment;
            [kl sizeToFitWidth:kw];
            kl.position = CGPointMake(0, (U(32) - kl.bounds.size.height) / 2);
            [k addSublayer:kl];
            [self->_esHint addSublayer:k];
            x += kw + U(12);
        };
        void (^text)(NSString *, BOOL) = ^(NSString *s, BOOL dim) {
            NSFont *f = [th medium:24];
            SFLabel *l = [SFLabel labelWithFont:f color:dim ? [NSColor colorWithDeviceWhite:1 alpha:0.7] : fg];
            l.text = s;
            CGFloat w = ceil([s sizeWithAttributes:@{NSFontAttributeName: f}].width) + U(2);
            [l sizeToFitWidth:w];
            l.position = CGPointMake(x, (h - l.bounds.size.height) / 2);
            [self->_esHint addSublayer:l];
            x += w;
        };
        if (engaged) {
            key(@"OK"); text([self->_esTiles[self->_esFocus] okAction], NO);
            x += U(30);
            key(@"MENU"); text(@"zurück zum Video", YES);
        } else {
            key(@"▼"); text(@"Empfehlungen des Kanals", NO);
        }
        CGFloat w = x + pad;
        self->_esHint.bounds = CGRectMake(0, 0, w, h);
        self->_esHint.cornerRadius = h / 2;
        self->_esHint.backgroundColor = [NSColor colorWithDeviceWhite:0.04 alpha:0.78].CGColor;
        // Place it where it covers no tile: above all tiles, below them, above/below a single tile,
        // at the top or bottom of the picture - first free spot wins (centred on the tiles, then the
        // screen, then the sides); creators fill the frame in many ways
        CGRect vr = CGRectIntersection(self->_esVideoRect, self.layer.bounds);
        CGFloat gap = U(engaged ? 34 : 22), m = U(24);   // focused tiles grow (scale + ring)
        NSMutableArray *rects = [NSMutableArray new];
        for (SFEndTile *t in self->_esTiles) if (t.shownNow) {
            CGRect f = CGRectInset(t.frame, -U(12), -U(12));
            if (t.round) f.size.height += U(30);   // follow pill below the avatar
            [rects addObject:[NSValue valueWithRect:NSRectFromCGRect(f)]];
            CGRect cap = [t captionFrame];
            if (!CGRectIsNull(cap)) [rects addObject:[NSValue valueWithRect:NSRectFromCGRect(CGRectInset(cap, -U(12), -U(12)))]];
        }
        // anchored to the tile the hint talks about: the focused one, else the one DOWN enters
        CGRect a = engaged ? [self->_esTiles[self->_esFocus] frame] : [self esEntryTile].frame;
        NSMutableArray *ys = [@[@(CGRectGetMinY(a) - gap - h), @(CGRectGetMaxY(a) + gap), @(CGRectGetMinY(u) - gap - h), @(CGRectGetMaxY(u) + gap)] mutableCopy];
        for (SFEndTile *t in self->_esTiles) if (t.shownNow) { [ys addObject:@(CGRectGetMinY(t.frame) - gap - h)]; [ys addObject:@(CGRectGetMaxY(t.frame) + gap)]; }
        [ys addObject:@(CGRectGetMinY(vr) + m)]; [ys addObject:@(CGRectGetMaxY(vr) - m - h)];
        NSArray *xs = @[@(CGRectGetMinX(a)), @(CGRectGetMidX(a) - w / 2), @(CGRectGetMidX(u) - w / 2), @(CGRectGetMidX(vr) - w / 2), @(CGRectGetMinX(vr) + m), @(CGRectGetMaxX(vr) - m - w)];
        CGRect best = CGRectNull; CGFloat bestCover = HUGE_VAL;
        for (NSNumber *yv in ys) for (NSNumber *xv in xs) {
            if (bestCover <= 0) break;
            CGFloat x0 = MIN(MAX(xv.doubleValue, CGRectGetMinX(vr) + m), CGRectGetMaxX(vr) - m - w);
            CGRect c = CGRectMake(x0, yv.doubleValue, w, h);
            if (CGRectGetMinY(c) < CGRectGetMinY(vr) + U(12) || CGRectGetMaxY(c) > CGRectGetMaxY(vr) - U(12)) continue;
            CGFloat cover = 0;
            for (NSValue *r in rects) { CGRect i = CGRectIntersection(c, NSRectToCGRect(r.rectValue)); if (!CGRectIsNull(i)) cover += i.size.width * i.size.height; }
            if (cover < bestCover - 1) { bestCover = cover; best = c; }
        }
        if (CGRectIsNull(best)) best = CGRectMake(CGRectGetMidX(vr) - w / 2, CGRectGetMaxY(vr) - m - h, w, h);
        CGFloat cx = CGRectGetMidX(best), y = CGRectGetMinY(best);
        self->_esHint.position = CGPointMake(round(cx), round(y + h / 2));
    });
    SFAnimate(0.3, ^{ self->_esHint.opacity = 1; });
}

- (void)devSetEndscreen:(NSArray *)elements {
    if (!_openURL) return;
    NSMutableDictionary *d = [SFMPVSourceFor(_openURL) mutableCopy] ?: [NSMutableDictionary new];
    if (elements) d[@"endCards"] = elements; else [d removeObjectForKey:@"endCards"];
    SFSetMPVSource(_openURL, d);
    [self esUpdate];
}

#pragma mark Focus

- (NSArray *)esVisible {
    NSMutableArray *a = [NSMutableArray new];
    for (SFEndTile *t in _esTiles) if (t.shownNow) [a addObject:t];
    return a;
}

// Where DOWN enters: reading order - the top row (tiles reaching up to the topmost one's middle), leftmost
- (SFEndTile *)esEntryTile {
    NSArray *vis = [self esVisible];
    SFEndTile *top = nil;
    for (SFEndTile *t in vis) if (!top || CGRectGetMinY(t.frame) < CGRectGetMinY(top.frame)) top = t;
    SFEndTile *pick = nil;
    for (SFEndTile *t in vis) {
        if (CGRectGetMinY(t.frame) > CGRectGetMidY(top.frame)) continue;
        if (!pick || CGRectGetMinX(t.frame) < CGRectGetMinX(pick.frame)) pick = t;
    }
    return pick;
}

- (void)esEnter {
    SFEndTile *pick = [self esEntryTile];
    if (!pick) return;
    _esFocus = [_esTiles indexOfObjectIdenticalTo:pick];
    SFLog(@"endscreen: focus %ld (%@)", (long)_esFocus, pick.kind);
    [self showOSD:NO autoHide:NO];
    SFAnimate(0.2, ^{ self->_pauseIcon.opacity = 0; });
    [self esRefreshLook];
}

// Back to normal playback keys. finish: run a deferred end (video ended while choosing)
- (void)esLeave:(BOOL)finish {
    if (_esFocus < 0) return;
    _esFocus = -1;
    SFLog(@"endscreen: left the tiles");
    [self esRefreshLook];
    if (finish && _esEndDeferred) { [self esUpdate]; [self finishEnd]; return; }
    [self updatePauseState];   // paused: pause icon + OSD again
    [self esUpdate];
}

// Spatial move: nearest visible tile in that direction (distance along it, plus off-axis offset weighted)
- (BOOL)esMove:(SFKey)key {
    SFEndTile *cur = _esTiles[_esFocus];
    CGPoint c = CGPointMake(CGRectGetMidX(cur.frame), CGRectGetMidY(cur.frame));
    CGFloat cw = cur.frame.size.width, ch = cur.frame.size.height;
    SFEndTile *best = nil; CGFloat bestScore = HUGE_VAL;
    for (SFEndTile *t in [self esVisible]) {
        if (t == cur) continue;
        CGRect f = t.frame;
        CGFloat dx = CGRectGetMidX(f) - c.x, dy = CGRectGetMidY(f) - c.y, along, off;
        switch (key) {
            // the candidate has to lie beyond the current tile in that direction (30 % overlap allowed)
            case SFKeyLeft:  if (CGRectGetMaxX(f) > CGRectGetMinX(cur.frame) + 0.3 * cw) continue; along = -dx; off = fabs(dy); break;
            case SFKeyRight: if (CGRectGetMinX(f) < CGRectGetMaxX(cur.frame) - 0.3 * cw) continue; along = dx; off = fabs(dy); break;
            case SFKeyUp:    if (CGRectGetMaxY(f) > CGRectGetMinY(cur.frame) + 0.3 * ch) continue; along = -dy; off = fabs(dx); break;
            default:         if (CGRectGetMinY(f) < CGRectGetMaxY(cur.frame) - 0.3 * ch) continue; along = dy; off = fabs(dx); break;
        }
        CGFloat score = along + 2 * off;
        if (score < bestScore) { bestScore = score; best = t; }
    }
    if (!best) return NO;
    _esFocus = [_esTiles indexOfObjectIdenticalTo:best];
    SFLog(@"endscreen: focus %ld (%@)", (long)_esFocus, best.kind);
    [self esRefreshLook];
    return YES;
}

- (BOOL)esHandleKey:(SFKey)key {
    if (![self esEngaged]) {
        if (!_esShown || _failed) return NO;
        // DOWN goes into the tiles - but not in the middle of turning the volume down
        if (key == SFKeyDown && !(_lastVolumeAt && -[_lastVolumeAt timeIntervalSinceNow] < 2)) { [self esEnter]; return YES; }
        return NO;
    }
    switch (key) {
        case SFKeyLeft: case SFKeyPrev: [self esMove:SFKeyLeft]; return YES;
        case SFKeyRight: case SFKeyNext: [self esMove:SFKeyRight]; return YES;
        case SFKeyDown: case SFKeyDownHold: [self esMove:SFKeyDown]; return YES;
        case SFKeyUp: case SFKeyUpHold:
            if (![self esMove:SFKeyUp]) [self esLeave:YES];   // above the top row: back to the video
            return YES;
        case SFKeyMenu: [self esLeave:YES]; return YES;
        case SFKeySelect: [self esOpen:_esTiles[_esFocus]]; return YES;
        case SFKeySelectHold:   // info panel as usual - unless the video is already over: then just finish
            if (_esEndDeferred) { [self esLeave:YES]; return YES; }
            [self esLeave:NO];
            return NO;
        default: return NO;                                    // Play/Pause: as usual
    }
}

#pragma mark Open

- (void)esOpen:(SFEndTile *)tile {
    NSDictionary *e = tile.element;
    NSString *st = tile.kind, *title = SFStr(e[@"title"]), *image = SFStr(e[@"image"]), *ref = SFStr(e[@"ref"]);
    SFNavigator *nav = self.navigator;
    Class<SFApp> app = [SFAppRegistry appForRef:ref];
    SFLog(@"endscreen: open %@ %@", st, ref);
    if ([st isEqualToString:SFEndCardVideo]) {   // like autoplay / the info panel's recommendations: play here
        SFItem *it = [app respondsToSelector:@selector(itemForRef:title:image:)] ? [app itemForRef:ref title:title image:image] : nil;
        if (!it) return;
        _esEndDeferred = NO;
        [self playItem:it];
        return;
    }
    if ([st isEqualToString:SFEndCardPlaylist]) { [self esOpenPlaylist:e]; return; }
    // channel page / follow: through the same link rules as the info panel ("Zum Kanal")
    SFItem *ep = [SFItem new];
    ep.kind = SFItemVideo; ep.source = [app appIdentifier]; ep.themeName = ep.source;
    ep.channel = title ?: ([st isEqualToString:SFEndCardFollow] ? _item.channel : nil);
    ep.showRef = ref;
    SFShowLink *link = [SFShowLink linkFor:ep here:nil pageTitle:nil];
    if ([st isEqualToString:SFEndCardFollow]) {
        SFItem *folder = [link.folder copy];
        if (!folder || ![[SFFollows shared] canFollow:folder]) { [nav toast:@"Diesem Kanal kann hier nicht gefolgt werden"]; return; }
        if (image) folder.image = image;
        if (!folder.title.length) folder.title = @"Kanal";
        SFToggleFollow(nav, folder, self.theme, NO);
        [self esUpdate];
        return;
    }
    if (!link) { [nav toast:@"Kanal nicht gefunden"]; return; }
    // leaving the video for a full screen replaces the player (progress saved), as from the info panel
    __weak SFPlayerScreen *ws = self;
    [link openOn:nav stillValid:^BOOL { return ws && nav.top == ws; } present:^(SFScreen *screen) {
        SFPlayerScreen *s = ws;
        if (s && [nav.stack containsObject:s]) { [nav popAbove:s]; [nav replaceTop:screen]; }
        else [nav push:screen];
    }];
}

// Playlist: the linked video starts right away as part of the playlist; the playlist's order is
// adopted as the queue as soon as it has loaded (autoplay then follows the playlist, the info panel
// shows it). Without a linked video the first one plays once the list is there.
- (void)esOpenPlaylist:(NSDictionary *)e {
    NSString *pid = SFStr(e[@"ref"]), *vid = SFStr(e[@"firstRef"]), *title = SFStr(e[@"title"]) ?: @"Playlist";
    Class<SFApp> app = [SFAppRegistry appForRef:pid];
    if (![app respondsToSelector:@selector(listLoader:title:)]) return;
    // until the list is there the video's own title is unknown: the playlist's title stands in
    Class<SFApp> vapp = [SFAppRegistry appForRef:vid];
    SFItem *first = [vapp respondsToSelector:@selector(itemForRef:title:image:)] ? [vapp itemForRef:vid title:title image:nil] : nil;
    if (first) {
        first = [first copy];
        first.playlistID = SFRefID(pid);   // raw list id, as the list loader tags its items (autoplay continues in the list)
        _esEndDeferred = NO;
        [self playItem:first];
    } else {
        [self esLeave:NO];
        [self.navigator toast:[NSString stringWithFormat:@"Playlist „%@“ wird geladen …", title]];
    }
    // the video had ended while the tiles had focus: if the playlist does not come, the end still
    // has to run (up-next card or leaving), not leave the player on the ended video (review 2026-11-05)
    BOOL endWaiting = !first && _ended;
    SFItem *was = _item;
    __weak SFPlayerScreen *ws = self;
    SFPageLoader load = [app listLoader:pid title:title];
    load(^(SFPage *page, NSError *err) {
        SFMain(^{
            SFPlayerScreen *s = ws;
            if (!s || s->_closing || s->_item != was) return;   // moved on meanwhile
            NSArray *items = [(SFShelf *)page.shelves.firstObject items];
            if (!items.count) {
                SFLog(@"endscreen: playlist %@ not loaded (%@)", pid, err.localizedDescription);
                [s.navigator toast:first ? @"Die Playlist ließ sich nicht laden – nur dieses Video wird abgespielt." : @"Die Playlist ließ sich nicht laden."];
                if (endWaiting) [s finishEnd];
                return;
            }
            if (!first) {
                SFLog(@"endscreen: playlist %@ (%lu videos), playing the first", pid, (unsigned long)items.count);
                [s playQueue:items index:0];
                return;
            }
            NSUInteger at = NSNotFound;
            for (NSUInteger k = 0; k < items.count; k++) if ([[items[k] identifier] isEqualToString:first.identifier]) { at = k; break; }
            if (at == NSNotFound) { SFLog(@"endscreen: playlist %@ does not contain %@", pid, vid); return; }
            NSMutableArray *q = [items mutableCopy];
            SFItem *li = items[at], *run = s->_item;
            if (!run.localPath) {   // the list knows the real title, channel and length
                run.title = li.title; run.channel = li.channel; run.showRef = run.showRef ?: li.showRef;
                if (li.duration > 0 && run.duration <= 0) run.duration = li.duration;
                [s updateTitles];
            }
            q[at] = run;   // the running item keeps its identity (autoplay finds its position)
            s->_queue = q; s->_index = at; s->_explicitQueue = NO;
            SFLog(@"endscreen: playlist %@ adopted (%lu videos, at %lu)", pid, (unsigned long)q.count, (unsigned long)at);
        });
    });
}

// Play a new list in this player (not the phone's explicit queue: autoplay follows the playlist)
- (void)playQueue:(NSArray *)items index:(NSUInteger)i {
    if (i >= items.count) return;
    _queue = [items copy];
    _explicitQueue = NO;
    _index = i;
    [self playItem:items[i]];
}

@end
