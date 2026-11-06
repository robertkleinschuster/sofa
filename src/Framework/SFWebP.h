// SFWebP - WebP decoding (libwebp): ImageIO on 10.9 knows no WebP, but image hosts send it to a
// browser that accepts it (i.ytimg.com to Sofa's Chrome identity, 2026-11-06: blank thumbnails).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

BOOL SFIsWebP(NSData *data);
// The image scaled down (aspect kept) so its longer side is at most maxPixel; NULL if undecodable.
CGImageRef SFDecodeWebP(NSData *data, CGFloat maxPixel) CF_RETURNS_RETAINED;
