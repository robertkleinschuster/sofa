#import "SFBrowseScreen.h"
#import "SFTile.h"
#import "SFLayers.h"
#import "SFStore.h"
#import "SFMenuScreen.h"
#import "SFDownloads.h"
#import "SFLibrary.h"
#import "SFPlayerScreen.h"
#import "SFHome.h"
#import "SFLogo.h"

// Ein sichtbarer "Zeilen"-Abschnitt: Rail = eine Zeile; Grid = mehrere Zeilen.
@interface SFRow : NSObject
@property (nonatomic) NSUInteger shelf;
@property (nonatomic, strong) NSArray *items;        // Items dieser Zeile
@property (nonatomic) NSUInteger firstIndex;         // Index im Shelf
@property (nonatomic) SFTileStyle style;
@property (nonatomic) BOOL rail;
@property (nonatomic, copy) NSString *title;         // nur erste Zeile eines Shelfs
@property (nonatomic) CGFloat y, height, titleHeight;
@property (nonatomic) NSInteger focusCol;            // letzter Fokus in der Zeile
@property (nonatomic) NSInteger scrollCol;           // erste sichtbare Spalte (Rail)
@property (nonatomic, strong) CALayer *layer;        // Zeilencontainer
@property (nonatomic, strong) CALayer *strip;        // verschiebbarer Kachelstreifen
@property (nonatomic, strong) NSMutableDictionary *tiles; // @(col) -> SFTileLayer
@end
@implementation SFRow @end

@implementation SFBrowseScreen {
    SFPage *_page;
    CALayer *_bg;
    SFImageLayer *_backdrop;
    CALayer *_backdropBox;
    CAGradientLayer *_backdropFade, *_backdropFadeBottom;
    CALayer *_header;
    SFLabel *_wordmark, *_pageTitle, *_clock, *_hint;
    CALayer *_content;           // vertikal verschobener Inhalt
    NSMutableArray *_rows;
    NSInteger _row;              // fokussierte Zeile
    CGFloat _contentTop;         // y-Beginn der Shelves
    CGFloat _scrollY;
    // Hero
    CALayer *_hero;
    SFLabel *_heroTitle, *_heroMeta, *_heroPlot;
    NSUInteger _heroSeq;
    // Status
    CALayer *_spinner;
    SFLabel *_empty;
    NSTimer *_clockTimer;
    BOOL _loading, _laidOut;
}

- (instancetype)initWithLoader:(SFPageLoader)loader theme:(SFTheme *)theme {
    if ((self = [super initWithTheme:theme])) {
        _loader = [loader copy];
        _rows = [NSMutableArray new];
        [self observeDownloads];
    }
    return self;
}
- (instancetype)initWithPage:(SFPage *)page {
    if ((self = [super initWithTheme:[SFTheme themeNamed:page.themeName ?: @"home"]])) {
        _rows = [NSMutableArray new];
        _page = page;
        [self observeDownloads];
    }
    return self;
}
// Download-Status auf den Kacheln live halten
- (void)observeDownloads {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshTiles) name:SFDownloadsDidChangeNotification object:nil];
}
- (SFPage *)page { return _page; }

