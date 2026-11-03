#import "SFKeyboardScreen.h"
#import "SFStore.h"
#import "SFLayers.h"
#import "SFLogo.h"

typedef NS_ENUM(NSInteger, SFKbKind) { SFKbChar, SFKbSpace, SFKbDelete, SFKbSubmit, SFKbLayout };

@interface SFKbKey : NSObject
@property (nonatomic) SFKbKind kind;
@property (nonatomic, copy) NSString *label;
@property (nonatomic) NSInteger col, span;
@property (nonatomic, strong) CALayer *bg;
@property (nonatomic, strong) SFLabel *text;
@end
@implementation SFKbKey
@end

// Raster in Design-Einheiten (1920x1080)
static const CGFloat kX = 96, kGridY = 330, kKeyW = 104, kKeyH = 92, kGap = 12;
static const CGFloat kFieldY = 150, kFieldH = 130;
static const CGFloat kSugRowH = 72, kSugGap = 6;
static const NSInteger kCols = 10, kMaxSug = 6, kMaxLen = 80;

@implementation SFKeyboardScreen {
    NSString *_title;
    NSMutableString *_text;
    void (^_completion)(NSString *);
    NSMutableArray *_rows;            // NSArray von SFKbKey je Zeile
    CALayer *_field, *_caret;
    SFLabel *_fieldText, *_hint, *_sugHeading;
    CALayer *_sugBox, *_sugHighlight;
    NSMutableArray *_sugRows;         // CALayer
    NSArray *_suggestions;            // NSString
    NSInteger _retRow, _retKey;       // Absprung-Taste bei „Rechts halten“ (-1 = geometrisch zurück)
    NSString *_sugHeadingText;
    NSInteger _area;                  // 0 = Raster, 1 = Vorschläge
    NSInteger _row, _key, _wantCol, _sug;
    NSUInteger _sugSeq;
    BOOL _laidOut;
}

- (instancetype)initWithTitle:(NSString *)title theme:(SFTheme *)theme initialText:(NSString *)text
                   completion:(void (^)(NSString *))completion {
    if ((self = [super initWithTheme:theme])) {
        _title = [title copy];
        _text = [NSMutableString stringWithString:text ?: @""];
        _completion = [completion copy];
        _placeholder = @"Suchbegriff eingeben";
        _submitTitle = @"Suchen";
        _sugRows = [NSMutableArray new];
        _suggestions = @[];
        _retRow = -1;
    }
    return self;
}

- (NSString *)text { return [_text copy]; }

#pragma mark Aufbau

- (NSArray *)buildKeys {
    // Layout wählbar (gemerkt): ABC (alphabetisch, für Ungeübte) oder QWERTZ (wie die Computertastatur)
    BOOL qwertz = [[[SFStore shared] setting:@"keyboard.layout"] isEqualToString:@"qwertz"];
    NSArray *lines = qwertz ? @[@"qwertzuiop", @"asdfghjklö", @"yxcvbnmäüß", @"1234567890"]
                            : @[@"abcdefghij", @"klmnopqrst", @"uvwxyzäöüß", @"1234567890"];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSString *line in lines) {
        NSMutableArray *r = [NSMutableArray new];
        for (NSUInteger i = 0; i < line.length; i++) {
            SFKbKey *k = [SFKbKey new];
            k.kind = SFKbChar; k.label = [line substringWithRange:NSMakeRange(i, 1)];
            k.col = i; k.span = 1;
            [r addObject:k];
        }
        [rows addObject:r];
    }
    NSMutableArray *last = [NSMutableArray new];
    NSArray *specials = @[@[@(SFKbLayout), qwertz ? @"ABC" : @"QWERTZ", @0, @2], @[@(SFKbSpace), @"Leerzeichen", @2, @3],
                          @[@(SFKbDelete), @"Löschen", @5, @2], @[@(SFKbSubmit), self.submitTitle ?: @"Suchen", @7, @3]];
    for (NSArray *s in specials) {
        SFKbKey *k = [SFKbKey new];
        k.kind = [s[0] integerValue]; k.label = s[1]; k.col = [s[2] integerValue]; k.span = [s[3] integerValue];
        [last addObject:k];
    }
    [rows addObject:last];
    return rows;
}

