#import "SFBrowseScreen.h"
#import "SFTile.h"
#import "SFLayers.h"
#import "SFStore.h"
#import "SFMenuScreen.h"
#import "SFDownloads.h"
#import "SFNet.h"
#import "SFFollows.h"
#import "SFLibrary.h"
#import "SFPlayerScreen.h"
#import "SFLogo.h"
#import "SFSearch.h"
#import "SFWatchLater.h"

#import "SFBrowseScreen+Private.h"
#import "SFApp.h"

@implementation SFRow @end

@implementation SFBrowseScreen

- (instancetype)initWithLoader:(SFPageLoader)loader theme:(SFTheme *)theme {
    if ((self = [super initWithTheme:theme])) {
        _loader = [loader copy];
        _rows = [NSMutableArray new];
        [self observeDownloads];
    }
    return self;
}
// keep the download status on the tiles live
- (void)observeDownloads {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadChanged:) name:SFDownloadsDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onlineChanged) name:SFNetOnlineDidChangeNotification object:nil];
    for (NSString *n in [SFAppRegistry remoteStatusNotifications])
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updatePhoneStatus) name:n object:nil];
}
- (SFPage *)page { return _page; }
- (BOOL)isOpaque { return !self.overlay; }

- (void)setReloadNotification:(NSString *)name {
    if (_reloadNotification) [[NSNotificationCenter defaultCenter] removeObserver:self name:_reloadNotification object:nil];
    _reloadNotification = [name copy];
    if (name) [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSoon) name:name object:nil];
}
- (void)addReloadNotification:(NSString *)name {
    if (name) [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSoon) name:name object:nil];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

#pragma mark Layout

- (void)layoutForSize:(CGSize)size {
    CALayer *L = self.layer;
    SFTheme *t = self.theme;
    SFNoAnimate(^{
        [self->_bg removeFromSuperlayer];
        if (self.overlay) {   // the video below stays visible, dimmed enough for text on a TV
            self->_bg = SFGradientBackground([NSColor colorWithDeviceWhite:0 alpha:0.72], [NSColor colorWithDeviceWhite:0 alpha:0.92], L.bounds);
            L.backgroundColor = NULL;
        } else {
            self->_bg = SFGradientBackground(t.backgroundTop, t.background, L.bounds);
            L.backgroundColor = t.background.CGColor;
        }
        self->_bg.zPosition = -10;
        [L addSublayer:self->_bg];

        if (!self->_backdrop) {
            // image + gradients in one container whose opacity animates as a whole
            self->_backdropBox = [CALayer layer];
            self->_backdropBox.zPosition = -5;
            self->_backdropBox.opacity = 0;
            self->_backdrop = [SFImageLayer layer];
            self->_backdropFade = [CAGradientLayer layer];
            self->_backdropFadeBottom = [CAGradientLayer layer];
            [self->_backdropBox addSublayer:self->_backdrop];
            [self->_backdropBox addSublayer:self->_backdropFade];
            [self->_backdropBox addSublayer:self->_backdropFadeBottom];
            [L addSublayer:self->_backdropBox];
        }
        // background image top right, faded out to the left and bottom
        CGFloat bw = size.width * 0.62, bh = bw * 9 / 16;
        self->_backdropBox.frame = CGRectMake(size.width - bw, 0, bw, bh);
        self->_backdrop.frame = self->_backdropBox.bounds;
        self->_backdropFade.hidden = YES; self->_backdropFadeBottom.hidden = YES;
        self->_backdrop.fadeEdges = YES;
        self->_backdrop.alwaysFadesIn = YES;
        self->_backdrop.placeholderColor = nil;
        [self buildHeader:size];
        if (!self->_content) {
            self->_content = [CALayer layer];
            self->_content.anchorPoint = CGPointZero;
            [L addSublayer:self->_content];
        }
        self->_content.frame = CGRectMake(0, 0, size.width, size.height);
    });
    _laidOut = YES;
    if (_page) {
        BOOL hdr = _headerFocus;
        [self buildRows];
        if (hdr && _searchPill) [self focusHeaderSearch];
    }
}

- (void)schedulePrefetch {
    [_prefetchTimer invalidate];
    _prefetchTimer = [NSTimer scheduledTimerWithTimeInterval:1.2 target:self selector:@selector(prefetchFocused) userInfo:nil repeats:NO];
}
- (void)prefetchFocused {
    _prefetchTimer = nil;
    SFItem *it = [self focusedItem];
    if (it.kind != SFItemVideo || [[SFDownloads shared] fileFor:it.identifier] || ![SFNet isOnline]) return;
    // only when the focus moved to another video: rebuilds after a follow check restore the same
    // focus (2026-11-06: one video preloaded 184 times a day, also with the screen asleep)
    if ([it.identifier isEqualToString:_prefetchedID]) return;
    _prefetchedID = it.identifier;
    Class<SFApp> app = [SFAppRegistry appForItem:it];
    if ([app respondsToSelector:@selector(preloadOnFocus:)]) [app preloadOnFocus:it];
}

#pragma mark Lifecycle

