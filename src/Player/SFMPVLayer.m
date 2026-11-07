#import "SFMPVLayer.h"
#import "SFMPVEngine.h"
#import "SFModel.h"
#include <libkern/OSAtomic.h>
#include <pthread.h>

// Reads the FBO into a CGImage (+1). GL returns rows bottom-up.
static CGImageRef devReadImage(GLint fbo, GLint w, GLint h) {
    NSMutableData *px = [NSMutableData dataWithLength:(NSUInteger)w * h * 4];
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px.mutableBytes);
    GLenum err = glGetError();
    // GL returns rows bottom-up, CG expects top first: swap rows
    uint8_t *b = px.mutableBytes; size_t rb = (size_t)w * 4;
    NSMutableData *tmp = [NSMutableData dataWithLength:rb];
    for (GLint y = 0; y < h / 2; y++) {
        memcpy(tmp.mutableBytes, b + y * rb, rb);
        memcpy(b + y * rb, b + (h - 1 - y) * rb, rb);
        memcpy(b + (h - 1 - y) * rb, tmp.mutableBytes, rb);
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate(px.mutableBytes, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef img = bc ? CGBitmapContextCreateImage(bc) : NULL;
    if (bc) CGContextRelease(bc);
    CGColorSpaceRelease(cs);
    if (err != GL_NO_ERROR) SFLog(@"mpv: dev frame read %dx%d fbo=%d glerr=0x%x", w, h, fbo, err);
    return img;
}


static void *glProc(void *ctx, const char *name) {
    static CFBundleRef gl;
    if (!gl) gl = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl"));
    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
    void *p = gl ? CFBundleGetFunctionPointerForName(gl, s) : NULL;
    CFRelease(s);
    return p;
}



// Frames are drawn on CoreAnimation's own display thread (asynchronous layer), at the display's
// refresh, when mpv has a new one - never through the main thread. Before (until 2026-11-07) each
// frame went mpv -> main queue -> setNeedsDisplay -> a draw in the main thread's commit, and the
// render waited there for the frame's display time: every main-thread stall dropped frames (50 fps:
// 1.1 % dropped, decoder 0), and the waits took main-thread time from the UI.
@implementation SFMPVLayer {
    mpv_render_context *_rc;          // guarded by _rcLock (drawn on CA's thread, retired on main)
    pthread_mutex_t _rcLock;
    CGLContextObj _ctx;
    volatile int32_t _frameDue;       // mpv's update callback: something new to draw
    volatile int32_t _forced;         // a draw the layer itself asked for (bounds, still frame retry)
    int _fbRetries;   // CA framebuffer not ready yet: redraw a limited number of times (still frame when paused)
}

- (BOOL)hasRenderContext { return _rc != NULL; }

- (void)dealloc { pthread_mutex_destroy(&_rcLock); }

- (void)setNeedsDisplay {
    OSAtomicOr32Barrier(1, (volatile uint32_t *)&_forced);
    [super setNeedsDisplay];
}

static __weak SFMPVLayer *gDevLayer;   // dev: most recently created layer (for "frameshot")
+ (SFMPVLayer *)devCurrent { return gDevLayer; }

- (instancetype)init {
    if ((self = [super init])) {
        gDevLayer = self;
        pthread_mutex_init(&_rcLock, NULL);
        self.asynchronous = YES;             // CA asks at every refresh (canDrawInCGLContext) - off the main thread
        self.needsDisplayOnBoundsChange = YES;
        self.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        self.opaque = YES;
    }
    return self;
}

- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask {
    CGLPixelFormatAttribute core[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
        kCGLPFADisplayMask, (CGLPixelFormatAttribute)mask, (CGLPixelFormatAttribute)0 };
    CGLPixelFormatObj pf = NULL; GLint n = 0;
    if (CGLChoosePixelFormat(core, &pf, &n) == kCGLNoError && pf) return pf;
    return [super copyCGLPixelFormatForDisplayMask:mask];   // fallback: legacy profile
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pf {
    _ctx = [super copyCGLContextForPixelFormat:pf];
    return _ctx;
}

// Dev: save the current frame as PNG (frameshot command)
- (void)devFrameShot {
    NSString *path = SFMPVDevFrameShotPath;
    if (!path || !_rc || !_ctx) return;   // not this layer (e.g. fallback engine) - the request stays for the playing one
    SFMPVDevFrameShotPath = nil;
    CGImageRef img = [self devCopyFrameOfSize:CGSizeMake(1280, 720)];
    if (!img) return;
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    if (d) { CGImageDestinationAddImage(d, img, NULL); CGImageDestinationFinalize(d); CFRelease(d); }
    CGImageRelease(img);
    SFLog(@"mpv: dev frameshot -> %@", path);
}

// Dev: render the current frame in the layer's GL context into a separate FBO and return it (+1) -
// regardless of whether CoreAnimation draws the (offscreen) window. Used by frameshot and by the
// dev screenshots / dev stream (SFRenderLayerTree), where the GL layer itself renders black.
- (CGImageRef)devCopyFrameOfSize:(CGSize)size {
    if (!SFDevMode || !_rc || !_ctx || size.width < 2 || size.height < 2) {
        if (SFDevMode) SFLog(@"mpv: dev frame unavailable (rc %d ctx %d size %.0fx%.0f)", _rc != NULL, _ctx != NULL, size.width, size.height);
        return NULL;
    }
    pthread_mutex_lock(&_rcLock);   // mpv renders on one thread at a time (CA's display thread draws too)
    if (!_rc) { pthread_mutex_unlock(&_rcLock); return NULL; }
    CGLLockContext(_ctx);
    CGLContextObj prev = CGLGetCurrentContext();
    CGLSetCurrentContext(_ctx);
    // save GL state: the production path reads FBO binding and viewport from the context
    GLint oDraw = 0, oRead = 0, oTex = 0, oVP[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &oDraw);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &oRead);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &oTex);
    glGetIntegerv(GL_VIEWPORT, oVP);
    GLint w = (GLint)size.width, h = (GLint)size.height;
    GLuint tex = 0, fb = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &fb);
    glBindFramebuffer(GL_FRAMEBUFFER, fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    mpv_opengl_fbo f = { .fbo = (int)fb, .w = w, .h = h, .internal_format = GL_RGBA8 };
    int flip = 1, noBlock = 0;
    mpv_render_param p[] = { { MPV_RENDER_PARAM_OPENGL_FBO, &f }, { MPV_RENDER_PARAM_FLIP_Y, &flip },
                             { MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &noBlock }, { MPV_RENDER_PARAM_INVALID, NULL } };
    mpv_render_context_render(_rc, p);
    CGImageRef img = devReadImage((GLint)fb, w, h);
    glDeleteFramebuffers(1, &fb);
    glDeleteTextures(1, &tex);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, oDraw);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, oRead);
    glBindTexture(GL_TEXTURE_2D, oTex);
    glViewport(oVP[0], oVP[1], oVP[2], oVP[3]);
    CGLSetCurrentContext(prev);
    CGLUnlockContext(_ctx);
    pthread_mutex_unlock(&_rcLock);
    return img;
}