- (NSColor *)keyColor { return self.theme.light ? SFHex(0xffffff) : self.theme.surface; }

// Textfarbe auf der Fokusfläche: nach Helligkeit der Fokusfarbe
- (NSColor *)onFocus {
    NSColor *f = [self.theme.focus colorUsingColorSpaceName:NSDeviceRGBColorSpace];
    CGFloat l = 0.299 * f.redComponent + 0.587 * f.greenComponent + 0.114 * f.blueComponent;
    return l > 0.6 ? SFHex(0x111111) : SFHex(0xffffff);
}

- (void)layoutForSize:(CGSize)size {
    SFTheme *t = self.theme;
    CALayer *L = self.layer;
    for (CALayer *s in [L.sublayers copy]) [s removeFromSuperlayer];
    [_sugRows removeAllObjects];
    _rows = [[self buildKeys] mutableCopy];
    SFNoAnimate(^{
        L.backgroundColor = t.background.CGColor;
        [L addSublayer:SFGradientBackground(t.backgroundTop, t.background, CGRectMake(0, 0, size.width, size.height))];

        // Kopf: Logo/Schriftzug + Titel
        CGFloat x = U(kX);
        CGImageRef logo = t.logo ? SFLogoImage(t.logo, t.logoVariant) : NULL;
        if (logo) {
            CGFloat aspect = (CGFloat)CGImageGetWidth(logo) / CGImageGetHeight(logo);
            CGFloat lh = aspect < 2.5 ? U(66) : U(50), lw = lh * aspect;
            if (lw > U(420)) { lw = U(420); lh = lw / aspect; }
            CALayer *lg = [CALayer layer];
            lg.contents = (__bridge id)logo;
            lg.contentsGravity = kCAGravityResizeAspect;
            lg.frame = CGRectMake(x, U(48) + (U(50) - lh) / 2, lw, lh);
            [L addSublayer:lg];
            x += lw + U(28);
        } else if (t.wordmark.length) {
            SFLabel *wm = [SFLabel labelWithFont:[t wordmarkFont:46] color:t.light ? t.accent : t.text];
            wm.text = t.wordmark;
            NSSize ws = [t.wordmark sizeWithAttributes:@{NSFontAttributeName: wm.font}];
            [wm sizeToFitWidth:ceil(ws.width) + 4];
            wm.position = CGPointMake(x, U(44));
            [L addSublayer:wm];
            x += wm.bounds.size.width + U(28);
        }
        SFLabel *tl = [SFLabel labelWithFont:[t regular:34] color:t.textDim];
        tl.text = self->_title;
        [tl sizeToFitWidth:U(900)];
        tl.position = CGPointMake(x, U(52));
        [L addSublayer:tl];

        // Textzeile
        CGFloat fw = size.width - 2 * U(kX);
        self->_field = [CALayer layer];
        self->_field.frame = CGRectMake(U(kX), U(kFieldY), fw, U(kFieldH));
        self->_field.cornerRadius = U(MAX(6, t.corner));
        self->_field.backgroundColor = (t.light ? SFHex(0xffffff) : [NSColor colorWithDeviceWhite:0 alpha:0.35]).CGColor;
        self->_field.borderColor = t.focus.CGColor;
        self->_field.borderWidth = U(3);
        [L addSublayer:self->_field];
        self->_fieldText = [SFLabel labelWithFont:[t medium:60] color:t.text];
        [self->_fieldText sizeToFitWidth:fw - U(80)];
        self->_fieldText.position = CGPointMake(U(40), (U(kFieldH) - self->_fieldText.bounds.size.height) / 2);
        [self->_field addSublayer:self->_fieldText];
        self->_caret = [CALayer layer];
        self->_caret.backgroundColor = t.focus.CGColor;
        [self->_field addSublayer:self->_caret];

        // Tasten
        for (NSUInteger r = 0; r < self->_rows.count; r++) {
            for (SFKbKey *k in self->_rows[r]) {
                CGFloat kx = U(kX) + k.col * U(kKeyW + kGap), ky = U(kGridY) + r * U(kKeyH + kGap);
                CGFloat kw = k.span * U(kKeyW) + (k.span - 1) * U(kGap);
                k.bg = [CALayer layer];
                k.bg.frame = CGRectMake(kx, ky, kw, U(kKeyH));
                k.bg.cornerRadius = U(MAX(4, MIN(14, t.corner)));
                k.bg.shadowColor = CGColorGetConstantColor(kCGColorBlack);
                k.bg.shadowRadius = U(16); k.bg.shadowOffset = CGSizeMake(0, U(8));
                k.text = [SFLabel labelWithFont:k.kind == SFKbChar ? [t medium:42] : [t medium:30] color:t.text];
                k.text.text = k.label;
                k.text.alignment = NSCenterTextAlignment;
                CGFloat th = [k.text sizeToFitWidth:kw - U(12)];
                k.text.position = CGPointMake(U(6), (U(kKeyH) - th) / 2);
                [k.bg addSublayer:k.text];
                [L addSublayer:k.bg];
            }
        }

        // Vorschläge rechts neben dem Raster
        CGFloat sx = U(kX) + kCols * U(kKeyW + kGap) + U(60);
        self->_sugBox = [CALayer layer];
        self->_sugBox.frame = CGRectMake(sx, U(kGridY) - U(50), size.width - U(kX) - sx, U(50) + kMaxSug * U(kSugRowH + kSugGap));
        [L addSublayer:self->_sugBox];
        self->_sugHeading = [SFLabel labelWithFont:[t medium:28] color:t.textDim];
        [self->_sugHeading sizeToFitWidth:self->_sugBox.bounds.size.width];
        self->_sugHeading.position = CGPointZero;
        [self->_sugBox addSublayer:self->_sugHeading];
        self->_sugHighlight = [CALayer layer];
        self->_sugHighlight.cornerRadius = U(10);
        self->_sugHighlight.backgroundColor = t.focus.CGColor;
        self->_sugHighlight.opacity = 0;
        [self->_sugBox addSublayer:self->_sugHighlight];

        self->_hint = [SFLabel labelWithFont:[t regular:26] color:t.textDim];
        [self->_hint sizeToFitWidth:size.width - 2 * U(kX)];
        self->_hint.position = CGPointMake(U(kX), U(kGridY) + 5 * U(kKeyH + kGap) + U(30));
        [L addSublayer:self->_hint];
    });
    _laidOut = YES;
    [self updateText];
    [self renderSuggestions];
    [self updateFocus:NO];
}