- (void)willAppear {
    [self updateClock];
    [_clockTimer invalidate];   // after an overlay (menu) willAppear arrives without a preceding willDisappear
    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(updateClock) userInfo:nil repeats:YES];
    if (!_page && !_loading) [self reload];
    else {
        for (SFRow *r in _rows) for (SFTileLayer *tl in r.tiles.allValues) [tl refreshProgress];
    }
}
- (void)willDisappear { [_clockTimer invalidate]; _clockTimer = nil; [_prefetchTimer invalidate]; _prefetchTimer = nil; }
- (void)didAppear {}

// Notification-driven reloads coalesce: deleting 200 downloads posts 200 notifications, the page
// loads once (review 2026-11-05: each reload ran the whole loader on the main thread).
- (void)reloadSoon {
    if (_reloadPending) return;
    _reloadPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ self->_reloadPending = NO; [self reload]; });
}

- (void)onlineChanged {
    [self updateHint];
    if (_loadFailed && [SFNet isOnline]) [self reload];   // the page that failed offline loads itself
}

// What a failed load tells the viewer: the source's own (German) message, a connection problem in
// plain words - never a raw NSURLError/curl text - and what to do.
static NSString *LoadErrorText(NSError *err) {
    NSString *m = err.localizedDescription;
    BOOL technical = !m.length || [err.domain isEqualToString:NSURLErrorDomain] || [m rangeOfString:@"curl" options:NSCaseInsensitiveSearch].location != NSNotFound;
    NSString *what = technical ? @"Der Inhalt konnte gerade nicht geladen werden." : m;
    return [what stringByAppendingString:@"\n\nOK – erneut versuchen"];
}

- (void)reload {
    if (!self.loader) return;
    _loading = YES;
    NSUInteger seq = ++_reloadSeq;
    if (!_page || _loadFailed) [self showSpinner:YES];
    __weak SFBrowseScreen *ws = self;
    self.loader(^(SFPage *page, NSError *err) {
        SFMain(^{
            SFBrowseScreen *s = ws; if (!s || seq != s->_reloadSeq) return;   // a newer reload owns the page
            s->_loading = NO;
            [s showSpinner:NO];
            if (!page) {
                // a refresh of a page with content keeps what it shows (a download finishing reloads
                // channel pages; a timeout there must not wipe the rows)
                if (s->_page.shelves.count && !s->_loadFailed) { SFLog(@"browse: refresh of %@ failed (%@) - keeping the page", s->_page.title ?: @"page", err.localizedDescription ?: @"?"); return; }
                SFPage *p = [SFPage page:s->_page.title theme:s.theme.identifier shelves:@[]];
                p.emptyText = LoadErrorText(err);
                s->_loadFailed = YES;
                [s setPage:p keepFocus:NO];
                return;
            }
            BOOL keep = s->_page != nil && !s->_loadFailed;
            s->_loadFailed = NO;
            [s setPage:page keepFocus:keep];
        });
    });
}

// Dev audit: log tiles without an image (find large empty areas)
static void auditImages(SFPage *page) {
    if (!SFDevMode) return;
    for (SFShelf *sh in page.shelves) {
        NSMutableArray *miss = [NSMutableArray new];
        for (SFItem *i in sh.items) if (!i.image.length && !i.logo.length && i.style != SFTileStyleApp && i.style != SFTileStyleButton) [miss addObject:[NSString stringWithFormat:@"%@<%@>", i.title ?: @"?", i.identifier ?: @""]];
        if (miss.count) SFLog(@"noimg: [%@] %@ / %@: %@", page.themeName, page.title ?: @"(Start)", sh.title ?: @"-", [miss componentsJoinedByString:@", "]);
    }
}

