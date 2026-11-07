#import "SFLayers.h"
#import "SFFrameMeter.h"
#import "SFNet.h"
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import "SFCurl.h"
#import "SFRuntime.h"
#import "SFUserAgent.h"
#import "SFWebP.h"

#pragma mark - Image cache

@implementation SFImageCache {
    NSCache *_mem;
    NSMutableSet *_missing;   // remote sources the server answered 404/410 for (this session): no refetch
    NSOperationQueue *_decode;
    NSOperationQueue *_net;
    NSString *_diskDir;
    NSURLSession *_session;
    NSMutableDictionary *_pending;
}

+ (instancetype)shared {
    static SFImageCache *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFImageCache new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _mem = [NSCache new];
        _missing = [NSMutableSet new];
        _mem.totalCostLimit = 350 * 1024 * 1024;  // decoded pixels
        _decode = [NSOperationQueue new];
        _decode.maxConcurrentOperationCount = 3;
        _net = [NSOperationQueue new];
        _net.maxConcurrentOperationCount = 6;
        _diskDir = [SFCacheDir() stringByAppendingPathComponent:@"img"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_diskDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
        c.HTTPMaximumConnectionsPerHost = 4;
        c.timeoutIntervalForRequest = 20;
        c.URLCache = nil;
        _session = [NSURLSession sessionWithConfiguration:c delegate:SFTrustAllSessionDelegate() delegateQueue:nil];
        _pending = [NSMutableDictionary new];
    }
    return self;
}

- (void)trim { [_mem removeAllObjects]; }

static NSString *hashString(NSString *s) {
    unsigned char d[CC_SHA1_DIGEST_LENGTH];
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA1(data.bytes, (CC_LONG)data.length, d);
    NSMutableString *o = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [o appendFormat:@"%02x", d[i]];
    return o;
}

// SVG (e.g. conference logos): ImageIO cannot do SVG on 10.9 -> rasterize once to a PNG via
// rsvg-convert (librsvg, MacPorts, native); the PNG then replaces the cache entry.
static BOOL looksLikeSVG(NSData *d) {
    if (d.length < 5) return NO;
    NSString *head = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, MIN(d.length, (NSUInteger)1024))] encoding:NSUTF8StringEncoding];
    if (!head) head = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, MIN(d.length, (NSUInteger)1024))] encoding:NSISOLatin1StringEncoding];
    return [head rangeOfString:@"<svg" options:NSCaseInsensitiveSearch].location != NSNotFound;
}
static NSData *rasterizeSVG(NSData *svg) {
    NSString *tool = SFTool(@"rsvg-convert");
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:tool]) return nil;
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *in = [tmp stringByAppendingPathExtension:@"svg"], *out = [tmp stringByAppendingPathExtension:@"png"];
    if (![svg writeToFile:in atomically:NO]) return nil;
    NSData *png = nil;   // keep the aspect ratio, 1024 px wide
    if (SFRunProcess(tool, @[@"-a", @"-w", @"1024", @"-f", @"png", @"-o", out, in], 20, NO, NULL) == 0) png = [NSData dataWithContentsOfFile:out];
    [[NSFileManager defaultManager] removeItemAtPath:in error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
    if (!png.length) SFLog(@"image: SVG not rasterized");
    return png.length ? png : nil;
}

static CGImageRef decodeThumb(CGImageSourceRef src, CGFloat px) CF_RETURNS_RETAINED;
static CGImageRef decodeThumb(CGImageSourceRef src, CGFloat px) {
    if (!src) return NULL;
    NSDictionary *o = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                        (id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(16, px)),
                        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                        (id)kCGImageSourceShouldCacheImmediately: @YES};
    return CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)o);
}