- (void)willAppear {
    [super willAppear];
    [self refreshSuggestions];   // "Zuletzt gesucht" kann sich geändert haben
}

#pragma mark Text

- (void)setText:(NSString *)text {
    [_text setString:text ?: @""];
    [self updateText];
    [self scheduleSuggestions];
}

- (void)updateText {
    if (!_laidOut) return;
    SFTheme *t = self.theme;
    CGFloat maxW = _field.bounds.size.width - U(80);
    NSString *shown = _text.length ? [_text copy] : self.placeholder;
    NSDictionary *attrs = @{NSFontAttributeName: _fieldText.font};
    // Langer Text: Anfang abschneiden, Ende (Einfügestelle) bleibt sichtbar
    if (_text.length) {
        while (shown.length > 1 && [[@"…" stringByAppendingString:shown] sizeWithAttributes:attrs].width > maxW - U(20))
            shown = [shown substringFromIndex:[shown rangeOfComposedCharacterSequenceAtIndex:0].length];
        if (shown.length < _text.length) shown = [@"…" stringByAppendingString:shown];
    }
    // Leerzeichen am Ende sichtbar machen (sonst springt der Cursor nicht)
    CGFloat w = _text.length ? [[shown stringByReplacingOccurrencesOfString:@" " withString:@"\u00a0"] sizeWithAttributes:attrs].width : 0;
    SFNoAnimate(^{
        self->_fieldText.text = shown;
        self->_fieldText.color = self->_text.length ? t.text : t.textDim;
        CGFloat ch = U(70);
        // leer: Cursor vorne, Platzhalter dahinter
        self->_fieldText.position = CGPointMake(self->_text.length ? U(40) : U(60), self->_fieldText.position.y);
        self->_caret.frame = CGRectMake(self->_text.length ? U(40) + ceil(w) + U(4) : U(40), (U(kFieldH) - ch) / 2, U(5), ch);
    });
    if (![_caret animationForKey:@"blink"]) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
        a.fromValue = @1; a.toValue = @0.1;
        a.duration = 0.55; a.autoreverses = YES; a.repeatCount = HUGE_VALF;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_caret addAnimation:a forKey:@"blink"];
    }
}

