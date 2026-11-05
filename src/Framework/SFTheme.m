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