- (void)imageForSource:(NSString *)src maxPixel:(CGFloat)px blurred:(BOOL)blur
            completion:(void (^)(CGImageRef))done {
    if (!src.length) { done(NULL); return; }
    @synchronized (_missing) { if ([_missing containsObject:src]) { done(NULL); return; } }
    if (blur) px = 64;  // decode tiny, the GPU scales up smoothly = cheap blur
    px = ceil(px / 64) * 64;
    NSString *key = [NSString stringWithFormat:@"%@|%.0f", src, px];
    id hit = [_mem objectForKey:key];
    if (hit) { done((__bridge CGImageRef)hit); return; }

    @synchronized (_pending) {
        NSMutableArray *w = _pending[key];
        if (w) { [w addObject:[done copy]]; return; }
        _pending[key] = [NSMutableArray arrayWithObject:[done copy]];
    }
    void (^finish)(CGImageRef) = ^(CGImageRef img) {
        if (img) {
            size_t cost = CGImageGetBytesPerRow(img) * CGImageGetHeight(img);
            [self->_mem setObject:(__bridge id)img forKey:key cost:cost];
        }
        CGImageRef keep = img ? CGImageRetain(img) : NULL;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *ws;
            @synchronized (self->_pending) { ws = self->_pending[key]; [self->_pending removeObjectForKey:key]; }
            for (void (^cb)(CGImageRef) in ws) cb(keep);
            if (keep) CGImageRelease(keep);
        });
    };

    BOOL remote = [src hasPrefix:@"http://"] || [src hasPrefix:@"https://"];
    if (!remote) {
        [_decode addOperationWithBlock:^{
            CGImageSourceRef s = NULL;
            if ([src.pathExtension.lowercaseString isEqualToString:@"svg"]) {
                NSData *png = rasterizeSVG([NSData dataWithContentsOfFile:src]);
                s = png ? CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL) : NULL;
            } else {
                NSData *d = [NSData dataWithContentsOfFile:src options:NSDataReadingMappedIfSafe error:nil];
                if (SFIsWebP(d)) { CGImageRef w = SFDecodeWebP(d, px); finish(w); if (w) CGImageRelease(w); return; }
                s = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:src], NULL);
            }
            CGImageRef img = decodeThumb(s, px);
            if (s) CFRelease(s);
            finish(img);
            if (img) CGImageRelease(img);
        }];
        return;
    }
    NSString *disk = [_diskDir stringByAppendingPathComponent:hashString(src)];
    void (^decodeData)(NSData *) = ^(NSData *raw) {
        [self->_decode addOperationWithBlock:^{
            NSData *data = raw;
            if (looksLikeSVG(data)) {   // rasterize once, the PNG replaces the cache entry
                data = rasterizeSVG(data);
                if (data) [data writeToFile:disk atomically:YES];
            }
            if (SFIsWebP(data)) { CGImageRef w = SFDecodeWebP(data, px); finish(w); if (w) CGImageRelease(w); return; }
            CGImageSourceRef s = data ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
            CGImageRef img = decodeThumb(s, px);
            if (s) CFRelease(s);
            finish(img);
            if (img) CGImageRelease(img);
        }];
    };
    [_net addOperationWithBlock:^{
        NSData *cached = [NSData dataWithContentsOfFile:disk];
        if (cached.length) { decodeData(cached); return; }
        NSURL *u = [NSURL URLWithString:src];
        if (!u) { finish(NULL); return; }
        if (SFHostNeedsCurl(u.host)) {   // TLS bridge (e.g. ORF images)
            NSInteger st = 0;
            NSData *data = SFCurlFetch(src, @"GET", nil, nil, &st, NULL);
            if (data.length && st < 400) { [data writeToFile:disk atomically:YES]; decodeData(data); }
            else {
                if (st == 404 || st == 410) @synchronized (self->_missing) { [self->_missing addObject:src]; }
                finish(NULL);
            }
            return;
        }
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u];
        [rq setValue:SFNativeUserAgent() forHTTPHeaderField:@"User-Agent"];
        [[self->_session dataTaskWithRequest:rq completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            NSInteger code = [(NSHTTPURLResponse *)r statusCode];
            if (SFIsTLSError(e)) SFMarkHostNeedsCurl(u.host);   // next attempt via curl
            if (data.length && code < 400) {
                [data writeToFile:disk atomically:YES];
                decodeData(data);
            } else {
                if (code == 404 || code == 410) @synchronized (self->_missing) { [self->_missing addObject:src]; }
                finish(NULL);
            }
            dispatch_semaphore_signal(sem);
        }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    }];
}
@end

#pragma mark - SFImageLayer

@interface SFImageLayer (Fade)
- (void)applyFaded:(CGImageRef)img source:(NSString *)want loaded:(NSString *)loaded animated:(BOOL)animated;
@end

@interface SFImageLayer (Adaptive)
- (void)adaptBackgroundTo:(CGImageRef)img source:(NSString *)want;
@end

