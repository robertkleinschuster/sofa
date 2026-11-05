#import "SFBrowseScreen.h"
#import "SFTile.h"
#import "SFLayers.h"
#import "SFStore.h"
#import "SFMenuScreen.h"
#import "SFDownloads.h"
#import "SFNet.h"
#import "SFLounge.h"
#import "SFFollows.h"
#import "SFYTSabr.h"
#import "SFLibrary.h"
#import "SFPlayerScreen.h"
#import "SFHome.h"
#import "SFLogo.h"
#import "SFSearch.h"
#import "SFWatchLater.h"

#import "SFBrowseScreen+Private.h"

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
- (instancetype)initWithPage:(SFPage *)page {
    if ((self = [super initWithTheme:[SFTheme themeNamed:page.themeName ?: @"home"]])) {
        _rows = [NSMutableArray new];
        _page = page;
        [self observeDownloads];
    }
    return self;
}
// keep the download status on the tiles live
- (void)observeDownloads {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshTiles) name:SFDownloadsDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateHint) name:SFNetOnlineDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updatePhoneStatus) name:SFLoungeRemotesDidChangeNotification object:nil];
}
- (SFPage *)page { return _page; }
- (BOOL)isOpaque { return !self.overlay; }

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
    BOOL brand = !self.overlay;   // overlay: only clock + key hint (the hero says what this is about)
    CGImageRef logo = brand && t.logo ? SFLogoImage(t.logo, t.logoVariant) : NULL;
    if (!brand) {
    } else if (logo) {
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
        // play symbol in front of the wordmark (own interpretation)
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
    if (!logo && brand) {
        _wordmark.position = CGPointMake(x, U(44));
        [_header addSublayer:_wordmark];
        x += _wordmark.bounds.size.width + U(28);
    }

    // "Suche" as a visible button next to the logo (like the search at the top in TV apps): Up from the
    // first row focuses it – so search is never more than one or two keys away.
    _searchPill = nil;
    if (self.searchSource && brand) {
        _searchPill = [CALayer layer];
        _searchPill.cornerRadius = U(26);
        _searchPill.borderWidth = U(2);
        _searchIcon = [CAShapeLayer layer];
        CGMutablePathRef sp = CGPathCreateMutable();
        CGPathAddEllipseInRect(sp, NULL, CGRectMake(U(2), U(2), U(18), U(18)));
        CGPathMoveToPoint(sp, NULL, U(17), U(17));
        CGPathAddLineToPoint(sp, NULL, U(25), U(25));
        _searchIcon.path = sp; CGPathRelease(sp);
        _searchIcon.fillColor = NULL;
        _searchIcon.lineWidth = U(3.5);
        _searchIcon.lineCap = kCALineCapRound;
        _searchIcon.frame = CGRectMake(U(22), U(13), U(27), U(27));
        [_searchPill addSublayer:_searchIcon];
        _searchLabel = [SFLabel labelWithFont:[t medium:26] color:t.text];
        _searchLabel.text = @"Suche";
        NSSize lsz = [_searchLabel.text sizeWithAttributes:@{NSFontAttributeName: _searchLabel.font}];
        CGFloat lh = [_searchLabel sizeToFitWidth:ceil(lsz.width) + 4];
        _searchLabel.position = CGPointMake(U(60), (U(52) - lh) / 2);
        [_searchPill addSublayer:_searchLabel];
        _searchPill.frame = CGRectMake(x + U(8), U(44), U(60) + ceil(lsz.width) + U(26), U(52));
        [_header addSublayer:_searchPill];
        x = CGRectGetMaxX(_searchPill.frame) + U(28);
        [self updateSearchPill:NO];
    }

    _pageTitle = [SFLabel labelWithFont:[t regular:34] color:t.textDim];
    _pageTitle.text = _page.subtitle.length ? [NSString stringWithFormat:@"%@  ·  %@", _page.title ?: @"", _page.subtitle] : _page.title;
    [_pageTitle sizeToFitWidth:size.width - x - U(960)];
    _pageTitle.position = CGPointMake(x, U(52));
    if (brand) [_header addSublayer:_pageTitle];

    // header band: soft gradient in the background colour so clock/hint are readable over any image
    CAGradientLayer *scrim = [CAGradientLayer layer];
    NSColor *top = t.backgroundTop ?: t.background;
    scrim.colors = @[(id)[top colorWithAlphaComponent:0.85].CGColor, (id)[top colorWithAlphaComponent:0].CGColor];
    scrim.frame = CGRectMake(0, 0, size.width, U(190));
    if (brand) [_header insertSublayer:scrim atIndex:0];
    _clock = [SFLabel labelWithFont:[t medium:32] color:t.light ? t.text : t.textDim];
    _clock.alignment = NSRightTextAlignment;
    _clock.shadow = !t.light;
    [_clock sizeToFitWidth:U(300)];
    _clock.position = CGPointMake(size.width - U(96) - U(300), U(52));
    [_header addSublayer:_clock];
    // status line top right (one shared centre line with the clock, right to left):
    //   [OK] halten: Optionen   ·   ● Handy: Name   ·   17:20
    // "OK" as a keycap: reads instantly as a remote key.
    _hint = [SFLabel labelWithFont:[t medium:26] color:t.text];
    _hint.shadow = !t.light;
    _hint.text = @"halten: Optionen";
    _hintKey = [CALayer layer];
    _hintKey.borderColor = t.text.CGColor; _hintKey.borderWidth = U(2); _hintKey.cornerRadius = U(8);
    SFLabel *ok = [SFLabel labelWithFont:[t bold:20] color:t.text];
    ok.text = @"OK"; ok.name = @"ok";
    [_hintKey addSublayer:ok];
    _hintKey.opacity = 0; _hint.opacity = 0;
    [_header addSublayer:_hintKey];
    [_header addSublayer:_hint];
    // phone status as a compact pill: with several users one sees at once whether a phone is controlling too
    _phonePill = [CALayer layer];
    _phonePill.backgroundColor = [t.accent colorWithAlphaComponent:t.light ? 0.12 : 0.22].CGColor;
    _phonePill.cornerRadius = U(20);
    _phoneDot = [CALayer layer];
    _phoneDot.cornerRadius = U(6);
    _phone = [SFLabel labelWithFont:[t medium:24] color:t.text];
    [_phonePill addSublayer:_phoneDot];
    [_phonePill addSublayer:_phone];
    [_header addSublayer:_phonePill];
    [self updatePhoneStatus];
    [self updateHint];
    [self updateClock];
    [self.layer addSublayer:_header];
}

