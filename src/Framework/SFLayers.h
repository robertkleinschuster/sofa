// Basic UI building blocks: text layer and asynchronously loaded image layer.
#import "SFCore.h"

@class SFLabelLook;

// Text as a CALayer (draws with NSStringDrawing, antialiasing, ellipsis).
@interface SFLabel : CALayer
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSFont *font;
@property (nonatomic, strong) NSColor *color;
@property (nonatomic) NSInteger maxLines;          // 0 = unlimited
@property (nonatomic) NSTextAlignment alignment;
@property (nonatomic) CGFloat lineSpacing;
@property (nonatomic) BOOL shadow;                 // soft shadow (text over images)
+ (instancetype)labelWithFont:(NSFont *)f color:(NSColor *)c;
// Sets bounds.height to fit the text at the given width; returns the height.
- (CGFloat)sizeToFitWidth:(CGFloat)w;

// Changing a label without drawing on the main thread. A first draw can be slow - a colour emoji at
// hero size decodes its bitmap from the font: 110-180 ms each on this iMac (2026-11-07), and a
// title with three of them blocked Home's navigation for half a second. A look is measured on the
// main thread (cheap) and drawn on the text queue (SFLabelLook render:); applyLook: then shows it
// at once, so text, size and picture change together.
- (CGFloat)heightForText:(NSString *)text maxLines:(NSInteger)maxLines width:(CGFloat)w;   // what sizeToFitWidth: would give
- (SFLabelLook *)lookForText:(NSString *)text maxLines:(NSInteger)maxLines width:(CGFloat)w;
- (void)applyLook:(SFLabelLook *)look;   // main thread, after render:
@end

@interface SFLabelLook : NSObject
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly) CGSize size;
// Draws the looks on the text queue (serial, off the main thread); `done` runs on the main thread.
+ (void)render:(NSArray *)looks done:(dispatch_block_t)done;
@end

// Image layer: loads file/HTTP images in the background, scales to the layer size,
// fades in softly. Shared memory and disk cache.
@interface SFImageLayer : CALayer
@property (nonatomic, copy) NSString *source;  // file path or http(s) URL
// shown when `source` can't be loaded (e.g. a high-resolution backdrop that doesn't exist for
// this video: YouTube maxresdefault 404) - set before `source`
@property (nonatomic, copy) NSString *fallbackSource;
@property (nonatomic, strong) NSColor *placeholderColor;
@property (nonatomic) BOOL blurred;            // for background images
@property (nonatomic) BOOL adaptiveBackground; // logos: background by the image's brightness (dark logo -> light)
@property (nonatomic) BOOL fadeEdges;          // soft fade-out left + bottom (backdrops)
@property (nonatomic) BOOL alwaysFadesIn;      // fades in also when cached (backdrops: a new picture, never a reload)
@end

@interface SFImageCache : NSObject
+ (instancetype)shared;
- (void)imageForSource:(NSString *)src maxPixel:(CGFloat)px blurred:(BOOL)blur
            completion:(void (^)(CGImageRef img))done;   // done on the main thread
- (void)trim;
@end

CALayer *SFGradientBackground(NSColor *top, NSColor *bottom, CGRect frame);
