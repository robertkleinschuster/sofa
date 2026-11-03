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

+ (instancetype)themeNamed:(NSString *)name {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary new];
    if (cache[name]) return cache[name];
    SFTheme *t = [self base];
    t.identifier = name;

    if ([name isEqualToString:@"home"]) {
        t.wordmark = @"Sofa";
        t.background = SFHex(0x0d0f14);
        t.backgroundTop = SFHex(0x232a3a);
        t.fontWordmark = @"AvenirNext-DemiBold";
        t.fontRegular = @"AvenirNext-Regular";
        t.fontMedium = @"AvenirNext-Medium";
        t.fontBold = @"AvenirNext-DemiBold";
        t.corner = 18;
    } else if ([name isEqualToString:@"youtube"]) {
        // Dunkel, rote Akzente, abgerundete 16:9-Kacheln.
        t.wordmark = @"YouTube"; t.logo = @"youtube"; t.logoVariant = 1;
        t.background = SFHex(0x0f0f0f);
        t.backgroundTop = SFHex(0x181818);
        t.surface = SFHex(0x272727);
        t.text = SFHex(0xf1f1f1);
        t.textDim = SFHex(0xaaaaaa);
        t.accent = SFHex(0xff0033);
        t.accentText = SFHex(0xffffff);
        t.focus = SFHex(0xffffff);
        t.corner = 14;
    } else if ([name isEqualToString:@"zdf"]) {
        // Anthrazit, Orange als Signalfarbe.
        t.wordmark = @"ZDF"; t.logo = @"zdf"; t.logoVariant = 0;
        t.background = SFHex(0x121417);
        t.backgroundTop = SFHex(0x22262c);
        t.surface = SFHex(0x2a2e35);
        t.accent = SFHex(0xfa7d19);
        t.accentText = SFHex(0x111111);
        t.focus = SFHex(0xfa7d19);
        t.fontRegular = @"AvenirNext-Regular";
        t.fontMedium = @"AvenirNext-Medium";
        t.fontBold = @"AvenirNext-Bold";
        t.fontWordmark = @"AvenirNext-Heavy";
        t.corner = 4;
    } else if ([name isEqualToString:@"ard"]) {
        // Nachtblau, kühles Weiß, redaktionelle Typografie.
        t.wordmark = @"ARD"; t.logo = @"ard"; t.logoVariant = 2;
        t.background = SFHex(0x001a33);
        t.backgroundTop = SFHex(0x00305e);
        t.surface = SFHex(0x0c2c4f);
        t.text = SFHex(0xffffff);
        t.textDim = SFHexA(0xdce8f5, 0.7);
        t.accent = SFHex(0x4f9cff);
        t.accentText = SFHex(0xffffff);
        t.focus = SFHex(0xffffff);
        t.fontRegular = @"GillSans";
        t.fontMedium = @"GillSans-SemiBold";
        t.fontBold = @"GillSans-Bold";
        t.fontWordmark = @"GillSans-Bold";
        t.corner = 8;
    } else if ([name isEqualToString:@"orf"]) {
        // Hell: Weiß/Hellgrau, Rot als Akzent.
        t.wordmark = @"ORF"; t.logo = @"orf"; t.logoVariant = 0;
        t.light = YES;
        t.background = SFHex(0xeeeff1);
        t.backgroundTop = SFHex(0xffffff);
        t.surface = SFHex(0xdadce0);
        t.text = SFHex(0x141414);
        t.textDim = SFHexA(0x141414, 0.6);
        t.accent = SFHex(0xd8001b);
        t.accentText = SFHex(0xffffff);
        t.focus = SFHex(0xd8001b);
        t.fontWordmark = @"HelveticaNeue-CondensedBlack";
        t.corner = 6;
    } else if ([name isEqualToString:@"ccc"]) {
        // Terminal-Ästhetik: Schwarz, Mono-Überschriften, Grün.
        t.wordmark = @"media.ccc.de"; t.logo = @"ccc"; t.logoVariant = 1;
        t.background = SFHex(0x0a0b0a);
        t.backgroundTop = SFHex(0x141a14);
        t.surface = SFHex(0x1b211b);
        t.text = SFHex(0xe8f0e8);
        t.textDim = SFHexA(0xb8d8b8, 0.65);
        t.accent = SFHex(0x36d66b);
        t.accentText = SFHex(0x041004);
        t.focus = SFHex(0x36d66b);
        t.fontWordmark = @"Menlo-Bold";
        t.fontBold = @"Menlo-Bold";
        t.corner = 2;
        t.uppercaseHeaders = NO;
    } else if ([name isEqualToString:@"mediathek"]) {
        t.wordmark = @"Mediathek";
        t.background = SFHex(0x101418);
        t.backgroundTop = SFHex(0x1e2a33);
        t.accent = SFHex(0x3fb6c8);
        t.focus = SFHex(0x3fb6c8);
        t.fontWordmark = @"AvenirNext-Bold";
    } else {
        t.wordmark = @"Sofa";
    }
    cache[name] = t;
    return t;
}
@end
