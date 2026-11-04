// Eine Kachel (Bild, Fortschritt, Badge, Dauer, Texte) inkl. Fokus-Darstellung.
#import "SFModel.h"
#import "SFLayers.h"

typedef struct {
    CGFloat width, imageHeight, textHeight, gap;
} SFTileMetrics;

SFTileMetrics SFMetricsForStyle(SFTileStyle st);

@interface SFTileLayer : CALayer
@property (nonatomic, strong, readonly) SFItem *item;
@property (nonatomic) BOOL focused;
- (instancetype)initWithItem:(SFItem *)item style:(SFTileStyle)st theme:(SFTheme *)theme;
- (void)refreshProgress;
- (void)loadImage;
@end
