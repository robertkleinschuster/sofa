// SFQRCode - a QR Code (ISO/IEC 18004) made on this Mac, no service asked: byte mode, versions 1-40,
// the smallest version that holds the text at the wanted error correction, raised while the version
// stays the same (more correction for free), the mask with the lowest penalty (the standard's four
// rules). The TV shows it to pair a phone (SFWebPairScreen: the pairing link). Pure; checked against
// libqrencode's matrices (tests/units/qrcode.m).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, SFQRECC) { SFQRECCLow, SFQRECCMedium, SFQRECCQuartile, SFQRECCHigh };

@interface SFQRCode : NSObject
// nil when the text doesn't fit (beyond version 40)
+ (instancetype)codeForText:(NSString *)text ecc:(SFQRECC)ecc;
@property (nonatomic, readonly) NSInteger version, size, mask;   // size = modules per side (17 + 4 * version)
@property (nonatomic, readonly) SFQRECC ecc;                     // as raised
- (BOOL)darkAtX:(NSInteger)x y:(NSInteger)y;                     // outside: NO (the quiet zone)
// One pixel per module, dark on light, with a quiet zone of `quiet` modules around it - for a layer
// that scales it up without smoothing (kCAFilterNearest). Caller releases.
- (CGImageRef)newImageWithQuietZone:(NSInteger)quiet dark:(CGColorRef)dark light:(CGColorRef)light CF_RETURNS_RETAINED;
@end
