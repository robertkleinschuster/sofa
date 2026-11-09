// SFBrowseScreen - header: wordmark, page title, "Suche" pill and the status row (clock, phone, key hint).
#import "SFBrowseScreen+Private.h"

@implementation SFBrowseScreen (Header)

- (void)buildHeader:(CGSize)size {
    SFTheme *t = self.theme;
    [_header removeFromSuperlayer];
    _header = [CALayer layer];
    _header.frame = CGRectMake(0, 0, size.width, U(130));
    _header.zPosition = 50;
    _wordmark = [SFLabel labelWithFont:[t wordmarkFont:46] color:t.wordmarkColor];
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
    } else if (t.headerMark == SFHeaderMarkPlayPill) {
        // play symbol in front of the wordmark
        CALayer *pill = [CALayer layer];
        pill.backgroundColor = t.headerMarkColor.CGColor;
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
    } else if (t.headerMark == SFHeaderMarkBar || t.headerMark == SFHeaderMarkDot) {
        CALayer *bar = [CALayer layer];
        bar.backgroundColor = t.headerMarkColor.CGColor;
        bar.frame = CGRectMake(x, U(50), U(8), U(42));
        if (t.headerMark == SFHeaderMarkDot) { bar.frame = CGRectMake(x, U(48), U(44), U(44)); bar.cornerRadius = U(22); }
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
- (void)updatePhoneStatus {
    // remote control status (phone): on Home every remote, inside an app only the app's own
    BOOL paused = NO;
    NSString *s = [SFAppRegistry remoteStatusForTheme:self.theme.identifier paused:&paused];
    SFNoAnimate(^{
        self->_phonePill.hidden = !s;
        self->_phone.text = s ?: @"";
        self->_phoneDot.backgroundColor = (paused ? [NSColor colorWithCalibratedRed:0.95 green:0.65 blue:0.15 alpha:1] : [NSColor colorWithCalibratedRed:0.25 green:0.8 blue:0.4 alpha:1]).CGColor;
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
    BOOL show = it && (it.kind == SFItemVideo || it.kind == SFItemLive || (it.kind == SFItemFolder && ([it.identifier hasPrefix:@"show:"] || [it.identifier hasPrefix:@"downloads:"] || [[SFFollows shared] canFollow:it])));
    SFAnimate(0.2, ^{ self->_hint.opacity = show ? 0.85 : 0; self->_hintKey.opacity = show ? 0.85 : 0; });
}

- (void)updateClock {
    NSString *s = SFFormatClock([NSDate date]);
    if (![_clock.text isEqualToString:s]) { _clock.text = s; [self layoutStatusRow]; }
}
@end
