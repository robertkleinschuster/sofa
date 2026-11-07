// SFBrowseScreen - focus and keys: moving between tiles, rows and the header.
#import "SFBrowseScreen+Private.h"
#import "SFFrameMeter.h"

@implementation SFBrowseScreen (Focus)

#pragma mark Focus

- (void)focusRow:(NSInteger)row col:(NSInteger)col animated:(BOOL)anim {
    if (row < 0 || row >= (NSInteger)_rows.count) return;
    if (_headerFocus) { _headerFocus = NO; [self updateSearchPill:anim]; }
    SFRow *old = _row < (NSInteger)_rows.count ? _rows[_row] : nil;
    SFTileLayer *ot = old.tiles[@(old.focusCol)];
    ot.focused = NO;

    SFRow *r = _rows[row];
    col = MAX(0, MIN(col, (NSInteger)r.items.count - 1));
    _row = row;
    r.focusCol = col;
    [self updateHint];
    [self schedulePrefetch];

    // vertical: focused row at the top edge of the content area
    CGFloat target = MAX(0, r.y - _contentTop);
    if (row == 0) target = 0;
    if (_pinTop && r.y + r.height <= self.size.height - U(40)) target = 0;   // row above (e.g. seasons) stays visible
    _scrollY = target;
    [self updateVisibleRows];

    // horizontal (rail): focus stays in column 1 while possible
    if (r.rail) {
        NSInteger sc = [self scrollColForRow:r col:col];
        r.scrollCol = sc;
        [self updateTilesInRow:r];
        CGFloat dx = -[self scrollOffsetForRow:r col:sc];
        void (^move)(void) = ^{ r.strip.position = CGPointMake(dx, r.titleHeight); };
        if (anim && old == r && r.strip.position.x != dx) SFFrameMeterMeasure(@"col", 0.3);   // the rail scrolls
        if (anim) SFAnimate(0.3, move); else SFNoAnimate(move);
    }
    // hide rows above the content area (they do not run under header/hero)
    CGFloat limit = self->_contentTop - U(20);
    void (^vmove)(void) = ^{
        self->_content.position = CGPointMake(0, -self->_scrollY);
        for (SFRow *x in self->_rows) {
            if (!x.layer) continue;
            x.layer.opacity = (x.y - self->_scrollY < limit) ? 0 : 1;
        }
    };
    if (anim && old != r) SFFrameMeterMeasure(@"row", 0.34);
    if (anim) SFAnimate(0.34, vmove); else SFNoAnimate(vmove);

    SFTileLayer *nt = r.tiles[@(col)];
    nt.focused = YES;
    if (self.showsHero) [self updateHeroFor:[self focusedItem]];
    else [self updateBackdropFor:[self focusedItem]];
}

- (void)updateSearchPill:(BOOL)anim {
    if (!_searchPill) return;
    SFTheme *t = self.theme;
    BOOL f = _headerFocus;
    void (^ch)(void) = ^{
        self->_searchPill.backgroundColor = f ? t.text.CGColor : [t.text colorWithAlphaComponent:0.08].CGColor;
        self->_searchPill.borderColor = f ? t.text.CGColor : [t.text colorWithAlphaComponent:0.35].CGColor;
        NSColor *fg = f ? (t.backgroundTop ?: t.background) : t.text;
        self->_searchIcon.strokeColor = fg.CGColor;
        self->_searchLabel.color = fg;
        self->_searchPill.transform = f ? CATransform3DMakeScale(1.08, 1.08, 1) : CATransform3DIdentity;
    };
    if (anim) SFAnimate(0.16, ch); else SFNoAnimate(ch);
}

- (void)focusHeaderSearch {
    SFRow *r = _row < (NSInteger)_rows.count ? _rows[_row] : nil;
    SFTileLayer *ot = r.tiles[@(r.focusCol)];
    ot.focused = NO;
    _headerFocus = YES;
    [self updateSearchPill:YES];
    [self updateHint];
    if (self.showsHero) [self updateHeroFor:SFSearchTile(self.searchSource)];
}

