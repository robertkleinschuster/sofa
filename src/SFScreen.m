#import "SFScreen.h"
#import "SFLayers.h"
#import "SFVolume.h"

@implementation SFScreen {
    CALayer *_layer;
}
- (instancetype)initWithTheme:(SFTheme *)theme {
    if ((self = [super init])) {
        _theme = theme ?: [SFTheme themeNamed:@"home"];
        _layer = [CALayer layer];
        _layer.anchorPoint = CGPointMake(0.5, 0.5);
        _layer.masksToBounds = YES;
    }
    return self;
}
- (instancetype)init { return [self initWithTheme:nil]; }
- (CALayer *)layer { return _layer; }
- (CGSize)size { return _layer.bounds.size; }
- (void)layoutForSize:(CGSize)size {}
- (void)willAppear {}
- (void)didAppear {}
- (void)willDisappear {}
- (BOOL)handleKey:(SFKey)key { return NO; }
- (BOOL)wantsCursorHidden { return YES; }
- (BOOL)isOpaque { return YES; }
- (CGFloat)toastCenterFromBottom { return U(110); }
@end

NSCursor *SFBlankCursor(void) {
    static NSCursor *c;
    if (!c) {
        NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
        [img lockFocus]; [[NSColor clearColor] set]; NSRectFill(NSMakeRect(0, 0, 16, 16)); [img unlockFocus];
        c = [[NSCursor alloc] initWithImage:img hotSpot:NSZeroPoint];
    }
    return c;
}

@implementation SFNavigator {
    NSMutableArray *_stack;
    CALayer *_root;
    CALayer *_toastLayer;
    SFLabel *_toastLabel;
    NSUInteger _toastSeq;
    CGSize _laidOut;
    CALayer *_volHUD, *_volFill;
    SFLabel *_volLabel;
    NSUInteger _volSeq;
}

// Kein Mauszeiger in der TV-Oberfläche (siehe main.m hideCursor)
- (void)resetCursorRects { if (!SFDevMode) [self addCursorRect:self.bounds cursor:SFBlankCursor()]; }

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _stack = [NSMutableArray new];
        _root = [CALayer layer];
        _root.geometryFlipped = YES;
        _root.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        self.layer = _root;
        self.wantsLayer = YES;   // layer-hosting
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    }
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }
- (NSArray *)stack { return [_stack copy]; }
- (SFScreen *)top { return _stack.lastObject; }

- (void)prepare:(SFScreen *)s {
    s.navigator = self;
    SFNoAnimate(^{
        s.layer.bounds = CGRectMake(0, 0, self.bounds.size.width, self.bounds.size.height);
        s.layer.position = CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2);
    });
    [s layoutForSize:self.bounds.size];
}

- (void)setFrameSize:(NSSize)n {
    [super setFrameSize:n];
    if (CGSizeEqualToSize(_laidOut, n)) return;
    _laidOut = n;
    for (SFScreen *s in _stack) [self prepare:s];
}

- (void)push:(SFScreen *)s {
    SFScreen *old = self.top;
    [self prepare:s];
    // Nur ein deckender Bildschirm verdrängt den darunter. Ein Overlay (Menü, Dialog) lässt ihn
    // weiterlaufen – z.B. das Video unter „Ton & Untertitel“ (vorher: Wiedergabe abgebaut).
    if (s.isOpaque) [old willDisappear];
    [s willAppear];
    [_stack addObject:s];
    SFNoAnimate(^{
        s.layer.opacity = 0;
        s.layer.transform = CATransform3DMakeScale(1.03, 1.03, 1);
        if (self->_toastLayer) [self->_root insertSublayer:s.layer below:self->_toastLayer];
        else [self->_root addSublayer:s.layer];
    });
    SFAnimate(0.32, ^{
        s.layer.opacity = 1;
        s.layer.transform = CATransform3DIdentity;
        if (old && s.isOpaque) {
            old.layer.opacity = 0;
            old.layer.transform = CATransform3DMakeScale(0.97, 0.97, 1);
        }
    });
    [s didAppear];
    if (old && s.isOpaque) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.top != old && old.layer.opacity == 0) SFNoAnimate(^{ [old.layer removeFromSuperlayer]; });
        });
    }
}

