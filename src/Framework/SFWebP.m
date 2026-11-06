#import "SFWebP.h"
#import <webp/decode.h>

BOOL SFIsWebP(NSData *data) {
    if (data.length < 12) return NO;
    const char *b = data.bytes;
    return memcmp(b, "RIFF", 4) == 0 && memcmp(b + 8, "WEBP", 4) == 0;
}

static void freePixels(void *info, const void *data, size_t size) { WebPFree((void *)data); }

CGImageRef SFDecodeWebP(NSData *data, CGFloat maxPixel) {
    WebPDecoderConfig cfg;
    if (!SFIsWebP(data) || !WebPInitDecoderConfig(&cfg)) return NULL;
    if (WebPGetFeatures(data.bytes, data.length, &cfg.input) != VP8_STATUS_OK) return NULL;
    int w = cfg.input.width, h = cfg.input.height;
    if (w <= 0 || h <= 0) return NULL;
    double scale = maxPixel > 0 ? MIN(1.0, maxPixel / MAX(w, h)) : 1.0;
    if (scale < 1.0) {   // libwebp scales while decoding: no full-size buffer for a small tile
        cfg.options.use_scaling = 1;
        cfg.options.scaled_width = MAX(1, (int)lround(w * scale));
        cfg.options.scaled_height = MAX(1, (int)lround(h * scale));
        w = cfg.options.scaled_width; h = cfg.options.scaled_height;
    }
    cfg.output.colorspace = MODE_rgbA;   // premultiplied, as Core Graphics wants it
    if (WebPDecode(data.bytes, data.length, &cfg) != VP8_STATUS_OK) { WebPFreeDecBuffer(&cfg.output); return NULL; }
    uint8_t *px = cfg.output.u.RGBA.rgba;
    size_t stride = (size_t)cfg.output.u.RGBA.stride, size = cfg.output.u.RGBA.size;
    // the provider owns the pixels from here (released with WebPFree)
    CGDataProviderRef p = CGDataProviderCreateWithData(NULL, px, size, freePixels);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, stride, cs,
                                   (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault,
                                   p, NULL, NO, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(p);
    return img;
}
