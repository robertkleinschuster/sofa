// Grundbausteine der Oberfläche: Text-Ebene und asynchron geladene Bild-Ebene.
#import "SFCore.h"

// Text als CALayer (zeichnet mit NSStringDrawing, Kantenglättung, Ellipse).
@interface SFLabel : CALayer
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSFont *font;
@property (nonatomic, strong) NSColor *color;
@property (nonatomic) NSInteger maxLines;          // 0 = unbegrenzt
@property (nonatomic) NSTextAlignment alignment;
@property (nonatomic) CGFloat lineSpacing;
@property (nonatomic) BOOL shadow;                 // weicher Schatten (Text über Bildern)
+ (instancetype)labelWithFont:(NSFont *)f color:(NSColor *)c;
// Setzt bounds.height passend zum Text bei gegebener Breite; liefert Höhe.
- (CGFloat)sizeToFitWidth:(CGFloat)w;
@end

// Bild-Ebene: lädt Datei-/HTTP-Bilder im Hintergrund, skaliert auf Ebenengröße,
// blendet weich ein. Gemeinsamer Speicher- und Plattencache.
@interface SFImageLayer : CALayer
@property (nonatomic, copy) NSString *source;  // Dateipfad oder http(s)-URL
@property (nonatomic, strong) NSColor *placeholderColor;
@property (nonatomic) BOOL blurred;            // für Hintergrundbilder
@property (nonatomic) BOOL fadeEdges;          // links + unten weich ausblenden (Backdrops)
@end

@interface SFImageCache : NSObject
+ (instancetype)shared;
- (void)imageForSource:(NSString *)src maxPixel:(CGFloat)px blurred:(BOOL)blur
            completion:(void (^)(CGImageRef img))done;   // done auf Main-Thread
- (void)trim;
@end

CALayer *SFGradientBackground(NSColor *top, NSColor *bottom, CGRect frame);