- (void)pop {
    if (_stack.count < 2) return;
    SFScreen *s = self.top;
    [_stack removeLastObject];
    SFScreen *under = self.top;
    [s willDisappear];
    [under willAppear];
    SFNoAnimate(^{
        if (!under.layer.superlayer) [self->_root insertSublayer:under.layer below:s.layer];
    });
    SFAnimate(0.28, ^{
        s.layer.opacity = 0;
        s.layer.transform = CATransform3DMakeScale(1.03, 1.03, 1);
        under.layer.opacity = 1;
        under.layer.transform = CATransform3DIdentity;
    });
    [under didAppear];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SFNoAnimate(^{ [s.layer removeFromSuperlayer]; });
    });
}

- (void)popToRoot {
    while (_stack.count > 2) {
        SFScreen *s = self.top;
        [s willDisappear];
        [_stack removeLastObject];
        SFNoAnimate(^{ [s.layer removeFromSuperlayer]; });
    }
    [self pop];
}

- (void)replaceTop:(SFScreen *)s {
    SFScreen *old = self.top;
    if (!old) { [self push:s]; return; }
    [old willDisappear];
    [_stack removeLastObject];
    [self prepare:s];
    [s willAppear];
    [_stack addObject:s];
    SFNoAnimate(^{
        s.layer.opacity = 0;
        [self->_root insertSublayer:s.layer above:old.layer];
    });
    SFAnimate(0.25, ^{ s.layer.opacity = 1; });
    [s didAppear];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SFNoAnimate(^{ [old.layer removeFromSuperlayer]; });
    });
}

- (void)sendKey:(SFKey)key {
    _lastInput = [NSDate timeIntervalSinceReferenceDate];
    SFScreen *t = self.top;
    if (!t) return;
    if ([t handleKey:key]) return;
    if (key == SFKeyMenu && self.stack.count <= 1) { if (self.rootMenuHandler) self.rootMenuHandler(); }
    else if (key == SFKeyMenu) [self pop];
    else if (key == SFKeyMenuHold) [self popToRoot];
}

#pragma mark Keyboard

- (void)keyDown:(NSEvent *)e {
    NSString *ch = e.charactersIgnoringModifiers.lowercaseString;
    switch (e.keyCode) {
        case 126: [self sendKey:SFKeyUp]; return;
        case 125: [self sendKey:SFKeyDown]; return;
        case 123: [self sendKey:SFKeyLeft]; return;
        case 124: [self sendKey:SFKeyRight]; return;
        case 36: case 76: if (!e.isARepeat) [self sendKey:SFKeySelect]; return;
        case 53: case 51: if (!e.isARepeat) [self sendKey:SFKeyMenu]; return;
        case 49: if (!e.isARepeat) [self sendKey:SFKeyPlayPause]; return;
    }
    if ([ch isEqualToString:@"i"] || [ch isEqualToString:@"c"]) { [self sendKey:SFKeySelectHold]; return; }
    if ([ch isEqualToString:@"h"]) { [self sendKey:SFKeyMenuHold]; return; }
    if ([ch isEqualToString:@"."]) { [self sendKey:SFKeyNext]; return; }
    if ([ch isEqualToString:@","]) { [self sendKey:SFKeyPrev]; return; }
    if ([ch isEqualToString:@"q"] && (e.modifierFlags & NSCommandKeyMask)) { [NSApp terminate:nil]; return; }
    [super keyDown:e];
}

#pragma mark Lautstärke

