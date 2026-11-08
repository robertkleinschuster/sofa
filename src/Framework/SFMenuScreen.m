#import "SFMenuScreen.h"
#import "SFLayers.h"

@implementation SFMenuOption
+ (instancetype)option:(NSString *)title action:(dispatch_block_t)action {
    SFMenuOption *o = [SFMenuOption new]; o.title = title; o.action = action; return o;
}
@end

@implementation SFMenuScreen {
    NSString *_title, *_subtitle;
    NSArray *_options;
    NSMutableArray *_rows;
    CALayer *_panel, *_highlight;
    CALayer *_dim;    // darkens the screen below; fades while the panel slides
    CALayer *_list;   // clips the rows; scrolls when they don't fit (long language lists, notes)
    CALayer *_listMask;   // edge fade, moves with the scroll offset
    NSInteger _sel;
    CGFloat _rowX, _rowW;   // the rows' geometry (setOptions: rebuilds them in place)
}

- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle options:(NSArray *)options theme:(SFTheme *)theme {
    if ((self = [super initWithTheme:theme])) {
        _title = title; _subtitle = subtitle; _options = options; _subtitleLines = 2;
        _rows = [NSMutableArray new];
    }
    return self;
}
- (BOOL)isOpaque { return NO; }
- (void)willDisappear {
    [super willDisappear];
    dispatch_block_t f = self.onDisappear;
    self.onDisappear = nil;
    if (f) f();
}

- (void)layoutForSize:(CGSize)size {
    SFTheme *t = self.theme;
    CALayer *L = self.layer;
    [_panel removeFromSuperlayer];
    [_rows removeAllObjects];
    _listMask = nil;
    SFNoAnimate(^{
        [self->_dim removeFromSuperlayer];
        self->_dim = [CALayer layer];
        self->_dim.frame = L.bounds;
        self->_dim.backgroundColor = [NSColor colorWithDeviceWhite:0 alpha:0.55].CGColor;
        [L addSublayer:self->_dim];
        CGFloat pw = U(720);
        self->_panel = [CALayer layer];
        self->_panel.frame = CGRectMake(size.width - pw, 0, pw, size.height);
        self->_panel.backgroundColor = (t.light ? SFHexA(0xffffff, 0.97) : [t.background colorWithAlphaComponent:0.97]).CGColor;
        self->_panel.shadowOpacity = 0.6; self->_panel.shadowRadius = U(40);
        CGPathRef sp = CGPathCreateWithRect(self->_panel.bounds, NULL);   // a given shape: no offscreen pass per frame while it slides
        self->_panel.shadowPath = sp;
        CGPathRelease(sp);
        [L addSublayer:self->_panel];

        CGFloat x = U(64), w = pw - 2 * x, y = U(150);
        SFLabel *tl = [SFLabel labelWithFont:[t bold:40] color:t.text];
        tl.text = self->_title; tl.maxLines = 3;
        y += [tl sizeToFitWidth:w];
        tl.position = CGPointMake(x, U(150));
        [self->_panel addSublayer:tl];
        if (self->_subtitle.length) {
            SFLabel *sl = [SFLabel labelWithFont:[t regular:26] color:t.textDim];
            sl.text = self->_subtitle; sl.maxLines = self->_subtitleLines;
            sl.position = CGPointMake(x, y + U(8));
            y += [sl sizeToFitWidth:w] + U(8);
            [self->_panel addSublayer:sl];
        }
        y += U(48);
        // rows live in a clipping list; its bounds origin scrolls (select:) - the side padding keeps
        // the highlight's overhang (x - 24) visible
        self->_list = [CALayer layer];
        self->_list.frame = CGRectMake(0, y - U(8), pw, MAX(U(100), size.height - y - U(40)));
        self->_list.masksToBounds = YES;
        [self->_panel addSublayer:self->_list];
        self->_highlight = [CALayer layer];
        self->_highlight.cornerRadius = U(12);
        self->_highlight.backgroundColor = t.focus.CGColor;
        [self->_list addSublayer:self->_highlight];
        self->_rowX = x; self->_rowW = w;
        [self buildRows];
    });
    [self select:self.initialSelection animated:NO];
}

// The option rows in the list (layout, setOptions:), with the edge fade when they don't fit
- (void)buildRows {
    SFTheme *t = self.theme;
    for (CALayer *r in _rows) [r removeFromSuperlayer];
    [_rows removeAllObjects];
    _list.mask = nil; _listMask = nil;
    CGFloat x = _rowX, w = _rowW;
    __block CGFloat y = U(8);
    SFNoAnimate(^{
        CGFloat rh = U(76);
        for (SFMenuOption *o in self->_options) {
            CALayer *row = [CALayer layer];
            row.frame = CGRectMake(x - U(24), y, w + U(48), rh);
            SFLabel *l = [SFLabel labelWithFont:[t medium:30] color:t.text];
            l.text = o.title;
            CGFloat lh = [l sizeToFitWidth:o.detail.length ? w - U(200) : w];   // no value on the right: full width
            l.position = CGPointMake(U(24), (rh - lh) / 2);
            l.name = @"title";
            [row addSublayer:l];
            if (o.detail.length) {
                SFLabel *d = [SFLabel labelWithFont:[t regular:26] color:t.textDim];
                d.text = o.detail; d.alignment = NSRightTextAlignment;
                CGFloat dh = [d sizeToFitWidth:U(240)];
                d.position = CGPointMake(row.bounds.size.width - U(264), (rh - dh) / 2);
                d.name = @"detail";
                [row addSublayer:d];
            }
            [self->_list addSublayer:row];
            [self->_rows addObject:row];
            y += rh + U(6);
        }
        // scrollable: soft fade at the clipped edges instead of rows cut in half
        CGFloat lh = self->_list.bounds.size.height;
        if (y > lh) {
            CAGradientLayer *mask = [CAGradientLayer layer];
            mask.frame = self->_list.bounds;
            mask.colors = @[(id)[NSColor clearColor].CGColor, (id)[NSColor blackColor].CGColor,
                            (id)[NSColor blackColor].CGColor, (id)[NSColor clearColor].CGColor];
            CGFloat f = MIN(0.2, U(56) / lh);
            mask.locations = @[@0, @(f), @(1 - f), @1];
            self->_list.mask = mask;
            self->_listMask = mask;
        }
    });
}