- (void)insert:(NSString *)s {
    if (_text.length >= kMaxLen) { [self bump:YES]; return; }
    if ([s isEqualToString:@" "] && (!_text.length || [_text hasSuffix:@" "])) { [self bump:YES]; return; }
    [_text appendString:s];
    [self updateText];
    [self scheduleSuggestions];
}

- (void)deleteBackward {
    if (!_text.length) { [self bump:YES]; return; }
    [_text deleteCharactersInRange:[_text rangeOfComposedCharacterSequenceAtIndex:_text.length - 1]];
    [self updateText];
    [self scheduleSuggestions];
}

- (void)clearAll {
    if (!_text.length) return;
    [_text setString:@""];
    [self updateText];
    [self scheduleSuggestions];
}

- (void)submit:(NSString *)s {
    NSString *q = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) { [self bump:YES]; [self.navigator toast:@"Bitte zuerst etwas eingeben."]; return; }
    if (_completion) _completion(q);
}

#pragma mark Vorschläge

- (void)refreshSuggestions { [self scheduleSuggestionsAfter:0]; }
- (void)scheduleSuggestions { [self scheduleSuggestionsAfter:0.25]; }

// Entprellt: nur die letzte Anfrage zählt (Tippen erzeugt sonst eine Anfrage je Taste)
- (void)scheduleSuggestionsAfter:(NSTimeInterval)delay {
    if (!self.suggestionProvider) return;
    NSUInteger seq = ++_sugSeq;
    NSString *q = [_text copy];
    __weak SFKeyboardScreen *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SFKeyboardScreen *s = ws;
        if (!s || seq != s->_sugSeq) return;
        s.suggestionProvider(q, ^(NSString *heading, NSArray *list) {
            SFMain(^{
                SFKeyboardScreen *s2 = ws;
                if (!s2 || seq != s2->_sugSeq) return;
                s2->_sugHeadingText = heading;
                s2->_suggestions = list.count > kMaxSug ? [list subarrayWithRange:NSMakeRange(0, kMaxSug)] : (list ?: @[]);
                [s2 renderSuggestions];
            });
        });
    });
}

- (void)renderSuggestions {
    if (!_laidOut) return;
    SFTheme *t = self.theme;
    for (CALayer *r in _sugRows) [r removeFromSuperlayer];
    [_sugRows removeAllObjects];
    SFNoAnimate(^{
        self->_sugHeading.text = self->_suggestions.count ? self->_sugHeadingText : @"";
        CGFloat w = self->_sugBox.bounds.size.width;
        for (NSUInteger i = 0; i < self->_suggestions.count; i++) {
            CALayer *row = [CALayer layer];
            row.frame = CGRectMake(0, U(50) + i * U(kSugRowH + kSugGap), w, U(kSugRowH));
            SFLabel *l = [SFLabel labelWithFont:[t medium:32] color:t.text];
            l.text = self->_suggestions[i];
            CGFloat lh = [l sizeToFitWidth:w - U(48)];
            l.position = CGPointMake(U(24), (U(kSugRowH) - lh) / 2);
            [row addSublayer:l];
            [self->_sugBox addSublayer:row];
            [self->_sugRows addObject:row];
        }
    });
    if (_area == 1) {
        if (!_suggestions.count) { _area = 0; }
        else _sug = MIN(_sug, (NSInteger)_suggestions.count - 1);
    }
    [self updateFocus:NO];
}

#pragma mark Fokus

- (SFKbKey *)focusedKey { return _rows[_row][_key]; }

- (NSInteger)keyInRow:(NSInteger)r forCol:(NSInteger)col {
    NSArray *keys = _rows[r];
    for (NSUInteger i = 0; i < keys.count; i++) {
        SFKbKey *k = keys[i];
        if (col >= k.col && col < k.col + k.span) return i;
    }
    return keys.count - 1;
}