- (void)setReloadNotification:(NSString *)name {
    if (_reloadNotification) [[NSNotificationCenter defaultCenter] removeObserver:self name:_reloadNotification object:nil];
    _reloadNotification = [name copy];
    if (name) [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:name object:nil];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

#pragma mark Layout

- (void)layoutForSize:(CGSize)size {
    CALayer *L = self.layer;
    SFTheme *t = self.theme;
    SFNoAnimate(^{
        [self->_bg removeFromSuperlayer];
        self->_bg = SFGradientBackground(t.backgroundTop, t.background, L.bounds);
        self->_bg.zPosition = -10;
        [L addSublayer:self->_bg];
        L.backgroundColor = t.background.CGColor;

        if (!self->_backdrop) {
            // Bild + Verläufe in einem Container, dessen Deckkraft gemeinsam animiert
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
        // Hintergrundbild rechts oben, nach links und unten ausgeblendet
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
    if (_page) [self buildRows];
}

- (void)buildHeader:(CGSize)size {
    SFTheme *t = self.theme;
    [_header removeFromSuperlayer];
    _header = [CALayer layer];
    _header.frame = CGRectMake(0, 0, size.width, U(130));
    _header.zPosition = 50;
    _wordmark = [SFLabel labelWithFont:[t wordmarkFont:46] color:t.light ? t.accent : t.text];
    if ([t.identifier isEqualToString:@"youtube"]) _wordmark.color = t.text;
    _wordmark.text = t.wordmark;
    NSSize ws = [t.wordmark sizeWithAttributes:@{NSFontAttributeName: _wordmark.font}];
    [_wordmark sizeToFitWidth:ceil(ws.width) + 4];
    CGFloat x = U(96);
    CGImageRef logo = t.logo ? SFLogoImage(t.logo, t.logoVariant) : NULL;
    if (logo) {
        CGFloat aspect = (CGFloat)CGImageGetWidth(logo) / CGImageGetHeight(logo);
        CGFloat lh = aspect < 2.5 ? U(66) : U(50), lw = lh * aspect;
        if (lw > U(420)) { lw = U(420); lh = lw * CGImageGetHeight(logo) / CGImageGetWidth(logo); }
        CALayer *lg = [CALayer layer];
        lg.contents = (__bridge id)logo;
        lg.contentsGravity = kCAGravityResizeAspect;
        lg.frame = CGRectMake(x, U(48) + (U(50) - lh) / 2, lw, lh);
        [_header addSublayer:lg];
        x += lw + U(28);
    } else if ([t.identifier isEqualToString:@"youtube"]) {
        // Abspiel-Symbol vor dem Schriftzug (eigene Interpretation)
        CALayer *pill = [CALayer layer];
        pill.backgroundColor = t.accent.CGColor;
        pill.cornerRadius = U(10);
        pill.frame = CGRectMake(x, U(50), U(52), U(38));
        CAShapeLayer *tri = [CAShapeLayer layer];
        CGMutablePathRef p = CGPathCreateMutable();
        CGPathMoveToPoint(p, NULL, U(20), U(10));
        CGPathAddLineToPoint(p, NULL, U(36), U(19));
        CGPathAddLineToPoint(p, NULL, U(20), U(28));
        CGPathCloseSubpath(p);
        tri.path = p; CGPathRelease(p);
        tri.fillColor = CGColorGetConstantColor(kCGColorWhite);
        [pill addSublayer:tri];
        [_header addSublayer:pill];
        x += U(64);
    } else if ([t.identifier isEqualToString:@"zdf"] || [t.identifier isEqualToString:@"orf"] || [t.identifier isEqualToString:@"ard"]) {
        CALayer *bar = [CALayer layer];
        bar.backgroundColor = t.accent.CGColor;
        bar.frame = CGRectMake(x, U(50), U(8), U(42));
        if ([t.identifier isEqualToString:@"ard"]) { bar.frame = CGRectMake(x, U(48), U(44), U(44)); bar.cornerRadius = U(22); bar.backgroundColor = SFHex(0x1d6fd8).CGColor; }
        [_header addSublayer:bar];
        x += bar.frame.size.width + U(16);
    }
    if (!logo) {
        _wordmark.position = CGPointMake(x, U(44));
        [_header addSublayer:_wordmark];
        x += _wordmark.bounds.size.width + U(28);
    }

    _pageTitle = [SFLabel labelWithFont:[t regular:34] color:t.textDim];
    _pageTitle.text = _page.subtitle.length ? [NSString stringWithFormat:@"%@  ·  %@", _page.title ?: @"", _page.subtitle] : _page.title;
    [_pageTitle sizeToFitWidth:size.width - x - U(960)];
    _pageTitle.position = CGPointMake(x, U(52));
    [_header addSublayer:_pageTitle];

    _clock = [SFLabel labelWithFont:[t medium:32] color:t.textDim];
    _clock.alignment = NSRightTextAlignment;
    [_clock sizeToFitWidth:U(300)];
    _clock.position = CGPointMake(size.width - U(96) - U(300), U(52));
    [_header addSublayer:_clock];
    // Remote-Hinweis: Optionen gibt es nur per Halten – sonst unentdeckbar
    _hint = [SFLabel labelWithFont:[t regular:26] color:t.textDim];
    _hint.alignment = NSRightTextAlignment;
    _hint.text = @"OK halten: Optionen";
    [_hint sizeToFitWidth:U(520)];
    _hint.position = CGPointMake(size.width - U(96) - U(300) - U(560), U(58));
    _hint.opacity = 0;
    [_header addSublayer:_hint];
    [self updateHint];
    [self updateClock];
    [self.layer addSublayer:_header];
}

- (void)updateHint {
    SFItem *it = [self focusedItem];
    BOOL show = it && (it.kind == SFItemVideo || it.kind == SFItemLive || (it.kind == SFItemFolder && ([it.identifier hasPrefix:@"show:"] || [[SFDownloads shared] canSubscribe:it])));
    SFAnimate(0.2, ^{ self->_hint.opacity = show ? 0.8 : 0; });
}

- (void)updateClock {
    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm"; }
    _clock.text = [df stringFromDate:[NSDate date]];
}

#pragma mark Lifecycle

- (void)willAppear {
    [self updateClock];
    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(updateClock) userInfo:nil repeats:YES];
    if (!_page && !_loading) [self reload];
    else {
        for (SFRow *r in _rows) for (SFTileLayer *tl in r.tiles.allValues) [tl refreshProgress];
    }
}
- (void)willDisappear { [_clockTimer invalidate]; _clockTimer = nil; }
- (void)didAppear {}

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

- (void)setPage:(SFPage *)page keepFocus:(BOOL)keep {
    // Fokus merken (per Shelf-Titel + Item-ID)
    NSString *fShelf = nil, *fItem = nil;
    if (keep && _row < (NSInteger)_rows.count) {
        SFRow *r = _rows[_row];
        fShelf = r.title ?: [self shelfTitleForRow:r];
        SFItem *it = [self focusedItem];
        fItem = it.identifier ?: it.title;
    }
    _page = page;
    if (!_laidOut) return;
    _pageTitle.text = page.subtitle.length ? [NSString stringWithFormat:@"%@  ·  %@", page.title ?: @"", page.subtitle] : page.title;
    [self buildRows];
    if (fShelf) {
        for (NSUInteger i = 0; i < _rows.count; i++) {
            SFRow *r = _rows[i];
            if (![[self shelfTitleForRow:r] isEqualToString:fShelf]) continue;
            for (NSUInteger c = 0; c < r.items.count; c++) {
                SFItem *it = r.items[c];
                if ([(it.identifier ?: it.title) isEqualToString:fItem]) {
                    [self focusRow:i col:c animated:NO];
                    return;
                }
            }
        }
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
        y = U(560);
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
                y += r.height + U(40);
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
    [self focusRow:0 col:0 animated:NO];
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
    if (r.rail && r.scrollCol > 0) {
        SFTileMetrics m = SFMetricsForStyle(r.style);
        strip.position = CGPointMake(-r.scrollCol * (U(m.width) + U(m.gap)), r.titleHeight);
    }
    r.layer = rl; r.strip = strip;
    r.tiles = [NSMutableDictionary new];
    SFNoAnimate(^{ [self->_content addSublayer:rl]; });
    [self updateTilesInRow:r];
}

- (CGFloat)xForCol:(NSInteger)c inRow:(SFRow *)r {
    SFTileMetrics m = SFMetricsForStyle(r.style);
    return U(96) + c * (U(m.width) + U(m.gap));
}

- (void)updateTilesInRow:(SFRow *)r {
    if (!r.layer) return;
    SFTileMetrics m = SFMetricsForStyle(r.style);
    CGFloat step = U(m.width) + U(m.gap);
    NSInteger visible = (NSInteger)ceil(self.size.width / step) + 1;
    NSInteger from = MAX(0, r.scrollCol - 2), to = MIN((NSInteger)r.items.count - 1, r.scrollCol + visible + 2);
    // Entfernen außerhalb
    for (NSNumber *k in r.tiles.allKeys) {
        NSInteger c = k.integerValue;
        if (c < from - 4 || c > to + 4) {
            SFNoAnimate(^{ [r.tiles[k] removeFromSuperlayer]; });
            [r.tiles removeObjectForKey:k];
        }
    }
    for (NSInteger c = from; c <= to; c++) {
        if (r.tiles[@(c)]) continue;
        SFTileLayer *tl = [[SFTileLayer alloc] initWithItem:r.items[c] style:r.style theme:self.theme];
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

#pragma mark Focus

- (SFItem *)focusedItem {
    if (_row >= (NSInteger)_rows.count) return nil;
    SFRow *r = _rows[_row];
    return r.focusCol < (NSInteger)r.items.count ? r.items[r.focusCol] : nil;
}

- (void)focusRow:(NSInteger)row col:(NSInteger)col animated:(BOOL)anim {
    if (row < 0 || row >= (NSInteger)_rows.count) return;
    SFRow *old = _row < (NSInteger)_rows.count ? _rows[_row] : nil;
    SFTileLayer *ot = old.tiles[@(old.focusCol)];
    ot.focused = NO;

    SFRow *r = _rows[row];
    col = MAX(0, MIN(col, (NSInteger)r.items.count - 1));
    _row = row;
    r.focusCol = col;
    [self updateHint];

    // Vertikal: fokussierte Zeile an die Oberkante des Inhaltsbereichs
    CGFloat target = MAX(0, r.y - _contentTop);
    if (row == 0) target = 0;
    _scrollY = target;
    [self updateVisibleRows];

    // Horizontal (Rail): Fokus bleibt in Spalte 1, solange möglich
    if (r.rail) {
        SFTileMetrics m = SFMetricsForStyle(r.style);
        CGFloat step = U(m.width) + U(m.gap);
        NSInteger fit = MAX(1, (NSInteger)floor((self.size.width - U(192) + U(m.gap)) / step));
        NSInteger maxScroll = MAX(0, (NSInteger)r.items.count - fit);
        NSInteger sc = MIN(maxScroll, MAX(0, col - 1));
        if (col >= r.scrollCol + 1 && col < r.scrollCol + fit - 1 && r.scrollCol <= maxScroll) sc = r.scrollCol;
        if (col < r.scrollCol + 1) sc = MAX(0, col - 1);
        if (col > r.scrollCol + fit - 2) sc = MIN(maxScroll, col - fit + 2);
        r.scrollCol = sc;
        [self updateTilesInRow:r];
        CGFloat dx = -sc * step;
        void (^move)(void) = ^{ r.strip.position = CGPointMake(dx, r.titleHeight); };
        if (anim) SFAnimate(0.3, move); else SFNoAnimate(move);
    }
    // Zeilen oberhalb des Inhaltsbereichs ausblenden (laufen nicht unter Header/Hero)
    CGFloat limit = self->_contentTop - U(20);
    void (^vmove)(void) = ^{
        self->_content.position = CGPointMake(0, -self->_scrollY);
        for (SFRow *x in self->_rows) {
            if (!x.layer) continue;
            x.layer.opacity = (x.y - self->_scrollY < limit) ? 0 : 1;
        }
    };
    if (anim) SFAnimate(0.34, vmove); else SFNoAnimate(vmove);

    SFTileLayer *nt = r.tiles[@(col)];
    nt.focused = YES;
    if (self.showsHero) [self updateHeroFor:[self focusedItem]];
    else [self updateBackdropFor:[self focusedItem]];
}

- (BOOL)handleKey:(SFKey)key {
    if (!_rows.count) return NO;
    SFRow *r = _rows[_row];
    // Halten der Pfeile (Remote-Helper wiederholt) = weiter navigieren
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
            if (nr < 0 || nr >= (NSInteger)_rows.count) { [self bump:0]; return YES; }
            SFRow *n = _rows[nr];
            NSInteger col;
            if (!r.rail && !n.rail && n.shelf == r.shelf) col = r.focusCol;   // Raster: Spalte halten
            else if (n.rail) col = n.focusCol;                                // Rail: dort weiter, wo man war
            else {
                // nächstliegende Spalte zur x-Position
                CGFloat x = [self xForCol:r.focusCol - r.scrollCol inRow:r];
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
            if (_row > 0 && _scrollY > 0) {   // erst nach oben, dann zurück
                [self focusRow:0 col:[_rows[0] focusCol] animated:YES];
                return YES;
            }
            return NO;
        default:
            return NO;
    }
}

- (void)bump:(NSInteger)dir {
    // dezentes "Anschlag"-Feedback
    SFTileLayer *t = [_rows[_row] tiles][@([_rows[_row] focusCol])];
    if (!t) return;
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:dir ? @"position.x" : @"position.y"];
    CGFloat base = dir ? t.position.x : t.position.y, d = U(10) * (dir ?: 1);
    a.values = @[@(base), @(base + d), @(base - d * 0.4), @(base)];
    a.duration = 0.25;
    [t addAnimation:a forKey:@"bump"];
}

#pragma mark Kontextmenü

- (void)showContextMenuFor:(SFItem *)it shelfItems:(NSArray *)items index:(NSUInteger)idx {
    NSMutableArray *opts = [NSMutableArray new];
    __weak SFBrowseScreen *ws = self;
    SFNavigator *nav = self.navigator;
    if (it.kind == SFItemVideo || it.kind == SFItemLive) {
        double p = [[SFStore shared] progressFor:it.identifier];
        [opts addObject:[SFMenuOption option:(p > 0 && p < 1) ? @"Fortsetzen" : @"Abspielen" action:^{ SFOpenItem(nav, it, items, idx); }]];
        if (p > 0 && p < 1) {
            [opts addObject:[SFMenuOption option:@"Von Anfang abspielen" action:^{
                SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:it queue:items index:idx];
                ps.startFromBeginning = YES;
                [nav push:ps];
            }]];
        }
        if (it.kind == SFItemVideo) {   // Offline-Schicht: Download ist eine Option des Inhalts
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
        if (it.kind == SFItemVideo) {
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
        SFShow *show = it.channel ? [[SFLibrary shared] showNamed:it.channel] : nil;
        if (show && ![_page.title isEqualToString:show.name]) {
            [opts addObject:[SFMenuOption option:[NSString stringWithFormat:@"Zu „%@“", show.name] action:^{
                SFItem *f = [SFItem new];
                f.kind = SFItemFolder; f.themeName = show.source;
                f.pageLoader = [SFHome showLoader:show.name];
                SFOpenItem(nav, f, nil, 0);
            }]];
        }
    } else if (it.kind == SFItemFolder) {
        [opts addObject:[SFMenuOption option:@"Öffnen" action:^{ SFOpenItem(nav, it, items, idx); }]];
        SFDownloads *dl = [SFDownloads shared];
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
            SFShow *sh = [[SFLibrary shared] showNamed:ch];
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
        if ([dl canSubscribe:it]) {
            BOOL on = [dl isSubscribed:it.identifier];
            SFMenuOption *o = [SFMenuOption option:@"Automatisch laden" action:^{
                if (on) { [dl unsubscribe:it.identifier]; [nav toast:@"Automatisch laden aus – vorhandene Folgen bleiben"]; }
                else { [dl subscribe:it]; [nav toast:[NSString stringWithFormat:@"Neue Folgen von „%@“ werden automatisch geladen – auch offline verfügbar", it.title]]; }
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

#pragma mark Hero / Backdrop

- (void)updateBackdropFor:(SFItem *)it {
    NSString *src = it.backdrop ?: _page.backdrop;
    if ([src isEqualToString:_backdrop.source] && _backdropBox.opacity > 0) return;
    if (!src.length) { SFAnimate(0.4, ^{ self->_backdropBox.opacity = 0; }); return; }
    _backdrop.source = src;
    CGFloat op = self.showsHero ? 0.75 : 0.4;   // auf Raster-Seiten zurückhaltender
    if (self.theme.light) op *= 0.6;
    SFAnimate(0.5, ^{ self->_backdropBox.opacity = op; });
}

- (void)buildHero:(CGSize)size {
    SFTheme *t = self.theme;
    _hero = [CALayer layer];
    _hero.frame = CGRectMake(0, 0, size.width, U(560));
    _hero.zPosition = 20;
    _heroTitle = [SFLabel labelWithFont:[t bold:58] color:t.text];
    _heroTitle.maxLines = 2;
    _heroMeta = [SFLabel labelWithFont:[t medium:26] color:t.textDim];
    _heroPlot = [SFLabel labelWithFont:[t regular:27] color:t.textDim];
    _heroPlot.maxLines = 3;
    _heroPlot.lineSpacing = U(4);
    for (SFLabel *l in @[_heroTitle, _heroMeta, _heroPlot]) { l.shadow = !t.light; [_hero addSublayer:l]; }
    [self.layer addSublayer:_hero];
}

- (void)updateHeroFor:(SFItem *)it {
    NSUInteger seq = ++_heroSeq;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (seq != self->_heroSeq) return;
        CGFloat w = self.size.width * 0.5;
        SFNoAnimate(^{
            self->_heroTitle.text = it.title ?: self->_page.title;
            CGFloat h1 = [self->_heroTitle sizeToFitWidth:w];
            NSMutableArray *meta = [NSMutableArray new];
            if (it.channel.length && ![it.channel isEqualToString:it.title]) [meta addObject:it.channel];
            if (it.date) [meta addObject:SFFormatDateShort(it.date)];
            if (it.duration > 0) [meta addObject:SFFormatDuration(it.duration)];
            if (!meta.count && it.subtitle.length) [meta addObject:it.subtitle];
            self->_heroMeta.text = [meta componentsJoinedByString:@"  ·  "];
            CGFloat h2 = [self->_heroMeta sizeToFitWidth:w];
            NSString *plot = [it.plot stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            self->_heroPlot.text = plot;
            // Plot-Zeilen an den verfügbaren Platz bis zu den Shelves anpassen
            CGFloat y = U(190);
            CGFloat avail = self->_contentTop - U(40) - (y + h1 + h2 + U(26));
            CGFloat lh = [self->_heroPlot sizeToFitWidth:w] > 0 ? 0 : 0;
            self->_heroPlot.maxLines = 1;
            lh = [self->_heroPlot sizeToFitWidth:w];
            NSInteger lines = MAX(0, MIN(3, (NSInteger)floor(avail / MAX(1, lh))));
            self->_heroPlot.hidden = lines == 0;
            self->_heroPlot.maxLines = MAX(1, lines);
            [self->_heroPlot sizeToFitWidth:w];
            self->_heroTitle.position = CGPointMake(U(96), y);
            self->_heroMeta.position = CGPointMake(U(96), y + h1 + U(10));
            self->_heroPlot.position = CGPointMake(U(96), y + h1 + h2 + U(26));
        });
        CATransition *tr = [CATransition animation];
        tr.type = kCATransitionFade; tr.duration = 0.25;
        [self->_hero addAnimation:tr forKey:@"fade"];
        NSString *bd = (it.kind == SFItemVideo || it.kind == SFItemLive) ? (it.image ?: it.backdrop) : (it.backdrop ?: it.image);
        [self updateBackdropFor:bd ? ({ SFItem *b = [SFItem new]; b.backdrop = bd; b; }) : nil];
    });
}
@end

#pragma mark - Öffnen

void SFOpenItem(SFNavigator *nav, SFItem *item, NSArray *queue, NSUInteger index) {
    switch (item.kind) {
        case SFItemVideo:
        case SFItemLive: {
            SFPlayerScreen *p = [[SFPlayerScreen alloc] initWithItem:item queue:queue index:index];
            [nav push:p];
            break;
        }
        case SFItemFolder: {
            SFTheme *t = [SFTheme themeNamed:item.themeName ?: nav.top.theme.identifier ?: @"home"];
            SFBrowseScreen *b = [[SFBrowseScreen alloc] initWithLoader:item.pageLoader theme:t];
            // Offline-Seiten (Sendung, Downloads) folgen dem Bestand live
            if ([item.identifier hasPrefix:@"show:"] || [item.identifier hasPrefix:@"downloads:"]) b.reloadNotification = SFLibraryDidChangeNotification;
            [nav push:b];
            break;
        }
        case SFItemAction:
            if (item.action) item.action();
            break;
    }
}