- (void)setPage:(SFPage *)page keepFocus:(BOOL)keep {
    auditImages(page);
    // remember the focus (by shelf title + item ID)
    NSString *fShelf = nil, *fItem = nil;
    NSInteger fRow = -1, fIdx = 0;
    if (keep && _row < (NSInteger)_rows.count) {
        SFRow *r = _rows[_row];
        fRow = _row; fIdx = r.firstIndex + r.focusCol;   // index in the shelf (grid: across rows)
        fShelf = r.title ?: [self shelfTitleForRow:r];
        SFItem *it = [self focusedItem];
        fItem = it.identifier ?: it.title;
    }
    BOOL hdr = keep && _headerFocus;   // focus on "Suche" survives a reload (e.g. download finished)
    SFRow *fr = _row < (NSInteger)_rows.count ? _rows[_row] : nil;
    SFTileLayer *prevTile = fr.tiles[@(fr.focusCol)];   // its row may live on (buildRows keeps unchanged rows)
    _page = page;
    if (!_laidOut) return;
    _pageTitle.text = page.subtitle.length ? [NSString stringWithFormat:@"%@  ·  %@", page.title ?: @"", page.subtitle] : page.title;
    [self buildRows];
    BOOL found = NO;
    if (fShelf) {
        for (NSUInteger i = 0; i < _rows.count && !found; i++) {
            SFRow *r = _rows[i];
            if (![[self shelfTitleForRow:r] isEqualToString:fShelf]) continue;
            for (NSUInteger c = 0; c < r.items.count; c++) {
                SFItem *it = r.items[c];
                if ([(it.identifier ?: it.title) isEqualToString:fItem]) {
                    [self focusRow:i col:c animated:NO];
                    found = YES;
                    break;
                }
            }
        }
    }
    // Focused element gone (e.g. removed from "Später ansehen"): stay in the same row at the same
    // position (= the next element); if the row is gone entirely, the row that moved up.
    if (!found && fRow >= 0 && _rows.count) {
        NSInteger target = -1, col = 0;
        for (NSUInteger i = 0; i < _rows.count && fShelf; i++) {   // grid row that now contains the old index (else the shelf's last one)
            SFRow *r = _rows[i];
            if (![[self shelfTitleForRow:r] isEqualToString:fShelf]) continue;
            target = i; col = fIdx - (NSInteger)r.firstIndex;
            if (fIdx < (NSInteger)(r.firstIndex + r.items.count)) break;
        }
        if (target < 0) {   // shelf gone entirely: the row that moved up, at its own position
            target = MIN(fRow, (NSInteger)_rows.count - 1);
            col = [_rows[target] focusCol];
        }
        [self focusRow:target col:MAX(0, col) animated:NO];   // focusRow clamps the column itself
    }
    if (hdr && _searchPill) [self focusHeaderSearch];
    SFRow *nr = !_headerFocus && _row < (NSInteger)_rows.count ? _rows[_row] : nil;
    if (prevTile && prevTile != nr.tiles[@(nr.focusCol)]) prevTile.focused = NO;   // the focus moved on: a kept tile lets go
}

- (void)replaceItemsOfShelf:(SFShelf *)shelf with:(NSArray *)items {
    NSUInteger si = [_page.shelves indexOfObjectIdenticalTo:shelf];
    if (si == NSNotFound) return;
    SFRow *row = nil;
    for (SFRow *r in _rows) if (r.shelf == si) { row = r; break; }
    BOOL inPlace = row && row.rail && shelf.layout == SFShelfRail && items.count == shelf.items.count && items.count > 0;
    shelf.items = items;
    if (!inPlace || !_laidOut) { if (_laidOut) [self setPage:_page keepFocus:YES]; return; }
    row.items = items;
    if (row.widths) {
        NSMutableArray *ws = [NSMutableArray new];
        for (SFItem *it in items) [ws addObject:@(SFButtonTileWidth(it, self.theme, self.overlay ? U(250) : 0))];
        row.widths = ws;
    }
    BOOL focusedHere = !_headerFocus && _row < (NSInteger)_rows.count && _rows[_row] == row;
    if (row.layer) {
        SFNoAnimate(^{ for (CALayer *l in row.tiles.allValues) [l removeFromSuperlayer]; });
        [row.tiles removeAllObjects];
        if (row.widths) row.scrollCol = [self scrollColForRow:row col:row.focusCol];
        SFNoAnimate(^{ row.strip.position = CGPointMake(-[self scrollOffsetForRow:row col:row.scrollCol], row.titleHeight); });
        [self updateTilesInRow:row];
    }
    if (focusedHere) {
        SFTileLayer *tl = row.tiles[@(row.focusCol)];
        tl.focused = YES;
        [self updateHint];
        if (self.showsHero) [self updateHeroFor:[self focusedItem]];
    }
}

- (NSString *)shelfTitleForRow:(SFRow *)r {
    return r.shelf < _page.shelves.count ? [_page.shelves[r.shelf] title] : nil;
}

- (void)showSpinner:(BOOL)on {
    if (on && !_spinner) {
        _spinner = [CALayer layer];
        CAShapeLayer *arc = [CAShapeLayer layer];
        CGFloat r = U(34);
        arc.frame = CGRectMake(0, 0, 2 * r, 2 * r);
        CGPathRef ep = CGPathCreateWithEllipseInRect(CGRectInset(arc.bounds, U(4), U(4)), NULL);
        arc.path = ep;
        CGPathRelease(ep);
        arc.fillColor = nil;
        arc.strokeColor = self.theme.accent.CGColor;
        arc.lineWidth = U(6);
        arc.lineCap = kCALineCapRound;
        arc.strokeEnd = 0.7;
        _spinner.bounds = arc.frame;
        [_spinner addSublayer:arc];
        _spinner.position = CGPointMake(self.size.width / 2, self.size.height / 2);
        CABasicAnimation *rot = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rot.fromValue = @0; rot.toValue = @(2 * M_PI); rot.duration = 0.9; rot.repeatCount = HUGE_VALF;
        [_spinner addAnimation:rot forKey:@"spin"];
        [self.layer addSublayer:_spinner];
    } else if (!on && _spinner) {
        [_spinner removeFromSuperlayer];
        _spinner = nil;
    }
}

#pragma mark Focus (moving it: +Focus)

- (SFItem *)focusedItem {
    if (_row >= (NSInteger)_rows.count) return nil;
    SFRow *r = _rows[_row];
    return r.focusCol < (NSInteger)r.items.count ? r.items[r.focusCol] : nil;
}
@end
