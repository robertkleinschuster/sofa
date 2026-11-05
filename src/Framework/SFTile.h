// A tile (image, progress, badge, duration, texts) incl. focus rendering.
#import "SFModel.h"
#import "SFLayers.h"

typedef struct {
    CGFloat width, imageHeight, textHeight, gap;
} SFTileMetrics;

SFTileMetrics SFMetricsForStyle(SFTileStyle st);
// Width of a button pill for its label: at least minWidth (0 = the style width), long labels grow
// up to a limit
CGFloat SFButtonTileWidth(SFItem *item, SFTheme *theme, CGFloat minWidth);

// Live state on tiles (download chip, watched progress) comes from the media core, so the component
// stays data-agnostic. Set once at launch (Library: SFTileStatus); without a source tiles show neither.
@protocol SFTileStatusSource <NSObject>
- (NSString *)chipTextForItem:(SFItem *)item;   // e.g. "↓ 42 %", nil = no chip
- (double)progressForItem:(SFItem *)item;       // watched fraction 0…1 (>= 1 = watched)
@end

@interface SFTileLayer : CALayer
+ (void)setStatusSource:(id<SFTileStatusSource>)source;
@property (nonatomic, strong, readonly) SFItem *item;
@property (nonatomic) BOOL focused;
- (instancetype)initWithItem:(SFItem *)item style:(SFTileStyle)st theme:(SFTheme *)theme;
// width > 0: own width in points instead of the style's (content-sized button pills)
- (instancetype)initWithItem:(SFItem *)item style:(SFTileStyle)st theme:(SFTheme *)theme width:(CGFloat)width;
- (void)refreshProgress;
- (void)loadImage;
@end
