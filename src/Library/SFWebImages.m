#import "SFWebImages.h"
#import "SFLayers.h"
#import "SFStore.h"
#import "SFNet.h"
#import <CommonCrypto/CommonHMAC.h>
#import <Security/SecRandom.h>
#import <ImageIO/ImageIO.h>

static const NSUInteger kMinWidth = 64, kMaxWidth = 1920;
static NSString *const kOldKeySetting = @"web.imageKey";   // where the key was kept until 2026-11-26 (moved, then removed)

static NSString *Hex(const uint8_t *b, size_t n) {
    NSMutableString *h = [NSMutableString stringWithCapacity:n * 2];
    for (size_t i = 0; i < n; i++) [h appendFormat:@"%02x", b[i]];
    return h;
}

static BOOL IsKey(NSString *hex) {
    return hex.length == 64 && [hex rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}

// The signing key: 256 random bits, in <data dir>/web/image.key (the folder 0700, the file 0600, next
// to the tailnet certificate's key) - a secret is no setting and no row of the database, which tests
// and backups copy. It lives as long as the data folder: the picture URLs a client cached (a native
// app's image cache, the browser's) stay valid across Sofa's restarts and updates.
static NSData *Key(void) {
    static NSData *key; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [SFAppSupportDir() stringByAppendingPathComponent:@"web"], *path = [dir stringByAppendingPathComponent:@"image.key"];
        NSString *hex = [[[NSString alloc] initWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!IsKey(hex)) {
            NSString *old = [[SFStore shared] setting:kOldKeySetting];   // the pictures handed out before keep working
            if (IsKey(old)) hex = old;
            else {
                uint8_t b[32];
                if (SecRandomCopyBytes(kSecRandomDefault, sizeof b, b) != 0) arc4random_buf(b, sizeof b);
                hex = Hex(b, sizeof b);
            }
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
            NSString *tmp = [path stringByAppendingString:@".tmp"];
            BOOL written = [fm createFileAtPath:tmp contents:[hex dataUsingEncoding:NSUTF8StringEncoding] attributes:@{NSFilePosixPermissions: @0600}]
                        && rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
            if (written) {
                if (old) [[SFStore shared] setSetting:nil forKey:kOldKeySetting];
                SFLog(@"web: picture key %@", IsKey(old) ? @"moved into the data folder" : @"made");
            } else SFLog(@"web: picture key not written (%s) - pictures are signed for this run only", strerror(errno));
        }
        key = [hex dataUsingEncoding:NSUTF8StringEncoding];
    });
    return key;
}

static NSString *Sign(NSString *source) {
    NSData *k = Key(), *d = [source dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, k.bytes, k.length, d.bytes, d.length, mac);
    NSMutableString *h = [NSMutableString new];
    for (int i = 0; i < 16; i++) [h appendFormat:@"%02x", mac[i]];
    return h;
}

@implementation SFWebImages

+ (NSString *)pathFor:(NSString *)source {
    if (!source.length) return nil;
    return [NSString stringWithFormat:@"/img/%@?u=%@", Sign(source), [SFNet escape:source]];
}

+ (BOOL)signature:(NSString *)sig matches:(NSString *)source {
    if (sig.length != 32 || !source.length) return NO;
    NSString *want = Sign(source);
    uint8_t diff = 0;
    for (NSUInteger i = 0; i < 32; i++) diff |= (uint8_t)([sig characterAtIndex:i] ^ [want characterAtIndex:i]);
    return diff == 0;
}

static NSCache *Encoded(void) {
    static NSCache *c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [NSCache new]; c.totalCostLimit = 32 << 20; });
    return c;
}

+ (void)imageFor:(NSString *)source width:(NSUInteger)width done:(void (^)(NSData *, NSString *))done {
    width = MIN(kMaxWidth, MAX(kMinWidth, width ?: 480));
    width = (width + 63) / 64 * 64;   // the steps SFImageCache keeps
    NSString *key = [NSString stringWithFormat:@"%lu|%@", (unsigned long)width, source];
    NSArray *hit = [Encoded() objectForKey:key];
    if (hit) { SFMain(^{ done(hit[0], hit[1]); }); return; }
    SFMain(^{
        [[SFImageCache shared] imageForSource:source maxPixel:width blurred:NO completion:^(CGImageRef img) {
            if (!img) { done(nil, nil); return; }
            CGImageRef keep = CGImageRetain(img);
            SFBackground(^{
                CGImageAlphaInfo a = CGImageGetAlphaInfo(keep);
                BOOL alpha = a == kCGImageAlphaFirst || a == kCGImageAlphaLast || a == kCGImageAlphaPremultipliedFirst || a == kCGImageAlphaPremultipliedLast;
                NSString *type = alpha ? @"public.png" : @"public.jpeg";
                NSMutableData *out = [NSMutableData new];
                CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, (__bridge CFStringRef)type, 1, NULL);
                if (dst) {
                    CGImageDestinationAddImage(dst, keep, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @0.82});
                    if (!CGImageDestinationFinalize(dst)) [out setLength:0];
                    CFRelease(dst);
                }
                CGImageRelease(keep);
                NSString *mime = alpha ? @"image/png" : @"image/jpeg";
                if (out.length) [Encoded() setObject:@[out, mime] forKey:key cost:out.length];
                SFMain(^{ done(out.length ? out : nil, mime); });
            });
        }];
    });
}
@end