static CGFloat textWidth(SFLabel *l) {
    if (!l.text.length) return 0;
    return ceil([[NSAttributedString alloc] initWithString:l.text attributes:@{NSFontAttributeName: l.font}].size.width) + 2;
}

// Lays out clock, phone pill and key hint right-aligned on one centre line
- (void)layoutStatusRow {
    if (!_clock) return;
    SFNoAnimate(^{
        CGFloat right = self.size.width - U(96);
        CGFloat ch = self->_clock.bounds.size.height, mid = U(52) + ch / 2;
        CGFloat cw = textWidth(self->_clock);
        CGFloat x = right - cw;   // left edge of the clock
        if (!self->_phonePill.hidden) {
            CGFloat lw = textWidth(self->_phone), ph = U(40);
            [self->_phone sizeToFitWidth:lw];
            CGFloat pw = U(18) + U(12) + U(10) + lw + U(18);
            x -= U(28) + pw;
            self->_phonePill.frame = CGRectMake(x, mid - ph / 2, pw, ph);
            self->_phoneDot.frame = CGRectMake(U(18), ph / 2 - U(6), U(12), U(12));
            self->_phone.position = CGPointMake(U(18) + U(12) + U(10), (ph - self->_phone.bounds.size.height) / 2);
        }
        CGFloat hw = textWidth(self->_hint);
        [self->_hint sizeToFitWidth:hw];
        x -= U(28) + hw;
        self->_hint.position = CGPointMake(x, mid - self->_hint.bounds.size.height / 2);
        SFLabel *ok = (SFLabel *)self->_hintKey.sublayers.firstObject;
        CGFloat ow = textWidth(ok); [ok sizeToFitWidth:ow];
        CGFloat kw = ow + U(16), kh = U(34);
        self->_hintKey.frame = CGRectMake(x - U(10) - kw, mid - kh / 2, kw, kh);
        ok.position = CGPointMake(U(8), (kh - ok.bounds.size.height) / 2);
    });
}

