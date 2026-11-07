#import "SFLayers.h"

#pragma mark - SFLabel

// Middle dot "·" (the separator of SFDotJoin) with lopsided metrics in some fonts: GillSans (ARD
// theme) draws it at the right edge of its advance (bearings 25.7 / -2.8 at 100 pt) -> a wide
// gap before the dot, none after it. Returns the shift (fraction of the point size) that centres
// its ink; 0 for fonts that are fine. Measured once per font.
static CGFloat SFDotShift(NSFont *font) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary new];
    NSNumber *c = cache[font.fontName];
    if (c) return c.doubleValue;
    NSFont *f = [NSFont fontWithName:font.fontName size:100] ?: font;
    NSAttributedString *a = [[NSAttributedString alloc] initWithString:@"\u00B7" attributes:@{NSFontAttributeName: f}];
    NSRect ink = [a boundingRectWithSize:NSMakeSize(1000, 1000) options:NSStringDrawingUsesDeviceMetrics];
    CGFloat left = ink.origin.x, right = a.size.width - NSMaxX(ink);
    CGFloat shift = fabs(left - right) > 4 ? (left - right) / 2 / 100 : 0;   // tolerate small asymmetries
    cache[font.fontName] = @(shift);
    return shift;
}

// The screen's backing scale for label contents. [NSScreen mainScreen] asks the window server
// (a mach round trip) - once per label it made new rows stall (88 ms in -[SFLabel init] while a row
// built its tiles, hitch monitor 2026-11-07). Asked once, again when the screens change.
static CGFloat SFBackingScale(void) {
    static CGFloat scale;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void (^read)(NSNotification *) = ^(NSNotification *n) { scale = [NSScreen mainScreen].backingScaleFactor ?: 1; };
        read(nil);
        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                                          object:nil queue:[NSOperationQueue mainQueue] usingBlock:read];
    });
    return scale;
}

@implementation SFLabel

+ (instancetype)labelWithFont:(NSFont *)f color:(NSColor *)c {
    SFLabel *l = [self layer];
    l.font = f; l.color = c; l.maxLines = 1;
    return l;
}

- (instancetype)init {
    if ((self = [super init])) {
        self.contentsScale = SFBackingScale();
        self.needsDisplayOnBoundsChange = YES;
        self.anchorPoint = CGPointZero;
        _maxLines = 1;
        _alignment = NSLeftTextAlignment;
    }
    return self;
}
- (id<CAAction>)actionForKey:(NSString *)event {
    if ([event isEqualToString:@"contents"]) return nil;
    return [super actionForKey:event];
}

- (void)setText:(NSString *)t { if (![_text isEqualToString:t]) { _text = [t copy]; [self setNeedsDisplay]; } }
- (void)setFont:(NSFont *)f { _font = f; [self setNeedsDisplay]; }
- (void)setColor:(NSColor *)c { _color = c; [self setNeedsDisplay]; }
- (void)setMaxLines:(NSInteger)m { _maxLines = m; [self setNeedsDisplay]; }

- (NSAttributedString *)attributed {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = self.alignment;
    ps.lineBreakMode = self.maxLines == 1 ? NSLineBreakByTruncatingTail : NSLineBreakByWordWrapping;
    ps.lineSpacing = self.lineSpacing;
    NSMutableDictionary *a = [@{NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:U(24)],
                                NSForegroundColorAttributeName: self.color ?: [NSColor whiteColor],
                                NSParagraphStyleAttributeName: ps} mutableCopy];
    if (self.shadow) {
        NSShadow *sh = [NSShadow new];
        sh.shadowColor = [NSColor colorWithDeviceWhite:0 alpha:0.75];
        sh.shadowBlurRadius = U(6);
        sh.shadowOffset = NSMakeSize(0, -U(1));
        a[NSShadowAttributeName] = sh;
    }
    NSMutableAttributedString *r = [[NSMutableAttributedString alloc] initWithString:self.text ?: @"" attributes:a];
    CGFloat shift = SFDotShift(a[NSFontAttributeName]) * [a[NSFontAttributeName] pointSize];
    if (shift != 0) {   // centre a lopsided "·": pull it left by `shift`, give the space back after it
        NSString *t = r.string;
        for (NSUInteger i = 1; i < t.length; i++) if ([t characterAtIndex:i] == 0x00B7) {
            [r addAttribute:NSKernAttributeName value:@(-shift) range:NSMakeRange(i - 1, 1)];
            [r addAttribute:NSKernAttributeName value:@(shift) range:NSMakeRange(i, 1)];
        }
    }
    return r;
}

- (CGFloat)lineHeight {
    // same measuring method as when drawing (line fragment), otherwise line 2 does not fit
    NSDictionary *a = @{NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:U(24)]};
    NSRect r = [@"ÄÖgy" boundingRectWithSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin attributes:a];
    return ceil(r.size.height) + self.lineSpacing;
}

- (CGFloat)sizeToFitWidth:(CGFloat)w {
    CGFloat h;
    if (!self.text.length) h = [self lineHeight];   // room for text set later
    else {
        NSRect r = [[self attributed] boundingRectWithSize:NSMakeSize(w, CGFLOAT_MAX)
                                                  options:NSStringDrawingUsesLineFragmentOrigin];
        h = ceil(r.size.height) + ceil(fabs(self.font.descender) * 0.5);  // do not clip descenders
        if (self.maxLines > 0) h = MIN(h, [self lineHeight] * self.maxLines + ceil(fabs(self.font.descender) * 0.5));
        if (self.shadow) h += U(4);
    }
    CGRect b = self.bounds; b.size = CGSizeMake(w, h);
    self.bounds = b;
    return h;
}

- (void)drawInContext:(CGContextRef)ctx {
    if (!self.text.length) return;
    NSGraphicsContext *old = [NSGraphicsContext currentContext];
    // If the layer is in a geometryFlipped tree, CA provides a flipped context.
    NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithGraphicsPort:ctx flipped:self.contentsAreFlipped];
    [NSGraphicsContext setCurrentContext:g];
    CGContextSaveGState(ctx);
    CGContextSetShouldSmoothFonts(ctx, false);
    CGContextSetShouldAntialias(ctx, true);
    NSRect r = NSMakeRect(0, 0, self.bounds.size.width, self.bounds.size.height);
    NSStringDrawingOptions o = NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine;
    [[self attributed] drawWithRect:r options:o];
    CGContextRestoreGState(ctx);
    [NSGraphicsContext setCurrentContext:old];
}
@end