@implementation SFImageLayer

static const NSTimeInterval kFadeIn = 0.3;

- (instancetype)init {
    if ((self = [super init])) {
        self.contentsGravity = kCAGravityResizeAspectFill;
        self.masksToBounds = YES;
        self.minificationFilter = kCAFilterTrilinear;
    }
    return self;
}
- (id<CAAction>)actionForKey:(NSString *)event {
    if ([event isEqualToString:@"contents"]) return nil;
    return [super actionForKey:event];
}

- (void)setPlaceholderColor:(NSColor *)c {
    _placeholderColor = c;
    if (!self.contents) self.backgroundColor = c.CGColor;
}

- (void)setSource:(NSString *)source {
    if ([_source isEqualToString:source] && (self.contents || !source)) return;
    _source = [source copy];
    self.contents = nil;
    self.backgroundColor = self.placeholderColor.CGColor;
    if (!source.length) return;
    CGFloat px = MAX(self.bounds.size.width, self.bounds.size.height) * self.contentsScale;
    if (px < 1) px = 512;
    NSString *want = _source, *fallback = [_fallbackSource isEqualToString:source] ? nil : _fallbackSource;
    BOOL blurred = self.blurred;
    __block BOOL inMemory = YES;   // answered within this call: the picture was decoded already
    __weak SFImageLayer *ws = self;
    void (^apply)(CGImageRef, NSString *) = ^(CGImageRef img, NSString *loaded) {
        SFImageLayer *s = ws;
        if (!s || ![s.source isEqualToString:want] || !img) return;
        BOOL animated = !inMemory || s.alwaysFadesIn;
        if (s.fadeEdges) { [s applyFaded:img source:want loaded:loaded animated:animated]; return; }
        if (s.adaptiveBackground) [s adaptBackgroundTo:img source:want];
        [s present:(__bridge id)img animated:animated];
    };
    [[SFImageCache shared] imageForSource:source maxPixel:px blurred:blurred completion:^(CGImageRef img) {
        if (img || !fallback.length) { apply(img, want); return; }
        SFImageLayer *s = ws;
        if (!s || ![s.source isEqualToString:want]) return;
        [[SFImageCache shared] imageForSource:fallback maxPixel:px blurred:blurred completion:^(CGImageRef f) { apply(f, fallback); }];
    }];
    inMemory = NO;
}

// Shows `img`: at once when it was in memory - a rebuilt row or a reopened panel shows the same
// pictures again, and fading them in from nothing made every reload flicker (user 2026-11-07);
// otherwise (and always for alwaysFadesIn) fading in.
- (void)present:(id)img animated:(BOOL)animated {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.contents = img;
    [CATransaction commit];
    if (!animated || !img) return;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0; fade.toValue = @1; fade.duration = kFadeIn;
    [self addAnimation:fade forKey:@"fadein"];
    if (self.alwaysFadesIn) SFFrameMeterMeasure(@"fade-in", kFadeIn);
}
@end

// Analysis of a logo (24x24): brightness of the opaque pixels, coverage, average edge colour
typedef struct { double lum, coverage, er, eg, eb; } SFLogoInfo;
static SFLogoInfo logoInfo(CGImageRef img) {
    SFLogoInfo info = { -1, 0, 0, 0, 0 };
    const int n = 24;
    uint8_t px[n * n * 4];
    memset(px, 0, sizeof px);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, n, n, 8, n * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c) return info;
    CGContextDrawImage(c, CGRectMake(0, 0, n, n), img);
    CGContextRelease(c);
    double sum = 0, w = 0, er = 0, eg = 0, eb = 0, en = 0;
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
        int i = y * n + x;
        double a = px[i * 4 + 3] / 255.0;
        if (a >= 0.3) {
            double r = px[i * 4] / 255.0 / a, g = px[i * 4 + 1] / 255.0 / a, b = px[i * 4 + 2] / 255.0 / a;
            sum += (0.2126 * r + 0.7152 * g + 0.0722 * b) * a; w += a;
            if (x == 0 || y == 0 || x == n - 1 || y == n - 1) { er += r; eg += g; eb += b; en++; }
        }
    }
    info.coverage = w / (n * n);
    if (w >= 6) info.lum = sum / w;
    if (en > 0) { info.er = er / en; info.eg = eg / en; info.eb = eb / en; }
    return info;
}

