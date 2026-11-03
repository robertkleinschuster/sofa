// Gestaltung pro Bereich (Home, YouTube, ZDF, ARD, ORF, media.ccc.de, ...).
// Jede "App" in Sofa hat ihr eigenes Theme; alle Screens zeichnen nur über das Theme.
#import "SFCore.h"

typedef NS_ENUM(NSInteger, SFTileStyle) {
    SFTileStyleLandscape,   // 16:9 Vorschaubild, Titel darunter
    SFTileStyleCircle,      // runder Avatar (YouTube-Kanäle)
    SFTileStylePoster,      // 2:3 Poster (Sendungen)
    SFTileStyleApp,         // App-Kachel auf dem Home-Screen
    SFTileStyleWide,        // 16:9 groß mit Text im Bild (Sendungen/Rubriken)
};

@interface SFTheme : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *wordmark;        // Schriftzug im Header
@property (nonatomic, strong) NSColor *background;
@property (nonatomic, strong) NSColor *backgroundTop;  // Verlauf oben
@property (nonatomic, strong) NSColor *surface;        // Kachel-Hintergrund (ohne Bild)
@property (nonatomic, strong) NSColor *text;
@property (nonatomic, strong) NSColor *textDim;
@property (nonatomic, strong) NSColor *accent;
@property (nonatomic, strong) NSColor *accentText;     // Text auf Accent-Fläche
@property (nonatomic, strong) NSColor *focus;          // Fokusrahmen
@property (nonatomic, copy) NSString *fontRegular;
@property (nonatomic, copy) NSString *fontMedium;
@property (nonatomic, copy) NSString *fontBold;
@property (nonatomic, copy) NSString *fontWordmark;
@property (nonatomic) CGFloat corner;                  // Eckenradius Kacheln (Design-Einheiten)
@property (nonatomic) BOOL light;                      // helles Theme (ORF)
@property (nonatomic) BOOL uppercaseHeaders;
@property (nonatomic, copy) NSString *logo;            // Header-Logo statt Schriftzug
@property (nonatomic) NSInteger logoVariant;

+ (instancetype)themeNamed:(NSString *)name;  // home, youtube, zdf, ard, orf, ccc, library

- (NSFont *)regular:(CGFloat)size;   // Größe in Design-Einheiten
- (NSFont *)medium:(CGFloat)size;
- (NSFont *)bold:(CGFloat)size;
- (NSFont *)wordmarkFont:(CGFloat)size;
@end