- (void)updateFocus:(BOOL)anim {
    if (!_laidOut) return;
    SFTheme *t = self.theme;
    NSColor *on = [self onFocus], *keyBg = [self keyColor];
    BOOL grid = _area == 0;
    void (^ch)(void) = ^{
        for (NSUInteger r = 0; r < self->_rows.count; r++) {
            NSArray *keys = self->_rows[r];
            for (NSUInteger i = 0; i < keys.count; i++) {
                SFKbKey *k = keys[i];
                BOOL f = grid && (NSInteger)r == self->_row && (NSInteger)i == self->_key;
                BOOL submit = k.kind == SFKbSubmit;
                // „Suchen“ unfokussiert nur als Akzent-Umriss: sonst zwei gleich aussehende Tasten (Fokus unklar)
                k.bg.backgroundColor = (f ? t.focus : keyBg).CGColor;
                k.bg.borderColor = t.accent.CGColor;
                k.bg.borderWidth = (submit && !f) ? U(3) : 0;
                k.text.color = f ? on : (submit ? t.accent : t.text);
                k.bg.transform = f ? CATransform3DMakeScale(1.1, 1.1, 1) : CATransform3DIdentity;
                k.bg.zPosition = f ? 10 : 0;
                k.bg.shadowOpacity = f ? 0.45 : 0;
            }
        }
        BOOL sf = !grid && self->_sug < (NSInteger)self->_sugRows.count;
        self->_sugHighlight.opacity = sf ? 1 : 0;
        if (sf) self->_sugHighlight.frame = [self->_sugRows[self->_sug] frame];
        for (NSUInteger i = 0; i < self->_sugRows.count; i++) {
            SFLabel *l = [[self->_sugRows[i] sublayers] firstObject];
            l.color = (sf && (NSInteger)i == self->_sug) ? on : t.text;
        }
        // „Rechts halten“ springt zu den Vorschlägen, sobald es welche gibt (ein Griff statt bis zu 10× rechts)
        self->_hint.text = grid
            ? (self->_suggestions.count
               ? @"Play/Pause: Zeichen löschen   ·   Mitte halten: alles löschen   ·   Rechts halten: zu den Vorschlägen   ·   MENU: zurück"
               : @"Play/Pause: Zeichen löschen   ·   Mitte halten: alles löschen   ·   Rechts halten: zu „Suchen“   ·   MENU: zurück")
            : @"Mitte: sofort suchen   ·   Mitte halten: in die Textzeile übernehmen   ·   Links: zur Tastatur";
    };
    if (anim) SFAnimate(0.14, ch); else SFNoAnimate(ch);
}

- (void)bump:(BOOL)horizontal {
    CALayer *l = _area == 0 ? [self focusedKey].bg : _sugHighlight;
    if (!l) return;
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:horizontal ? @"position.x" : @"position.y"];
    CGFloat base = horizontal ? l.position.x : l.position.y, d = U(8);
    a.values = @[@(base), @(base + d), @(base - d * 0.4), @(base)];
    a.duration = 0.22;
    [l addAnimation:a forKey:@"bump"];
}

- (void)moveGridRow:(NSInteger)dr {
    NSInteger r = _row + dr;
    if (r < 0 || r >= (NSInteger)_rows.count) { [self bump:NO]; return; }
    _row = r;
    _key = [self keyInRow:r forCol:_wantCol];
    [self updateFocus:YES];
}

- (void)moveGridKey:(NSInteger)dk {
    NSInteger k = _key + dk;
    NSArray *keys = _rows[_row];
    if (k < 0) { [self bump:YES]; return; }   // linker Rand: Anschlag
    if (k >= (NSInteger)keys.count) {         // rechter Rand: in die Vorschläge
        if (!_suggestions.count) { [self bump:YES]; return; }
        CGFloat ky = [self focusedKey].bg.frame.origin.y + U(kKeyH) / 2 - (_sugBox.frame.origin.y + U(50));
        _sug = MAX(0, MIN((NSInteger)_suggestions.count - 1, (NSInteger)floor(ky / U(kSugRowH + kSugGap))));
        _area = 1; _retRow = -1;
        [self updateFocus:YES];
        return;
    }
    _key = k;
    _wantCol = [keys[k] col];
    [self updateFocus:YES];
}

