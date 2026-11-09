#import "SFLogo.h"
#import <ImageIO/ImageIO.h>

// The logos' directory: the bundle's, or res/logos of a development build without bundle resources.
static NSString *logosDir(void) {
    static NSString *dir; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *res = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"logos"];
        if ([[NSFileManager new] fileExistsAtPath:res]) { dir = res; return; }
        NSString *exe = [[NSBundle mainBundle] executablePath];
        NSString *root = [[[[[exe stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
                            stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        dir = [root stringByAppendingPathComponent:@"res/logos"];
    });
    return dir;
}

static NSString *logoPath(NSString *name) { return [logosDir() stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]]; }

// The logo in its variant, decoded and recoloured: a fresh image (+1), NULL if there is none. Pure.
static CGImageRef render(NSString *name, SFLogoVariant variant) {
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
    // logos without alpha channel (ARD) have a white background -> cut out
    BOOL knockWhite = CGImageGetAlphaInfo(img) == kCGImageAlphaNone || CGImageGetAlphaInfo(img) == kCGImageAlphaNoneSkipLast || CGImageGetAlphaInfo(img) == kCGImageAlphaNoneSkipFirst;
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *p = px + i * 4;
        uint8_t a = p[3];
        if (!a) continue;
        // un-premultiply
        double r = p[0] * 255.0 / a, g = p[1] * 255.0 / a, b = p[2] * 255.0 / a;
        double lum = 0.299 * r + 0.587 * g + 0.114 * b;
        double sat = MAX(r, MAX(g, b)) - MIN(r, MIN(g, b));
        // cut out the white (opaque) background: very light + achromatic -> transparent
        if (knockWhite && lum > 240 && sat < 18 && a == 255) { p[0] = p[1] = p[2] = p[3] = 0; continue; }
        if (variant == SFLogoWhite) { r = g = b = 255; }
        else if (variant == SFLogoLightText && lum < 90 && sat < 40) { r = g = b = 255; }
        p[0] = (uint8_t)(r * a / 255.0); p[1] = (uint8_t)(g * a / 255.0); p[2] = (uint8_t)(b * a / 255.0);
    }
    CGImageRelease(img);
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return out;
}

static NSMutableDictionary *cache(void) {
    static NSMutableDictionary *c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [NSMutableDictionary new]; });
    return c;
}

static NSString *keyOf(NSString *name, SFLogoVariant variant) { return [NSString stringWithFormat:@"%@#%ld", name, (long)variant]; }

// Kept in the cache unless another thread got there first; the cached image either way.
static CGImageRef keep(NSString *key, CGImageRef img) {
    NSMutableDictionary *c = cache();
    @synchronized (c) {
        if (!c[key]) c[key] = (__bridge_transfer id)img; else CGImageRelease(img);
        return (__bridge CGImageRef)c[key];
    }
}

CGImageRef SFLogoImage(NSString *name, SFLogoVariant variant) {
    NSString *key = keyOf(name, variant);
    NSMutableDictionary *c = cache();
    @synchronized (c) { id hit = c[key]; if (hit) return (__bridge CGImageRef)hit; }
    CGImageRef img = render(name, variant);   // outside the lock: SFLogoPrepare may be rendering another
    return img ? keep(key, img) : NULL;
}

static NSString *markPath(NSString *name) {
    return [[logosDir() stringByAppendingPathComponent:@"marks"] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
}

CGImageRef SFLogoMark(NSString *name) {
    if (!name.length) return NULL;
    NSString *key = [@"mark#" stringByAppendingString:name];
    NSMutableDictionary *c = cache();
    @synchronized (c) { id hit = c[key]; if (hit) return hit == [NSNull null] ? NULL : (__bridge CGImageRef)hit; }
    CGImageRef img = NULL;
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:markPath(name)], NULL);
    if (src) { img = CGImageSourceCreateImageAtIndex(src, 0, NULL); CFRelease(src); }
    if (!img) { @synchronized (c) { c[key] = [NSNull null]; } return NULL; }   // none: not looked up again
    return keep(key, img);
}

// Every logo in every variant, off the main thread: decoding and recolouring them where the first
// tiles asked for them took 310 ms of the main thread at launch (hitch monitor 2026-11-07).
void SFLogoPrepare(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (NSString *f in [[NSFileManager new] contentsOfDirectoryAtPath:logosDir() error:nil]) {
            if (![f.pathExtension isEqualToString:@"png"]) continue;
            NSString *name = f.stringByDeletingPathExtension;
            for (SFLogoVariant v = SFLogoOriginal; v <= SFLogoWhite; v++) {
                NSString *key = keyOf(name, v);
                @synchronized (cache()) { if (cache()[key]) continue; }
                CGImageRef img = render(name, v);
                if (img) keep(key, img);
            }
        }
        for (NSString *f in [[NSFileManager new] contentsOfDirectoryAtPath:[logosDir() stringByAppendingPathComponent:@"marks"] error:nil])
            if ([f.pathExtension isEqualToString:@"png"]) SFLogoMark(f.stringByDeletingPathExtension);
    });
}
