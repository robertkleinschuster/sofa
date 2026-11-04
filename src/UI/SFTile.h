// Eine Kachel (Bild, Fortschritt, Badge, Dauer, Texte) inkl. Fokus-Darstellung.
#import "SFModel.h"
#import "SFLayers.h"

typedef struct {
    CGFloat width, imageHeight, textHeight, gap;
} SFTileMetrics;

SFTileMetrics SFMetricsForStyle(SFTileStyle st);
// Width of a button pill for its label: at least minWidth (0 = the style width), long labels grow
// up to a limit
CGFloat SFButtonTileWidth(SFItem *item, SFTheme *theme, CGFloat minWidth);

@interface SFTileLayer : CALayer
@property (nonatomic, strong, readonly) SFItem *item;
@property (nonatomic) BOOL focused;
- (instancetype)initWithItem:(SFItem *)item style:(SFTileStyle)st theme:(SFTheme *)theme;
// width > 0: own width in points instead of the style's (content-sized button pills)
- (instancetype)initWithItem:(SFItem *)item style:(SFTileStyle)st theme:(SFTheme *)theme width:(CGFloat)width;
- (void)refreshProgress;
- (void)loadImage;
@end
