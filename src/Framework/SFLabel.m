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

// A label's text drawn into a picture of `size` points at `scale`: the one way labels draw, on the
// main thread (display) or on the text queue (SFLabelLook). Row 0 at the top - CA shows a contents
// image upright in the flipped layer tree.
static CGImageRef RenderText(NSAttributedString *text, CGSize size, CGFloat scale) CF_RETURNS_RETAINED;
static CGImageRef RenderText(NSAttributedString *text, CGSize size, CGFloat scale) {
    size_t pw = (size_t)ceil(size.width * scale), ph = (size_t)ceil(size.height * scale);
    if (!text.length || pw == 0 || ph == 0) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, pw, ph, 8, 0, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextTranslateCTM(ctx, 0, ph);
    CGContextScaleCTM(ctx, scale, -scale);   // flipped: y down from the top, like the layer tree
    NSGraphicsContext *old = [NSGraphicsContext currentContext];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:ctx flipped:YES]];
    CGContextSetShouldSmoothFonts(ctx, false);
    CGContextSetShouldAntialias(ctx, true);
    NSStringDrawingOptions o = NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine;
    [text drawWithRect:NSMakeRect(0, 0, size.width, size.height) options:o];
    [NSGraphicsContext setCurrentContext:old];
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

@interface SFLabelLook ()
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSInteger maxLines;
@property (nonatomic) CGSize size;
@property (nonatomic) CGFloat scale;
@property (nonatomic, copy) NSAttributedString *attributed;
@property (nonatomic, strong) id image;   // CGImage, once rendered (nil: empty text)
@property (nonatomic) BOOL rendered;
@end

@implementation SFLabelLook
+ (void)render:(NSArray *)looks done:(dispatch_block_t)done {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("sofa.text", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    });
    NSArray *todo = [looks copy];
    dispatch_async(queue, ^{
        for (SFLabelLook *l in todo) @autoreleasepool {
            if (l.rendered) continue;
            l.image = (__bridge_transfer id)RenderText(l.attributed, l.size, l.scale);
            l.rendered = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(); });
    });
}
@end

@implementation SFLabel {
    SFLabelLook *_shown;   // applied look: display keeps its picture while nothing else changed
}

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

- (NSAttributedString *)attributed { return [self attributedText:self.text maxLines:self.maxLines]; }

- (NSAttributedString *)attributedText:(NSString *)text maxLines:(NSInteger)maxLines {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = self.alignment;
    ps.lineBreakMode = maxLines == 1 ? NSLineBreakByTruncatingTail : NSLineBreakByWordWrapping;
    ps.lineSpacing = self.lineSpacing;
    NSMutableDictionary *a = [@{NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:U(24)],
                                NSForegroundColorAttributeName: self.color ?: [NSColor whiteColor],
                                NSParagraphStyleAttributeName: ps} mutableCopy];
    if (self.shadow) {
        // one shared instance: NSShadow compares by identity, and display compares attributed strings
        static NSShadow *sh;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sh = [NSShadow new];
            sh.shadowColor = [NSColor colorWithDeviceWhite:0 alpha:0.75];
            sh.shadowBlurRadius = U(6);
            sh.shadowOffset = NSMakeSize(0, -U(1));
        });
        a[NSShadowAttributeName] = sh;
    }
    NSMutableAttributedString *r = [[NSMutableAttributedString alloc] initWithString:text ?: @"" attributes:a];
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

- (CGFloat)heightForText:(NSString *)text maxLines:(NSInteger)maxLines width:(CGFloat)w {
    if (!text.length) return [self lineHeight];   // room for text set later
    NSRect r = [[self attributedText:text maxLines:maxLines] boundingRectWithSize:NSMakeSize(w, CGFLOAT_MAX)
                                                                          options:NSStringDrawingUsesLineFragmentOrigin];
    CGFloat h = ceil(r.size.height) + ceil(fabs(self.font.descender) * 0.5);  // do not clip descenders
    if (maxLines > 0) h = MIN(h, [self lineHeight] * maxLines + ceil(fabs(self.font.descender) * 0.5));
    if (self.shadow) h += U(4);
    return h;
}

- (CGFloat)sizeToFitWidth:(CGFloat)w {
    CGFloat h = [self heightForText:self.text maxLines:self.maxLines width:w];
    CGRect b = self.bounds; b.size = CGSizeMake(w, h);
    self.bounds = b;
    return h;
}

- (SFLabelLook *)lookForText:(NSString *)text maxLines:(NSInteger)maxLines width:(CGFloat)w {
    SFLabelLook *l = [SFLabelLook new];
    l.text = text ?: @"";
    l.maxLines = maxLines;
    l.size = CGSizeMake(w, [self heightForText:text maxLines:maxLines width:w]);
    l.scale = self.contentsScale;
    l.attributed = [self attributedText:text maxLines:maxLines];
    return l;
}

- (void)applyLook:(SFLabelLook *)look {
    _text = [look.text copy];
    _maxLines = look.maxLines;
    _shown = look;
    CGRect b = self.bounds; b.size = look.size;
    self.bounds = b;
    [self setNeedsDisplay];   // display: shows the look's picture, nothing drawn here
}

// Draws through RenderText - unless an applied look still matches what the label would draw.
- (void)display {
    SFLabelLook *l = _shown;
    if (l && l.rendered && CGSizeEqualToSize(l.size, self.bounds.size) && l.scale == self.contentsScale
        && [l.attributed isEqualToAttributedString:[self attributed]]) {
        self.contents = l.image;
        return;
    }
    _shown = nil;
    self.contents = (__bridge_transfer id)RenderText([self attributed], self.bounds.size, self.contentsScale);
}
@end