- (BOOL)handleKey:(SFKey)key {
    // header focus first: even an empty page (e.g. offline) stays usable via "Suche"
    if (_headerFocus) {
        switch (key) {
            case SFKeyDown: case SFKeyDownHold:
                if (!_rows.count || _row >= (NSInteger)_rows.count) return YES;
                _headerFocus = NO;
                [self updateSearchPill:YES];
                [self focusRow:_row col:[_rows[_row] focusCol] animated:YES];
                return YES;
            case SFKeySelect: case SFKeyPlayPause:
                SFOpenSearch(self.navigator, self.searchSource, nil);
                return YES;
            case SFKeyMenu: case SFKeyMenuHold:
                return NO;
            default: {   // bump (around the focused size 1.08, without snapping back)
                CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
                a.values = @[@1.08, @1.14, @1.08]; a.duration = 0.2;
                [_searchPill addAnimation:a forKey:@"bump"];
                return YES;
            }
        }
    }
    if (!_rows.count) {
        if ((key == SFKeyUp || key == SFKeyUpHold) && _searchPill) { [self focusHeaderSearch]; return YES; }
        if (_loadFailed && (key == SFKeySelect || key == SFKeyPlayPause)) { [self reload]; return YES; }   // "OK – erneut versuchen"
        return NO;
    }
    SFRow *r = _rows[_row];
    // holding the arrows (remote helper repeats) = keep navigating
    if (key == SFKeyUpHold) key = SFKeyUp;
    else if (key == SFKeyDownHold) key = SFKeyDown;
    else if (key == SFKeyPrev) key = SFKeyLeft;
    else if (key == SFKeyNext) key = SFKeyRight;
    switch (key) {
        case SFKeyLeft:
            if (r.focusCol > 0) [self focusRow:_row col:r.focusCol - 1 animated:YES];
            else [self bump:-1];
            return YES;
        case SFKeyRight:
            if (r.focusCol + 1 < (NSInteger)r.items.count) [self focusRow:_row col:r.focusCol + 1 animated:YES];
            else if (!r.rail && _row + 1 < (NSInteger)_rows.count && [_rows[_row + 1] shelf] == r.shelf)
                [self focusRow:_row + 1 col:0 animated:YES];
            else [self bump:1];
            return YES;
        case SFKeyUp:
        case SFKeyDown: {
            NSInteger nr = _row + (key == SFKeyDown ? 1 : -1);
            if (nr < 0 && _searchPill) { [self focusHeaderSearch]; return YES; }
            if (nr < 0 || nr >= (NSInteger)_rows.count) { [self bump:0]; return YES; }
            SFRow *n = _rows[nr];
            NSInteger col;
            if (!r.rail && !n.rail && n.shelf == r.shelf) col = r.focusCol;   // grid: keep the column
            else if (n.rail) col = n.focusCol;                                // rail: continue where one was
            else {
                // nearest column to the x position
                CGFloat x = [self xForCol:r.focusCol inRow:r] - [self scrollOffsetForRow:r col:r.scrollCol];
                SFTileMetrics m = SFMetricsForStyle(n.style);
                col = (NSInteger)round((x - U(96)) / (U(m.width) + U(m.gap)));
            }
            [self focusRow:nr col:col animated:YES];
            return YES;
        }
        case SFKeySelect:
        case SFKeyPlayPause: {
            SFItem *it = [self focusedItem];
            if (!it) return YES;
            NSArray *shelfItems = [_page.shelves[r.shelf] items];
            NSUInteger idx = r.firstIndex + r.focusCol;
            if (self.onSelect) self.onSelect(it, shelfItems, idx);
            else SFOpenItem(self.navigator, it, shelfItems, idx);
            return YES;
        }
        case SFKeySelectHold: {
            SFItem *it = [self focusedItem];
            if (it) [self showContextMenuFor:it shelfItems:[_page.shelves[r.shelf] items] index:r.firstIndex + r.focusCol];
            return YES;
        }
        case SFKeyMenu:
            if (_row > 0 && _scrollY > 0) {   // first to the top, then back
                [self focusRow:0 col:[_rows[0] focusCol] animated:YES];
                return YES;
            }
            return NO;
        default:
            return NO;
    }
}

- (void)bump:(NSInteger)dir {
    // subtle "bump" feedback
    SFTileLayer *t = [_rows[_row] tiles][@([_rows[_row] focusCol])];
    if (!t) return;
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:dir ? @"position.x" : @"position.y"];
    CGFloat base = dir ? t.position.x : t.position.y, d = U(10) * (dir ?: 1);
    a.values = @[@(base), @(base + d), @(base - d * 0.4), @(base)];
    a.duration = 0.25;
    [t addAnimation:a forKey:@"bump"];
}
@end