- (void)leaveSuggestions {
    if (_retRow >= 0 && _retRow < (NSInteger)_rows.count && _retKey < (NSInteger)[_rows[_retRow] count]) {
        _row = _retRow; _key = _retKey; _wantCol = [_rows[_row][_key] col];
        _retRow = -1; _area = 0;
        [self updateFocus:YES];
        return;
    }
    CGFloat sy = _sugBox.frame.origin.y + U(50) + _sug * U(kSugRowH + kSugGap) + U(kSugRowH) / 2 - U(kGridY);
    _row = MAX(0, MIN((NSInteger)_rows.count - 1, (NSInteger)floor(sy / U(kKeyH + kGap))));
    _key = [_rows[_row] count] - 1;
    _wantCol = [_rows[_row][_key] col];
    _area = 0;
    [self updateFocus:YES];
}

- (void)focusKind:(SFKbKind)kind orChar:(NSString *)c {
    for (NSUInteger r = 0; r < _rows.count; r++)
        for (NSUInteger i = 0; i < [_rows[r] count]; i++) {
            SFKbKey *k = _rows[r][i];
            if ((c && [k.label isEqualToString:c]) || (!c && k.kind == kind)) {
                _area = 0; _row = r; _key = i; _wantCol = k.col;
                [self updateFocus:YES];
                return;
            }
        }
}

#pragma mark Eingabe

- (void)activateKey:(SFKbKey *)k {
    switch (k.kind) {
        case SFKbChar: [self insert:k.label]; break;
        case SFKbSpace: [self insert:@" "]; break;
        case SFKbDelete: [self deleteBackward]; break;
        case SFKbSubmit: [self submit:_text]; break;
        case SFKbLayout: {   // ABC <-> QWERTZ, gemerkt; Fokus bleibt auf dem Umschalter
            BOOL q = [[[SFStore shared] setting:@"keyboard.layout"] isEqualToString:@"qwertz"];
            [[SFStore shared] setSetting:q ? @"abc" : @"qwertz" forKey:@"keyboard.layout"];
            [self layoutForSize:self.size];
            [self focusKind:SFKbLayout orChar:nil];
            return;
        }
    }
    // kurzes "Drück"-Feedback
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    a.fromValue = @0.95; a.toValue = @1.1; a.duration = 0.12;
    [k.bg addAnimation:a forKey:@"press"];
}

- (BOOL)handleKey:(SFKey)key {
    if (!_laidOut) return key != SFKeyMenu && key != SFKeyMenuHold;
    BOOL grid = _area == 0;
    switch (key) {
        case SFKeyUp: case SFKeyUpHold:
            if (grid) [self moveGridRow:-1];
            else if (_sug > 0) { _sug--; [self updateFocus:YES]; } else [self bump:NO];
            return YES;
        case SFKeyDown: case SFKeyDownHold:
            if (grid) [self moveGridRow:1];
            else if (_sug + 1 < (NSInteger)_suggestions.count) { _sug++; [self updateFocus:YES]; } else [self bump:NO];
            return YES;
        case SFKeyLeft:
            if (grid) [self moveGridKey:-1]; else [self leaveSuggestions];
            return YES;
        case SFKeyRight:
            if (grid) [self moveGridKey:1]; else [self bump:YES];
            return YES;
        case SFKeySelect:
            if (grid) [self activateKey:[self focusedKey]];
            else if (_sug < (NSInteger)_suggestions.count) { [self setText:_suggestions[_sug]]; [self submit:_suggestions[_sug]]; }
            return YES;
        case SFKeySelectHold:
            if (grid) [self clearAll];
            else if (_sug < (NSInteger)_suggestions.count) {   // übernehmen und weitertippen
                NSString *s = _suggestions[_sug];
                [self setText:[s hasSuffix:@" "] ? s : [s stringByAppendingString:@" "]];
                [self leaveSuggestions];
            }
            return YES;
        case SFKeyPlayPause: [self deleteBackward]; return YES;
        case SFKeyNext:
            if (grid && _suggestions.count) { _retRow = _row; _retKey = _key; _sug = 0; _area = 1; [self updateFocus:YES]; }
            else if (grid) [self focusKind:SFKbSubmit orChar:nil];
            else [self bump:YES];
            return YES;
        case SFKeyPrev: [self focusKind:SFKbChar orChar:@"a"]; return YES;
        case SFKeyMenu:
            if (self.onCancel) self.onCancel();
            return NO;   // Navigator: zurück
        default:
            return NO;
    }
}
@end
