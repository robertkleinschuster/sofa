#import "SFTheme.h"

@implementation SFTheme

static NSFont *fontOr(NSString *name, CGFloat size, NSString *fallback) {
    NSFont *f = [NSFont fontWithName:name size:U(size)];
    if (!f && fallback) f = [NSFont fontWithName:fallback size:U(size)];
    return f ?: [NSFont systemFontOfSize:U(size)];
}
- (NSFont *)regular:(CGFloat)s { return fontOr(self.fontRegular, s, @"HelveticaNeue"); }
- (NSFont *)medium:(CGFloat)s  { return fontOr(self.fontMedium, s, @"HelveticaNeue-Medium"); }
- (NSFont *)bold:(CGFloat)s    { return fontOr(self.fontBold, s, @"HelveticaNeue-Bold"); }
- (NSFont *)wordmarkFont:(CGFloat)s { return fontOr(self.fontWordmark ?: self.fontBold, s, @"HelveticaNeue-Bold"); }
- (NSColor *)wordmarkColor { return _wordmarkColor ?: (self.light ? self.accent : self.text); }
- (NSColor *)focusText {
    if (_focusText) return _focusText;
    if (self.light) return [NSColor whiteColor];
    return [self.focus isEqual:[NSColor whiteColor]] ? SFHex(0x111111) : self.accentText;   // dark text on a white focus
}
- (NSColor *)progressColor { return _progressColor ?: (self.light ? self.accent : self.focus); }
- (NSColor *)seekBarColor { return _seekBarColor ?: self.accent; }
- (NSColor *)headerMarkColor { return _headerMarkColor ?: self.accent; }

+ (instancetype)base {
    SFTheme *t = [SFTheme new];
    t.background = SFHex(0x101114);
    t.backgroundTop = SFHex(0x1c1f26);
    t.surface = SFHex(0x24272e);
    t.text = SFHex(0xf4f5f7);
    t.textDim = SFHexA(0xf4f5f7, 0.6);
    t.accent = SFHex(0xffffff);
    t.accentText = SFHex(0x111111);
    t.focus = SFHex(0xffffff);
    t.fontRegular = @"HelveticaNeue";
    t.fontMedium = @"HelveticaNeue-Medium";
    t.fontBold = @"HelveticaNeue-Bold";
    t.corner = 10;
    return t;
}

static NSMutableDictionary *gBuilders;   // name -> void (^)(SFTheme *)

+ (void)registerTheme:(NSString *)name builder:(void (^)(SFTheme *))builder {
    if (!gBuilders) gBuilders = [NSMutableDictionary new];
    gBuilders[name] = [builder copy];
}

+ (instancetype)themeNamed:(NSString *)name {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary new];
    if (!name) name = @"";
    if (cache[name]) return cache[name];
    SFTheme *t = [self base];
    t.identifier = name;
    t.wordmark = @"Sofa";
    void (^b)(SFTheme *) = gBuilders[name];
    if (b) b(t);
    cache[name] = t;
    return t;
}
@end

NSColor *SFTextColorOn(NSColor *background) {
    NSColor *c = [background colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    if (!c) return [NSColor whiteColor];
    double (^lin)(double) = ^double(double v) { return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); };
    double l = 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent);
    // the luminance where black and white text have equal contrast (WCAG): above it, dark text reads better
    return l > 0.179 ? SFHex(0x111111) : [NSColor whiteColor];
}