@implementation SFImageLayer (Adaptive)
- (void)adaptBackgroundTo:(CGImageRef)img source:(NSString *)want {
    CGImageRef keep = CGImageRetain(img);
    __weak SFImageLayer *ws = self;
    SFBackground(^{
        SFLogoInfo li = logoInfo(keep);
        double lum = li.lum;
        CGImageRelease(keep);
        dispatch_async(dispatch_get_main_queue(), ^{
            SFImageLayer *s = ws;
            if (!s || ![s.source isEqualToString:want] || lum < 0) return;
            CGFloat bgLum = 0.5;
            NSColor *pc = [s.placeholderColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
            if (pc) bgLum = 0.2126 * pc.redComponent + 0.7152 * pc.greenComponent + 0.0722 * pc.blueComponent;
            NSColor *bg = nil;
            if (li.coverage > 0.85) {   // opaque image: fill the edges in its own edge colour (seamless)
                bg = [NSColor colorWithCalibratedRed:li.er green:li.eg blue:li.eb alpha:1];
            } else if (lum < 0.4 && bgLum < 0.5) bg = [NSColor colorWithCalibratedWhite:0.9 alpha:1];        // dark logo on dark -> light
            else if (lum > 0.7 && bgLum > 0.5) bg = [NSColor colorWithCalibratedWhite:0.14 alpha:1];  // light logo on light -> dark
            if (bg) SFAnimate(0.25, ^{ s.backgroundColor = bg.CGColor; });
        });
    });
}
@end

static CGImageRef fadedImage(CGImageRef src) CF_RETURNS_RETAINED;
static CGImageRef fadedImage(CGImageRef src) {
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGContextRef m = CGBitmapContextCreate(NULL, w, h, 8, 0, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    // mask: horizontal 0->1 (left 45 %), multiplied by vertical 1->0 (bottom 45 %)
    uint8_t *mp = CGBitmapContextGetData(m);
    size_t bpr = CGBitmapContextGetBytesPerRow(m);
    for (size_t y = 0; y < h; y++) {
        // bitmap row 0 = top
        double fy = (double)y / h;
        double vy = fy < 0.55 ? 1.0 : MAX(0, 1.0 - (fy - 0.55) / 0.45);
        if (fy < 0.18) vy *= 0.35 + 0.65 * (fy / 0.18);   // darken the top slightly (header/clock readable)
        for (size_t x = 0; x < w; x++) {
            double fx = (double)x / w;
            double vx = fx > 0.45 ? 1.0 : fx / 0.45;
            double a = vx * vx * (3 - 2 * vx) * vy * vy * (3 - 2 * vy);
            mp[y * bpr + x] = (uint8_t)(a * 255);
        }
    }
    CGImageRef mask = CGBitmapContextCreateImage(m);
    CGContextClipToMask(c, CGRectMake(0, 0, w, h), mask);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), src);
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGImageRelease(mask); CGContextRelease(m); CGContextRelease(c); CGColorSpaceRelease(cs);
    return out;
}

@implementation SFImageLayer (Fade)
// `want` = the layer's source (still current?), `loaded` = where the pixels came from (the source
// or its fallback) - the faded result is cached by `loaded`.
- (void)applyFaded:(CGImageRef)img source:(NSString *)want loaded:(NSString *)loaded animated:(BOOL)animated {
    static NSCache *cache;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ cache = [NSCache new]; cache.countLimit = 12; });
    id hit = [cache objectForKey:loaded];
    if (hit) { [self present:hit animated:animated]; return; }
    CGImageRef keep = CGImageRetain(img);
    SFBackground(^{
        CGImageRef f = fadedImage(keep);
        CGImageRelease(keep);
        id obj = (__bridge_transfer id)f;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!obj) return;
            [cache setObject:obj forKey:loaded];
            if ([self.source isEqualToString:want]) [self present:obj animated:YES];
        });
    });
}
@end

CALayer *SFGradientBackground(NSColor *top, NSColor *bottom, CGRect frame) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = frame;
    g.colors = @[(id)top.CGColor, (id)bottom.CGColor];
    g.startPoint = CGPointMake(0.5, 0);   // geometryFlipped root: y=0 at the top
    g.endPoint = CGPointMake(0.5, 0.7);
    return g;
}