// Preload YouTube: when focus rests on a video for 1.2 s, resolve the stream address already
// (resolver cache) – OK then starts almost instantly. Downloaded content does not need this.
- (void)schedulePrefetch {
    [_prefetchTimer invalidate];
    _prefetchTimer = [NSTimer scheduledTimerWithTimeInterval:1.2 target:self selector:@selector(prefetchFocused) userInfo:nil repeats:NO];
}
- (void)prefetchFocused {
    _prefetchTimer = nil;
    SFItem *it = [self focusedItem];
    NSString *ref = it.resolverRef ?: it.identifier;
    if (it.kind != SFItemVideo || ![ref hasPrefix:@"yt:"] || [[SFDownloads shared] fileFor:it.identifier] || ![SFNet isOnline]) return;
    [[SFYTSabr shared] preloadOnFocus:[ref substringFromIndex:3]];
}

- (void)updatePhoneStatus {
    SFLounge *l = [SFLounge shared];
    NSArray *n = l.remoteNames;
    NSString *s = l.paused ? @"Handy pausiert" : n.count ? [@"Handy: " stringByAppendingString:[n componentsJoinedByString:@", "]] : nil;
    // the phone only controls YouTube: show the status only on Home and in the YouTube app
    NSString *tid = self.theme.identifier;
    if (![tid isEqualToString:@"home"] && ![tid isEqualToString:@"youtube"]) s = nil;
    SFNoAnimate(^{
        self->_phonePill.hidden = !s;
        self->_phone.text = s ?: @"";
        self->_phoneDot.backgroundColor = (l.paused ? [NSColor colorWithCalibratedRed:0.95 green:0.65 blue:0.15 alpha:1] : [NSColor colorWithCalibratedRed:0.25 green:0.8 blue:0.4 alpha:1]).CGColor;
    });
    [self layoutStatusRow];
}

- (void)updateHint {
    if (![SFNet isOnline]) {   // offline takes precedence: explains why online content does not play
        SFNoAnimate(^{ self->_hint.text = @"Keine Internetverbindung – Downloads sind verfügbar"; });
        [self layoutStatusRow];
        SFAnimate(0.2, ^{ self->_hint.opacity = 1; self->_hintKey.opacity = 0; });
        return;
    }
    if (![_hint.text isEqualToString:@"halten: Optionen"]) { SFNoAnimate(^{ self->_hint.text = @"halten: Optionen"; }); [self layoutStatusRow]; }
    SFItem *it = _headerFocus ? nil : [self focusedItem];
    BOOL show = it && (it.kind == SFItemVideo || it.kind == SFItemLive || (it.kind == SFItemFolder && ([it.identifier hasPrefix:@"show:"] || [it.identifier hasPrefix:@"downloads:"] || [[SFDownloads shared] canSubscribe:it] || [[SFFollows shared] canFollow:it])));
    SFAnimate(0.2, ^{ self->_hint.opacity = show ? 0.85 : 0; self->_hintKey.opacity = show ? 0.85 : 0; });
}

