// sources: src/Framework/SFWebP.m
// flags: -I/opt/local/include -L/opt/local/lib -lwebp
// SFWebP: WebP thumbnails (ImageIO on 10.9 has no WebP) - decoded, scaled down with the aspect kept,
// colours right; anything else is not taken for WebP.
#import <Foundation/Foundation.h>
#import <webp/encode.h>
#import "SFWebP.h"

BOOL SFDevMode = NO;   // main.m's, for SFCore.m

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; fprintf(stderr, "FAIL %s: ", #c); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

int main(void) {
    @autoreleasepool {
        // 64x32: left half red, right half blue, lossless (exact colours)
        enum { W = 64, H = 32 };
        uint8_t rgba[W * H * 4];
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            uint8_t *p = rgba + (y * W + x) * 4;
            p[0] = x < W / 2 ? 255 : 0; p[1] = 0; p[2] = x < W / 2 ? 0 : 255; p[3] = 255;
        }
        uint8_t *out = NULL;
        size_t n = WebPEncodeLosslessRGBA(rgba, W, H, W * 4, &out);
        CHECK(n > 0, "encode");
        NSData *webp = [NSData dataWithBytes:out length:n];
        WebPFree(out);

        CHECK(SFIsWebP(webp), "RIFF/WEBP header recognised");
        CHECK(!SFIsWebP([@"\xff\xd8\xff\xe0 JFIF......" dataUsingEncoding:NSISOLatin1StringEncoding]), "JPEG is no WebP");
        CHECK(!SFIsWebP([NSData data]), "empty");
        CHECK(SFDecodeWebP([NSData dataWithBytes:"RIFF\0\0\0\0WEBPxxxx" length:16], 64) == NULL, "broken WebP -> NULL");

        CGImageRef full = SFDecodeWebP(webp, 0);
        CHECK(full && CGImageGetWidth(full) == W && CGImageGetHeight(full) == H, "full size %zux%zu", full ? CGImageGetWidth(full) : 0, full ? CGImageGetHeight(full) : 0);
        if (full) CGImageRelease(full);

        CGImageRef img = SFDecodeWebP(webp, 16);   // longer side 16 -> 16x8
        CHECK(img && CGImageGetWidth(img) == 16 && CGImageGetHeight(img) == 8, "scaled %zux%zu", img ? CGImageGetWidth(img) : 0, img ? CGImageGetHeight(img) : 0);
        if (img) {
            CFDataRef d = CGDataProviderCopyData(CGImageGetDataProvider(img));
            const uint8_t *px = CFDataGetBytePtr(d);
            size_t stride = CGImageGetBytesPerRow(img);
            const uint8_t *left = px + 4 * stride + 2 * 4, *right = px + 4 * stride + 13 * 4;
            CHECK(left[0] > 240 && left[2] < 15 && left[3] == 255, "left red: %d %d %d %d", left[0], left[1], left[2], left[3]);
            CHECK(right[2] > 240 && right[0] < 15 && right[3] == 255, "right blue: %d %d %d %d", right[0], right[1], right[2], right[3]);
            CFRelease(d);
            CGImageRelease(img);
        }
    }
    return fails ? 1 : 0;
}
