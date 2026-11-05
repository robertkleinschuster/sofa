// Design tokens. Every area (the Sofa home, each app) has its own theme = base tokens + the
// area's overrides, registered by name (apps: SFAppRegistry from SFApp configureTheme:).
// All components draw only through the theme; the Framework knows no apps.
#import "SFCore.h"

typedef NS_ENUM(NSInteger, SFTileStyle) {
    SFTileStyleLandscape,   // 16:9 thumbnail, title below
    SFTileStyleCircle,      // round avatar (YouTube channels)
    SFTileStylePoster,      // 2:3 poster (shows)
    SFTileStyleApp,         // app tile on the home screen
    SFTileStyleWide,        // 16:9 large with text in the image (shows/sections)
    SFTileStyleButton,      // compact pill with text (actions: Folgen, Automatisch herunterladen)
};

@interface SFTheme : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *wordmark;        // wordmark in the header
@property (nonatomic, strong) NSColor *background;
@property (nonatomic, strong) NSColor *backgroundTop;  // gradient top
@property (nonatomic, strong) NSColor *surface;        // tile background (without image)
@property (nonatomic, strong) NSColor *text;
@property (nonatomic, strong) NSColor *textDim;
@property (nonatomic, strong) NSColor *accent;
@property (nonatomic, strong) NSColor *accentText;     // text on an accent surface
@property (nonatomic, strong) NSColor *focus;          // focus frame
@property (nonatomic, copy) NSString *fontRegular;
@property (nonatomic, copy) NSString *fontMedium;
@property (nonatomic, copy) NSString *fontBold;
@property (nonatomic, copy) NSString *fontWordmark;
@property (nonatomic) CGFloat corner;                  // tile corner radius (design units)
@property (nonatomic) BOOL light;                      // light theme (ORF)
@property (nonatomic) BOOL uppercaseHeaders;
@property (nonatomic, copy) NSString *logo;            // header logo instead of the wordmark
@property (nonatomic) NSInteger logoVariant;

+ (instancetype)themeNamed:(NSString *)name;   // registered name; unknown -> base theme
+ (void)registerTheme:(NSString *)name builder:(void (^)(SFTheme *t))builder;   // tokens on top of the base

- (NSFont *)regular:(CGFloat)size;   // size in design units
- (NSFont *)medium:(CGFloat)size;
- (NSFont *)bold:(CGFloat)size;
- (NSFont *)wordmarkFont:(CGFloat)size;
@end
