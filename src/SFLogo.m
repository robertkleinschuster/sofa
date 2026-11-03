#import "SFLogo.h"
#import <ImageIO/ImageIO.h>

static NSString *logoPath(NSString *name) {
    NSString *p = [[NSBundle mainBundle] pathForResource:name ofType:@"png" inDirectory:@"logos"];
    if (!p) {   // Entwicklungs-Build ohne Bundle-Ressourcen
        NSString *exe = [[NSBundle mainBundle] executablePath];
        NSString *root = [[[[[exe stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
                            stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        p = [root stringByAppendingFormat:@"/res/logos/%@.png", name];
    }
    return p;
}

CGImageRef SFLogoImage(NSString *name, SFLogoVariant variant) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%@#%ld", name, (long)variant];
    id hit = cache[key];
    if (hit) return (__bridge CGImageRef)hit;
    NSString *path = logoPath(name);
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return NULL;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);
    uint8_t *px = CGBitmapContextGetData(c);
    // Logos ohne Alphakanal (ARD) haben weißen Hintergrund -> freistellen
    BOOL knockWhite = CGImageGetAlphaInfo(img) == kCGImageAlphaNone || CGImageGetAlphaInfo(img) == kCGImageAlphaNoneSkipLast || CGImageGetAlphaInfo(img) == kCGImageAlphaNoneSkipFirst;
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *p = px + i * 4;
        uint8_t a = p[3];
        if (!a) continue;
        // un-premultiply
        double r = p[0] * 255.0 / a, g = p[1] * 255.0 / a, b = p[2] * 255.0 / a;
        double lum = 0.299 * r + 0.587 * g + 0.114 * b;
        double sat = MAX(r, MAX(g, b)) - MIN(r, MIN(g, b));
        // weißen (undurchsichtigen) Hintergrund freistellen: sehr hell + unbunt -> transparent
        if (knockWhite && lum > 240 && sat < 18 && a == 255) { p[0] = p[1] = p[2] = p[3] = 0; continue; }
        if (variant == SFLogoWhite) { r = g = b = 255; }
        else if (variant == SFLogoLightText && lum < 90 && sat < 40) { r = g = b = 255; }
        p[0] = (uint8_t)(r * a / 255.0); p[1] = (uint8_t)(g * a / 255.0); p[2] = (uint8_t)(b * a / 255.0);
    }
    CGImageRelease(img);
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    if (!out) return NULL;
    cache[key] = (__bridge_transfer id)out;
    return (__bridge CGImageRef)cache[key];
}