- (void)updateClock {
    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm"; }
    NSString *s = [df stringFromDate:[NSDate date]];
    if (![_clock.text isEqualToString:s]) { _clock.text = s; [self layoutStatusRow]; }
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

#pragma mark Focus

- (SFItem *)focusedItem {
    if (_row >= (NSInteger)_rows.count) return nil;
    SFRow *r = _rows[_row];
    return r.focusCol < (NSInteger)r.items.count ? r.items[r.focusCol] : nil;
}

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

#pragma mark Hero / Backdrop

- (void)updateBackdropFor:(SFItem *)it {
    if (self.overlay) return;   // the video itself is the backdrop
    NSString *src = it.backdrop ?: _page.backdrop;
    if ([src isEqualToString:_backdrop.source] && _backdropBox.opacity > 0) return;
    if (!src.length) { SFAnimate(0.4, ^{ self->_backdropBox.opacity = 0; }); return; }
    _backdrop.source = src;
    CGFloat op = self.showsHero ? 0.75 : 0.4;   // more restrained on grid pages
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
        CGFloat w = self.size.width * (self.overlay ? 0.6 : 0.5);
        SFNoAnimate(^{
            self->_heroTitle.text = it.heroTitle ?: it.title ?: self->_page.title;
            CGFloat h1 = [self->_heroTitle sizeToFitWidth:w];
            NSMutableArray *meta = [NSMutableArray new];
            if (it.channel.length && ![it.channel isEqualToString:it.title]) [meta addObject:it.channel];
            if (it.date) [meta addObject:SFFormatDateShort(it.date)];
            if (it.duration > 0) [meta addObject:SFFormatDuration(it.duration)];
            if (!meta.count && it.subtitle.length) [meta addObject:it.subtitle];
            if (it.heroMeta.length) { [meta removeAllObjects]; [meta addObject:it.heroMeta]; }
            self->_heroMeta.text = [meta componentsJoinedByString:@"  ·  "];
            CGFloat h2 = [self->_heroMeta sizeToFitWidth:w];
            NSString *plot = [it.plot stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            self->_heroPlot.text = plot;
            // fit the plot lines to the space available down to the shelves
            CGFloat y = self.overlay ? U(120) : U(190);   // overlay: no logo row above
            CGFloat avail = self->_contentTop - U(40) - (y + h1 + h2 + U(26));
            // first line incl. descender/shadow padding, each further line only its line height
            self->_heroPlot.maxLines = 1;
            CGFloat lh = [self->_heroPlot sizeToFitWidth:w];
            self->_heroPlot.maxLines = 2;
            CGFloat step = MAX(1, [self->_heroPlot sizeToFitWidth:w] - lh);
            NSInteger fit = avail < lh ? 0 : 1 + (NSInteger)floor((avail - lh) / step);
            NSInteger lines = MAX(0, MIN(self.heroPlotLines > 0 ? self.heroPlotLines : 3, fit));
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

#pragma mark - Opening

SFBrowseScreen *SFBrowseScreenForFolder(SFItem *item, SFTheme *fallback) {
    SFTheme *t = [SFTheme themeNamed:item.themeName ?: fallback.identifier ?: @"home"];
    SFBrowseScreen *b = [[SFBrowseScreen alloc] initWithLoader:item.pageLoader theme:t];
    b.folderIdentifier = item.identifier;
    // offline pages (show, downloads) follow the inventory live
    if ([item.identifier hasPrefix:@"show:"] || [item.identifier hasPrefix:@"downloads:"] || [item.identifier hasPrefix:@"ytchannel:"]) b.reloadNotification = SFLibraryDidChangeNotification;
    if ([item.identifier hasPrefix:@"room:"]) b.reloadNotification = SFDownloadsStorageDidChangeNotification;   // deletions, online checks
    if ([item.identifier hasPrefix:@"ytchannel:"]) b.showsHero = YES;   // channel header (banner, subscribers, description)
    return b;
}

void SFOpenItem(SFNavigator *nav, SFItem *item, NSArray *queue, NSUInteger index) {
    // copy-protected: say so honestly right away instead of spinner + error screen
    if (item.drm && (item.kind == SFItemVideo || item.kind == SFItemLive)) { [nav toast:SFDRMNotice]; return; }
    switch (item.kind) {
        case SFItemVideo:
        case SFItemLive: {
            SFPlayerScreen *p = [[SFPlayerScreen alloc] initWithItem:item queue:queue index:index];
            [nav push:p];
            break;
        }
        case SFItemFolder:
            [nav push:SFBrowseScreenForFolder(item, nav.top.theme)];
            break;
        case SFItemAction:
            if (item.action) item.action();
            break;
    }
}
