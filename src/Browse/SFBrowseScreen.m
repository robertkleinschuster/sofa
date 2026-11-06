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
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshTiles) name:SFDownloadsDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateHint) name:SFNetOnlineDidChangeNotification object:nil];
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

- (void)reload {
    if (!self.loader) return;
    _loading = YES;
    if (!_page) [self showSpinner:YES];
    __weak SFBrowseScreen *ws = self;
    self.loader(^(SFPage *page, NSError *err) {
        SFMain(^{
            SFBrowseScreen *s = ws; if (!s) return;
            s->_loading = NO;
            [s showSpinner:NO];
            if (!page) {
                SFPage *p = [SFPage page:s->_page.title theme:s.theme.identifier shelves:@[]];
                p.emptyText = err.localizedDescription ?: @"Inhalt konnte nicht geladen werden.";
                [s setPage:p keepFocus:NO];
                return;
            }
            [s setPage:page keepFocus:s->_page != nil];
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

#pragma mark Rows

- (void)buildRows {
    SFNoAnimate(^{
        for (SFRow *r in self->_rows) [r.layer removeFromSuperlayer];
        [self->_rows removeAllObjects];
        [self->_empty removeFromSuperlayer]; self->_empty = nil;
        [self->_hero removeFromSuperlayer]; self->_hero = nil;
    });
    CGSize size = self.size;
    SFTheme *t = self.theme;
    CGFloat left = U(96), avail = size.width - 2 * left;
    CGFloat y = U(150);
    if (self.showsHero) {
        [self buildHero:size];
        y = self.overlay ? U(590) : U(560);   // overlay: no logo row -> room for more description
    }
    _contentTop = y;
    NSUInteger si = 0;
    for (SFShelf *sh in _page.shelves) {
        if (!sh.items.count) { si++; continue; }
        SFTileMetrics m = SFMetricsForStyle(sh.style);
        CGFloat tileH = U(m.imageHeight) + (m.textHeight ? U(14) + U(m.textHeight) : 0);
        CGFloat titleH = sh.title.length ? U(58) : 0;
        if (sh.layout == SFShelfRail) {
            SFRow *r = [SFRow new];
            r.shelf = si; r.items = sh.items; r.style = sh.style; r.rail = YES;
            r.title = sh.title; r.titleHeight = titleH;
            r.y = y; r.height = titleH + tileH;
            if (sh.style == SFTileStyleButton) {   // pills sized to their label (long channel names, track names); overlay: compact, the whole action row fits
                NSMutableArray *ws = [NSMutableArray new];
                for (SFItem *it in sh.items) [ws addObject:@(SFButtonTileWidth(it, t, self.overlay ? U(250) : 0))];
                r.widths = ws;
            }
            if (sh.focusIndex > 0 && sh.focusIndex < sh.items.count) {
                r.focusCol = sh.focusIndex;
                r.scrollCol = [self scrollColForRow:r col:r.focusCol];
            }
            [_rows addObject:r];
            y += r.height + U(64);
        } else {
            CGFloat step = U(m.width) + U(m.gap);
            NSUInteger per = MAX(1, (NSUInteger)floor((avail + U(m.gap)) / step));
            for (NSUInteger i = 0; i < sh.items.count; i += per) {
                SFRow *r = [SFRow new];
                r.shelf = si; r.style = sh.style; r.rail = NO;
                r.items = [sh.items subarrayWithRange:NSMakeRange(i, MIN(per, sh.items.count - i))];
                r.firstIndex = i;
                r.title = i == 0 ? sh.title : nil;
                r.titleHeight = i == 0 ? titleH : 0;
                r.y = y; r.height = r.titleHeight + tileH;
                [_rows addObject:r];
                y += r.height + U(58);   // room for the downward-moving titles of the enlarged focus tile
            }
            y += U(12);
        }
        si++;
    }
    if (!_rows.count) {
        _empty = [SFLabel labelWithFont:[t regular:32] color:t.textDim];
        _empty.text = _page.emptyText ?: @"Hier gibt es noch nichts.";
        _empty.alignment = NSCenterTextAlignment;
        _empty.maxLines = 3;
        CGFloat h = [_empty sizeToFitWidth:U(1200)];
        _empty.position = CGPointMake((size.width - U(1200)) / 2, (size.height - h) / 2);
        [self.layer addSublayer:_empty];
        if (self.showsHero) [self updateHeroFor:nil];
        return;
    }
    _row = 0;
    _scrollY = 0;
    SFNoAnimate(^{ self->_content.position = CGPointZero; });
    [self updateVisibleRows];
    NSUInteger start = 0;   // start focus of the page (season choice stays reachable via Up)
    for (NSUInteger i = 0; i < _rows.count && _page.focusShelf; i++) if ([_rows[i] shelf] == _page.focusShelf) { start = i; break; }
    _pinTop = start > 0;
    [self focusRow:start col:0 animated:NO];
    _pinTop = NO;
}

- (void)materializeRow:(SFRow *)r {
    if (r.layer) return;
    SFTheme *t = self.theme;
    CALayer *rl = [CALayer layer];
    rl.anchorPoint = CGPointZero;
    rl.frame = CGRectMake(0, r.y, self.size.width, r.height);
    if (r.title.length) {
        SFLabel *tl = [SFLabel labelWithFont:[t bold:31] color:t.text];
        tl.text = t.uppercaseHeaders ? r.title.uppercaseString : r.title;
        [tl sizeToFitWidth:self.size.width - U(192)];
        tl.position = CGPointMake(U(96), 0);
        [rl addSublayer:tl];
    }
    CALayer *strip = [CALayer layer];
    strip.anchorPoint = CGPointZero;
    strip.frame = CGRectMake(0, r.titleHeight, self.size.width, r.height - r.titleHeight);
    [rl addSublayer:strip];
    if (r.rail && r.scrollCol > 0) strip.position = CGPointMake(-[self scrollOffsetForRow:r col:r.scrollCol], r.titleHeight);
    r.layer = rl; r.strip = strip;
    r.tiles = [NSMutableDictionary new];
    SFNoAnimate(^{ [self->_content addSublayer:rl]; });
    [self updateTilesInRow:r];
}

- (CGFloat)xForCol:(NSInteger)c inRow:(SFRow *)r {
    SFTileMetrics m = SFMetricsForStyle(r.style);
    if (r.widths) {
        CGFloat x = U(96);
        for (NSInteger k = 0; k < c && k < (NSInteger)r.widths.count; k++) x += [r.widths[k] doubleValue] + U(m.gap);
        return x;
    }
    return U(96) + c * (U(m.width) + U(m.gap));
}
- (CGFloat)widthForCol:(NSInteger)c inRow:(SFRow *)r {
    if (r.widths && c >= 0 && c < (NSInteger)r.widths.count) return [r.widths[c] doubleValue];
    return U(SFMetricsForStyle(r.style).width);
}
// Horizontal shift of a rail's strip when column sc is the first visible one
- (CGFloat)scrollOffsetForRow:(SFRow *)r col:(NSInteger)sc { return [self xForCol:sc inRow:r] - U(96); }

// First visible column so that col is visible: focus stays in column 1 while possible (one tile of
// context to the left), the row never scrolls past its end.
- (NSInteger)scrollColForRow:(SFRow *)r col:(NSInteger)col {
    NSInteger n = (NSInteger)r.items.count;
    CGFloat avail = self.size.width - U(192);
    if (r.widths) {   // variable widths: smallest shift that shows col fully, at most to the row's end
        CGFloat total = [self xForCol:n - 1 inRow:r] + [self widthForCol:n - 1 inRow:r] - U(96);
        if (total <= avail) return 0;
        NSInteger sc = MIN(r.scrollCol, MAX(0, col - 1));
        while (sc < col && [self xForCol:col inRow:r] + [self widthForCol:col inRow:r] - [self xForCol:sc inRow:r] > avail) sc++;
        return sc;
    }
    SFTileMetrics m = SFMetricsForStyle(r.style);
    CGFloat step = U(m.width) + U(m.gap);
    NSInteger fit = MAX(1, (NSInteger)floor((avail + U(m.gap)) / step));
    NSInteger maxScroll = MAX(0, n - fit);
    NSInteger sc = MIN(maxScroll, MAX(0, col - 1));
    if (col >= r.scrollCol + 1 && col < r.scrollCol + fit - 1 && r.scrollCol <= maxScroll) sc = r.scrollCol;
    if (col < r.scrollCol + 1) sc = MAX(0, col - 1);
    if (col > r.scrollCol + fit - 2) sc = MIN(maxScroll, col - fit + 2);
    return sc;
}

- (void)updateTilesInRow:(SFRow *)r {
    if (!r.layer) return;
    SFTileMetrics m = SFMetricsForStyle(r.style);
    CGFloat step = U(m.width) + U(m.gap);
    NSInteger visible = (NSInteger)ceil(self.size.width / step) + 1;
    NSInteger from = MAX(0, r.scrollCol - 2), to = MIN((NSInteger)r.items.count - 1, r.scrollCol + visible + 2);
    if (r.widths) { from = 0; to = (NSInteger)r.items.count - 1; }   // button rows are short
    // remove outside
    for (NSNumber *k in r.tiles.allKeys) {
        NSInteger c = k.integerValue;
        if (c < from - 4 || c > to + 4) {
            SFNoAnimate(^{ [r.tiles[k] removeFromSuperlayer]; });
            [r.tiles removeObjectForKey:k];
        }
    }
    for (NSInteger c = from; c <= to; c++) {
        if (r.tiles[@(c)]) continue;
        SFTileLayer *tl = [[SFTileLayer alloc] initWithItem:r.items[c] style:r.style theme:self.theme width:r.widths ? [self widthForCol:c inRow:r] : 0];
        SFNoAnimate(^{
            tl.position = CGPointMake([self xForCol:c inRow:r] + tl.bounds.size.width / 2, 0);
            [r.strip addSublayer:tl];
        });
        [tl loadImage];
        r.tiles[@(c)] = tl;
    }
}

- (void)updateVisibleRows {
    CGFloat top = _scrollY - self.size.height * 0.5, bottom = _scrollY + self.size.height * 1.5;
    for (SFRow *r in _rows) {
        BOOL vis = r.y + r.height >= top && r.y <= bottom;
        if (vis && !r.layer) [self materializeRow:r];
        else if (!vis && r.layer) {
            SFNoAnimate(^{ [r.layer removeFromSuperlayer]; });
            r.layer = nil; r.strip = nil; r.tiles = nil;
        }
    }
}

#pragma mark Focus (moving it: +Focus)

- (SFItem *)focusedItem {
    if (_row >= (NSInteger)_rows.count) return nil;
    SFRow *r = _rows[_row];
    return r.focusCol < (NSInteger)r.items.count ? r.items[r.focusCol] : nil;
}
@end
