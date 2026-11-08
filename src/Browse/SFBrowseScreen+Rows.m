// SFBrowseScreen - rows: building them from the page, keeping unchanged ones, their tiles and
// which of them exist as layers.
#import "SFBrowseScreen+Private.h"

@implementation SFBrowseScreen (Rows)

#pragma mark Rows

// What a row looks like: rows of a rebuilt page with the same key keep their layers and tiles.
static NSString *SFRowKey(SFRow *r) {
    NSMutableString *k = [NSMutableString stringWithFormat:@"%@|%d|%d|%lu", r.title ?: @"", (int)r.style, r.rail, (unsigned long)r.firstIndex];
    for (SFItem *i in r.items)
        [k appendFormat:@"|%@~%@~%@~%@~%@~%d~%.0f", i.identifier ?: @"", i.title ?: @"", i.subtitle ?: @"", i.badge ?: @"",
                        i.image ?: @"", i.tint != nil, i.duration];
    return k;
}

// A page rebuilt with new data (details, recommendations or episodes arriving, a download done)
// keeps what did not change: unchanged rows keep their layers and tiles, the hero stays. Tearing
// everything down blinked the whole page at every update - the player's info panel builds up in
// three steps (user 2026-11-07).
- (void)buildRows {
    NSMutableDictionary *keep = [NSMutableDictionary new];   // key -> materialized row of the old page
    for (SFRow *r in _rows) if (r.layer) keep[SFRowKey(r)] = r;
    CGSize size = self.size;
    BOOL heroFits = _hero && self.showsHero && _hero.bounds.size.width == size.width;
    SFNoAnimate(^{
        [self->_rows removeAllObjects];
        [self->_empty removeFromSuperlayer]; self->_empty = nil;
        if (!heroFits) { [self->_hero removeFromSuperlayer]; self->_hero = nil; }
    });
    SFTheme *t = self.theme;
    CGFloat left = U(96), avail = size.width - 2 * left;
    CGFloat y = U(150);
    if (self.showsHero) {
        if (!_hero) [self buildHero:size];
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
    NSUInteger reused = 0;
    NSMutableSet *kept = [NSMutableSet new];
    for (SFRow *r in _rows) {
        NSString *key = SFRowKey(r);
        SFRow *old = keep[key];
        if (!old) continue;
        [keep removeObjectForKey:key];
        reused++; [kept addObject:r];
        r.layer = old.layer; r.strip = old.strip; r.tiles = old.tiles;
        r.focusCol = old.focusCol; r.scrollCol = old.scrollCol;
        SFNoAnimate(^{ r.layer.position = CGPointMake(0, r.y); });
    }
    BOOL rebuilt = reused + keep.count > 0;   // an earlier page had built rows
    SFNoAnimate(^{ for (SFRow *gone in keep.allValues) [gone.layer removeFromSuperlayer]; });
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
    if (rebuilt) {   // the rows built anew (layers and tiles); rows off screen get none yet
        NSMutableArray *fresh = [NSMutableArray new];
        for (SFRow *r in _rows) if (r.layer && ![kept containsObject:r]) [fresh addObject:[NSString stringWithFormat:@"%@#%lu", r.title ?: @"-", (unsigned long)r.firstIndex]];
        SFLog(@"rows: rebuilt %@ - %lu kept, %lu new (%@)", _page.title ?: @"(Start)", (unsigned long)reused, (unsigned long)fresh.count, [fresh componentsJoinedByString:@", "]);
    }
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

// Rows within half a screen of the visible area exist as layers. A row on screen is built at
// once; one off screen waits until the motion has stopped: built in the same transaction as the
// scroll, its tiles' pictures arrived mid-animation as new textures - first visits to rows ran
// at 29-41 fps (frame meter 2026-11-07).
static const NSTimeInterval kBuildAheadDelay = 0.4;   // > the row animation (0.34 s)
// A shelf with more to load: once the focus is within six tiles of a rail's end or two lines of a
// grid's, its next portion - appended at the end, the page rebuilt keeping the focus (rows that did
// not change keep their layers: nothing shown moves).
- (void)loadMoreNear:(SFRow *)r col:(NSInteger)col {
    SFShelf *sh = r.shelf < _page.shelves.count ? _page.shelves[r.shelf] : nil;
    if (!sh.moreLoader || [_loadingMore containsObject:sh]) return;
    NSUInteger ahead = r.rail ? 6 : 2 * MAX((NSUInteger)1, r.items.count);
    if (r.firstIndex + col + ahead < sh.items.count) return;
    if (!_loadingMore) _loadingMore = [NSMutableSet new];
    [_loadingMore addObject:sh];
    SFPage *page = _page;
    __weak SFBrowseScreen *ws = self;
    sh.moreLoader(^(NSArray *items, BOOL more) {
        dispatch_async(dispatch_get_main_queue(), ^{   // never inside the focus change that asked
            if (!more) sh.moreLoader = nil;
            SFBrowseScreen *s = ws;
            if (!s) return;
            [s->_loadingMore removeObject:sh];
            if (s->_page != page) return;   // reloaded meanwhile: the new page has its own shelves
            NSMutableSet *have = [NSMutableSet new];
            for (SFItem *i in sh.items) if (i.identifier) [have addObject:i.identifier];
            NSMutableArray *add = [NSMutableArray new];
            for (SFItem *i in items) if (!i.identifier || ![have containsObject:i.identifier]) [add addObject:i];
            SFLog(@"rows: %@ +%lu%@", sh.title ?: @"-", (unsigned long)add.count, more ? @"" : @" (complete)");
            if (!add.count) return;
            sh.items = [sh.items arrayByAddingObjectsFromArray:add];
            [s setPage:page keepFocus:YES];
        });
    });
}

- (void)updateVisibleRows { [self updateVisibleRowsAhead:NO]; }
- (void)buildRowsAhead { [self updateVisibleRowsAhead:YES]; }

- (void)updateVisibleRowsAhead:(BOOL)ahead {
    CGFloat h = self.size.height, top = _scrollY - h * 0.5, bottom = _scrollY + h * 1.5;
    BOOL deferred = NO;
    for (SFRow *r in _rows) {
        BOOL vis = r.y + r.height >= top && r.y <= bottom;
        BOOL onScreen = r.y + r.height >= _scrollY && r.y <= _scrollY + h;
        if (vis && !r.layer) {
            if (onScreen || ahead) [self materializeRow:r]; else deferred = YES;
        } else if (!vis && r.layer) {
            SFNoAnimate(^{ [r.layer removeFromSuperlayer]; });
            r.layer = nil; r.strip = nil; r.tiles = nil;
        }
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(buildRowsAhead) object:nil];
    if (deferred) [self performSelector:@selector(buildRowsAhead) withObject:nil afterDelay:kBuildAheadDelay];
}
@end