static void onUpdate(void *ctx) {
    // mpv thread: something new to draw - CA's display thread picks it up at the next refresh
    SFMPVLayer *l = (__bridge SFMPVLayer *)ctx;
    OSAtomicOr32Barrier(1, (volatile uint32_t *)&l->_frameDue);
    if (SFMPVDevFrameShotPath) dispatch_async(dispatch_get_main_queue(), ^{ [l devFrameShot]; });
}

// CA's display thread, every refresh: draw when mpv has a frame for now (or the layer needs one).
- (BOOL)canDrawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts {
    if (OSAtomicAnd32OrigBarrier(0, (volatile uint32_t *)&_forced)) return YES;
    if (!_rc) return _mpv != NULL;   // the first draw creates the render context
    if (!OSAtomicAnd32OrigBarrier(0, (volatile uint32_t *)&_frameDue)) return NO;
    pthread_mutex_lock(&_rcLock);
    uint64_t flags = _rc ? mpv_render_context_update(_rc) : 0;
    pthread_mutex_unlock(&_rcLock);
    return (flags & MPV_RENDER_UPDATE_FRAME) != 0;
}

- (void)drawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts {
    CGLSetCurrentContext(ctx);
    pthread_mutex_lock(&_rcLock);
    [self drawLocked:ctx];
    pthread_mutex_unlock(&_rcLock);
    [super drawInCGLContext:ctx pixelFormat:pf forLayerTime:t displayTime:ts];
}