- (void)volumeStep:(int)dir {
    // Dev-Instanzen ändern NIE die echte Systemlautstärke (nur Anzeige simulieren)
    static float devVol = 0.5f;
    float v;
    if (SFDevMode) { devVol = MAX(0, MIN(1, roundf(devVol * 16 + dir) / 16)); v = devVol; }
    else { [SFVolume step:dir]; v = [SFVolume volume]; }
    if (v < 0) { [self toast:@"Lautstärke ist für dieses Ausgabegerät nicht regelbar"]; return; }
    CGSize sz = self.bounds.size;
    if (!_volHUD) {
        _volHUD = [CALayer layer];
        _volHUD.bounds = CGRectMake(0, 0, U(520), U(110));
        _volHUD.cornerRadius = U(20);
        _volHUD.backgroundColor = [NSColor colorWithDeviceWhite:0.08 alpha:0.9].CGColor;
        _volHUD.zPosition = 1001;
        CALayer *track = [CALayer layer];
        track.frame = CGRectMake(U(150), U(48), U(330), U(14));
        track.cornerRadius = U(7);
        track.backgroundColor = [NSColor colorWithDeviceWhite:1 alpha:0.22].CGColor;
        track.masksToBounds = YES;
        _volFill = [CALayer layer];
        _volFill.anchorPoint = CGPointZero;
        _volFill.backgroundColor = CGColorGetConstantColor(kCGColorWhite);
        [track addSublayer:_volFill];
        [_volHUD addSublayer:track];
        _volLabel = [SFLabel labelWithFont:[NSFont fontWithName:@"HelveticaNeue-Medium" size:U(30)] color:[NSColor whiteColor]];
        [_volLabel sizeToFitWidth:U(110)];
        _volLabel.position = CGPointMake(U(34), U(34));
        [_volHUD addSublayer:_volLabel];
        SFNoAnimate(^{ self->_volHUD.opacity = 0; [self->_root addSublayer:self->_volHUD]; });
    }
    BOOL muted = (!SFDevMode && [SFVolume muted]) || v <= 0.001;
    SFNoAnimate(^{
        self->_volHUD.position = CGPointMake(sz.width - U(96) - U(260), U(100));
        self->_volLabel.text = muted ? @"Stumm" : [NSString stringWithFormat:@"%d", (int)lroundf(v * 16)];
    });
    SFAnimate(0.12, ^{
        self->_volFill.frame = CGRectMake(0, 0, U(330) * (muted ? 0 : v), U(14));
        self->_volHUD.opacity = 1;
    });
    NSUInteger seq = ++_volSeq;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (seq == self->_volSeq) SFAnimate(0.4, ^{ self->_volHUD.opacity = 0; });
    });
}

#pragma mark Toast

- (void)toast:(NSString *)text {
    CGSize sz = self.bounds.size;
    if (!_toastLayer) {
        _toastLayer = [CALayer layer];
        _toastLayer.backgroundColor = [NSColor colorWithDeviceWhite:0.08 alpha:0.92].CGColor;
        _toastLayer.cornerRadius = U(14);
        _toastLayer.zPosition = 1000;
        _toastLayer.shadowOpacity = 0.5;
        _toastLayer.shadowRadius = U(20);
        _toastLabel = [SFLabel labelWithFont:[NSFont fontWithName:@"HelveticaNeue-Medium" size:U(26)]
                                       color:[NSColor whiteColor]];
        _toastLabel.maxLines = 2;
        _toastLabel.alignment = NSCenterTextAlignment;
        [_toastLayer addSublayer:_toastLabel];
        SFNoAnimate(^{ self->_toastLayer.opacity = 0; [self->_root addSublayer:self->_toastLayer]; });
    }
    NSUInteger seq = ++_toastSeq;
    SFNoAnimate(^{
        self->_toastLabel.text = text;
        // Breite am Text ausrichten (kurze Hinweise als kompakte Pille), lange umbrechen
        CGFloat maxW = MIN(U(1100), sz.width - U(200));
        CGFloat tw = ceil([text sizeWithAttributes:@{NSFontAttributeName: self->_toastLabel.font}].width);
        CGFloat w = MIN(maxW, MAX(U(320), tw + U(96)));
        CGFloat h = [self->_toastLabel sizeToFitWidth:w - U(64)];
        self->_toastLayer.bounds = CGRectMake(0, 0, w, h + U(44));
        CGFloat fromBottom = self.top ? [self.top toastCenterFromBottom] : U(110);
        self->_toastLayer.position = CGPointMake(sz.width / 2, sz.height - fromBottom);
        self->_toastLabel.position = CGPointMake(U(32), U(22));   // Label = Breite − 2·32
    });
    SFAnimate(0.25, ^{ self->_toastLayer.opacity = 1; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (seq == self->_toastSeq) SFAnimate(0.4, ^{ self->_toastLayer.opacity = 0; });
    });
}
@end