// New rows in place, without the entrance again (a list that fills while it is open: Bluetooth
// devices found by a search). The selection stays on the option with the same title.
- (void)setOptions:(NSArray *)options {
    NSString *cur = _sel < (NSInteger)_options.count ? [_options[_sel] title] : nil;
    _options = [options copy];
    if (!_list) return;   // not laid out yet: the layout builds them
    NSInteger sel = MIN(_sel, (NSInteger)_options.count - 1);
    for (NSInteger i = 0; cur && i < (NSInteger)_options.count; i++)
        if ([[_options[i] title] isEqual:cur]) { sel = i; break; }
    [self buildRows];
    [self select:sel animated:NO];
}

// A side panel: slides in from the right edge and out again, opaque all the way; only the
// darkening of the screen below fades (user 2026-11-07: the slide in/out was missing)
- (CATransform3D)offscreen { return CATransform3DMakeTranslation(_panel.bounds.size.width + U(60), 0, 0); }   // + its shadow
- (void)prepareEntrance { _dim.opacity = 0; _panel.transform = [self offscreen]; }
- (void)enter { _dim.opacity = 1; _panel.transform = CATransform3DIdentity; }
- (void)exit { _dim.opacity = 0; _panel.transform = [self offscreen]; }

- (void)select:(NSInteger)i animated:(BOOL)anim {
    if (!_rows.count) return;
    _sel = MAX(0, MIN(i, (NSInteger)_rows.count - 1));
    CALayer *row = _rows[_sel];
    SFTheme *t = self.theme;
    NSColor *onFocus = t.focusText;
    // keep the selected row (and a peek of its neighbour) inside the visible list
    CGRect b = _list.bounds;
    CGFloat pad = U(8) + row.frame.size.height / 2, top = b.origin.y;
    if (CGRectGetMinY(row.frame) - pad < top) top = CGRectGetMinY(row.frame) - pad;
    if (CGRectGetMaxY(row.frame) + pad > top + b.size.height) top = CGRectGetMaxY(row.frame) + pad - b.size.height;
    CALayer *last = _rows.lastObject;
    top = MAX(0, MIN(top, CGRectGetMaxY(last.frame) + U(8) - b.size.height));
    b.origin.y = MAX(0, top);
    void (^ch)(void) = ^{
        self->_list.bounds = b;
        self->_listMask.frame = b;   // the mask lives in the list's (scrolled) coordinates
        if ([self->_listMask isKindOfClass:[CAGradientLayer class]]) {   // fade only where more rows follow
            CGFloat f = MIN(0.2, U(56) / b.size.height);
            BOOL more = CGRectGetMaxY(last.frame) + U(8) > b.origin.y + b.size.height + 1;
            ((CAGradientLayer *)self->_listMask).locations = @[@0, @(b.origin.y > 1 ? f : 0), @(more ? 1 - f : 1), @1];
        }
        self->_highlight.frame = row.frame;
        for (CALayer *r in self->_rows) {
            for (CALayer *s in r.sublayers) {
                if (![s isKindOfClass:[SFLabel class]]) continue;
                SFLabel *l = (SFLabel *)s;
                BOOL on = r == row;
                l.color = on ? onFocus : ([l.name isEqualToString:@"detail"] ? t.textDim : t.text);
            }
        }
    };
    if (anim) SFAnimate(0.18, ch); else SFNoAnimate(ch);
}

- (NSInteger)selectedIndex { return _sel; }

- (BOOL)handleKey:(SFKey)key {
    switch (key) {
        case SFKeyUp: [self select:_sel - 1 animated:YES]; return YES;
        case SFKeyDown: [self select:_sel + 1 animated:YES]; return YES;
        case SFKeySelect:
        case SFKeyPlayPause: {
            if (_sel >= (NSInteger)_options.count) return YES;
            SFMenuOption *o = _options[_sel];
            SFNavigator *nav = self.navigator;
            if (!o.keepOpen) [nav pop];
            if (o.action) dispatch_async(dispatch_get_main_queue(), o.action);
            return YES;
        }
        case SFKeyLeft: case SFKeyRight: case SFKeySelectHold: return YES;
        default: return NO;
    }
}
@end