// Under _rcLock on CA's display thread: _rc stays valid throughout (retireWithMPV takes the lock).
- (void)drawLocked:(CGLContextObj)ctx {
    if (!_rc && _mpv) {
        mpv_opengl_init_params gp = { .get_proc_address = glProc, .get_proc_address_ctx = NULL };
        mpv_render_param p[] = {
            { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
            { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gp },
            { MPV_RENDER_PARAM_INVALID, NULL },
        };
        int r = mpv_render_context_create(&_rc, _mpv, p);
        if (r < 0) { SFLog(@"mpv: render context: %s", mpv_error_string(r)); _rc = NULL; }
        else {
            mpv_render_context_set_update_callback(_rc, onUpdate, (__bridge void *)self);
            dispatch_block_t ready = self.onRenderContext; self.onRenderContext = nil;
            if (ready) dispatch_async(dispatch_get_main_queue(), ready);
        }
    }
    GLint fbo = 0, vp[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
    glGetIntegerv(GL_VIEWPORT, vp);
    // Don't render without a size or with an incomplete CA framebuffer (first call before appearing) -
    // otherwise mpv reports INVALID_FRAMEBUFFER_OPERATION; the next frame comes anyway.
    BOOL fbOK = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    BOOL rendered = NO;
    if (_rc && fbOK && vp[2] > 0 && vp[3] > 0) {
        rendered = YES; _fbRetries = 0;
        // Error flags from CoreAnimation (e.g. from setting up the layer) are "sticky" and would be
        // reported as mpv's own error - collect them first.
        GLenum stale; int n = 0;
        while ((stale = glGetError()) != GL_NO_ERROR && n++ < 8) if (SFDevMode) SFLog(@"mpv: GL error before rendering: 0x%x", stale);
        mpv_opengl_fbo f = { .fbo = fbo, .w = vp[2], .h = vp[3], .internal_format = 0 };
        int flip = 1;
        mpv_render_param p[] = {
            { MPV_RENDER_PARAM_OPENGL_FBO, &f },
            { MPV_RENDER_PARAM_FLIP_Y, &flip },
            { MPV_RENDER_PARAM_INVALID, NULL },
        };
        mpv_render_context_render(_rc, p);
    } else {
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        // When paused no further frame callback comes: don't leave the still frame black, retry briefly
        if (_rc && _fbRetries < 30) {
            _fbRetries++;
            __weak SFMPVLayer *ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws setNeedsDisplay]; });
        }
    }
    if (rendered) mpv_render_context_report_swap(_rc);
}

// Closing a player blocked the main thread ~300 ms in mpv_render_context_free and
// mpv_terminate_destroy, which wait for the vo and core threads (hitch monitor 2026-11-07, "menu").
// Here the main thread only detaches: _rc goes NULL first under _rcLock, so drawing (CA's display
// thread, under the same lock) never touches it again. The render context is freed on a serial queue with the
// layer's GL context current and locked, before the core it belongs to is destroyed.
- (void)retireWithMPV:(mpv_handle *)mpv {
    static dispatch_queue_t teardown;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ teardown = dispatch_queue_create("sofa.mpv-teardown", DISPATCH_QUEUE_SERIAL); });
    self.mpv = NULL;
    self.onRenderContext = nil;
    pthread_mutex_lock(&_rcLock);   // waits for a draw in progress (at most one frame)
    mpv_render_context *rc = _rc;
    _rc = NULL;
    if (rc) mpv_render_context_set_update_callback(rc, NULL, NULL);
    pthread_mutex_unlock(&_rcLock);
    CGLContextObj ctx = rc && _ctx ? CGLRetainContext(_ctx) : NULL;
    if (!rc && !mpv) return;
    dispatch_async(teardown, ^{
        if (rc) {
            if (ctx) { CGLLockContext(ctx); CGLSetCurrentContext(ctx); }
            mpv_render_context_free(rc);
            if (ctx) { CGLSetCurrentContext(NULL); CGLUnlockContext(ctx); CGLReleaseContext(ctx); }
        }
        if (mpv) mpv_terminate_destroy(mpv);
    });
}
@end

