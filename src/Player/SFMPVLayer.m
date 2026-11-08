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



// Rendering runs on a thread of its own (2026-11-08): mpv draws each frame on the render queue into
// one of two textures of a private GL context that shares its objects with CoreAnimation's. CA's
// draw - on 10.9 a timer on the MAIN run loop (CAOpenGLLayer_timer_callback) - only copies the newest
// texture into its framebuffer (glBlitFramebuffer). Until then mpv rendered inside CA's draw: the
// first frame's shader setup and every frame's texture upload were main-thread time (115-250 ms on
// a player's first frame, hitch monitor 2026-11-07), and the draw waited on mpv's locks.
// Fences order the two contexts: CA waits for a texture's rendering before copying it, the render
// queue waits for CA's copy before drawing into that texture again.
typedef struct {
    GLuint tex;
    GLint w, h;
    GLsync written;   // render queue: the frame in tex is complete on the GPU after this
    GLsync read;      // CA: its copy of tex is complete after this
} SFVideoBuffer;

@implementation SFMPVLayer {
    mpv_render_context *_rc;          // guarded by _rcLock (rendered on the render queue, retired on main)
    pthread_mutex_t _rcLock;
    CGLContextObj _rctx;              // the render queue's context; CA's contexts share its textures
    GLuint _fbo;                      // _rctx: mpv's target, the back texture attached
    SFVideoBuffer _buf[2];            // guarded by _bufLock
    int _front;                       // the buffer CA shows, -1 = no frame yet
    pthread_mutex_t _bufLock;
    CGLContextObj _readCtx;           // CA's context the read FBOs below belong to
    GLuint _readFbo[2];
    volatile int32_t _pxW, _pxH;      // CA's framebuffer size: the size frames are rendered at
    volatile int32_t _redraw;         // render the current frame again (new size, before a size was known)
    volatile int32_t _newFrame;       // a frame CA has not shown yet
    volatile int32_t _forced;         // a draw the layer itself asked for (bounds)
    volatile int32_t _serviceQueued;  // a render-queue pass is pending (coalesces mpv's callbacks)
}

- (BOOL)hasRenderContext { return _rc != NULL; }

static CGLPixelFormatObj SFCorePixelFormat(uint32_t displayMask) {
    CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
        displayMask ? kCGLPFADisplayMask : (CGLPixelFormatAttribute)0, (CGLPixelFormatAttribute)displayMask, (CGLPixelFormatAttribute)0 };
    CGLPixelFormatObj pf = NULL; GLint n = 0;
    return CGLChoosePixelFormat(a, &pf, &n) == kCGLNoError ? pf : NULL;
}

// mpv's work (frames, reconfiguring the output, controls) runs on this queue at once, with the
// render context - independent of CA, which draws only a layer on screen: with the display asleep
// or the window offscreen the core used to stall, and with it every property read on the main
// thread (3.4 s in mpv_get_property_string, 2026-11-07). Lock order: _rctx, _rcLock, _bufLock.
static dispatch_queue_t RenderQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("sofa.mpv-render", DISPATCH_QUEUE_SERIAL); });
    return q;
}

- (void)kick {
    if (!OSAtomicOr32OrigBarrier(1, (volatile uint32_t *)&_serviceQueued))
        dispatch_async(RenderQueue(), ^{ [self serviceRenderWork]; });
}

- (void)dealloc {
    if (_rctx) {
        CGLLockContext(_rctx);
        CGLContextObj prev = CGLGetCurrentContext();
        CGLSetCurrentContext(_rctx);
        for (int i = 0; i < 2; i++) {
            if (_buf[i].tex) glDeleteTextures(1, &_buf[i].tex);
            if (_buf[i].written) glDeleteSync(_buf[i].written);
            if (_buf[i].read) glDeleteSync(_buf[i].read);
        }
        if (_fbo) glDeleteFramebuffers(1, &_fbo);
        CGLSetCurrentContext(prev);
        CGLUnlockContext(_rctx);
        CGLReleaseContext(_rctx);
    }
    pthread_mutex_destroy(&_rcLock);
    pthread_mutex_destroy(&_bufLock);
}

- (void)setMpv:(mpv_handle *)mpv {
    _mpv = mpv;
    if (mpv) [self kick];   // the render context, right away (the file loads once it exists)
}

// A draw at the next refresh (canDraw asks every refresh of a layer on screen). super's draws in
// the main thread's next commit, holding up the commit; only the first draw goes that way: CA asks
// a layer off screen (an offscreen window) only when told to.
- (void)setNeedsDisplay {
    OSAtomicOr32Barrier(1, (volatile uint32_t *)&_forced);
    if (_front < 0) [super setNeedsDisplay];
}
- (void)setNeedsDisplayInRect:(CGRect)r {   // super's setNeedsDisplay ends up here
    OSAtomicOr32Barrier(1, (volatile uint32_t *)&_forced);
    if (_front < 0) [super setNeedsDisplayInRect:r];
}

// The size frames are rendered at, known before CA's first draw (bounds x scale): the first frame
// does not wait for CA. CA's framebuffer size (its draw) has the last word.
- (void)targetSizeChanged {
    CGFloat sc = self.contentsScale > 0 ? self.contentsScale : 1;
    int32_t w = (int32_t)lround(self.bounds.size.width * sc), h = (int32_t)lround(self.bounds.size.height * sc);
    if (w <= 0 || h <= 0 || (w == _pxW && h == _pxH)) return;
    OSAtomicCompareAndSwap32Barrier(_pxW, w, &_pxW);
    OSAtomicCompareAndSwap32Barrier(_pxH, h, &_pxH);
    OSAtomicOr32Barrier(1, (volatile uint32_t *)&_redraw);
    [self kick];
    [self setNeedsDisplay];
}
- (void)setBounds:(CGRect)b { [super setBounds:b]; [self targetSizeChanged]; }
- (void)setContentsScale:(CGFloat)s { [super setContentsScale:s]; [self targetSizeChanged]; }

static __weak SFMPVLayer *gDevLayer;   // dev: most recently created layer (for "frameshot")
+ (SFMPVLayer *)devCurrent { return gDevLayer; }

- (instancetype)init {
    if ((self = [super init])) {
        gDevLayer = self;
        pthread_mutex_init(&_rcLock, NULL);
        pthread_mutex_init(&_bufLock, NULL);
        _front = -1;
        CGLPixelFormatObj pf = SFCorePixelFormat(0);
        if (pf) { CGLCreateContext(pf, NULL, &_rctx); CGLReleasePixelFormat(pf); }
        if (!_rctx) SFLog(@"mpv: no OpenGL 3.2 context - no video");
        self.asynchronous = YES;             // CA asks at every refresh (canDrawInCGLContext) while on screen
        self.needsDisplayOnBoundsChange = NO;   // the draw notices the new size and asks for a frame at it
        self.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        self.opaque = YES;
    }
    return self;
}

- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask {
    return SFCorePixelFormat(mask) ?: [super copyCGLPixelFormatForDisplayMask:mask];
}

// CA's context shares the render context's objects (textures, fences): the frames are there
- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pf {
    CGLContextObj ctx = NULL;
    if (_rctx && CGLCreateContext(pf, _rctx, &ctx) == kCGLNoError && ctx) return ctx;
    SFLog(@"mpv: CoreAnimation's context cannot share the render context - no video");
    return [super copyCGLContextForPixelFormat:pf];
}

// Dev: save the current frame as PNG (frameshot command)
- (void)devFrameShot {
    NSString *path = SFMPVDevFrameShotPath;
    if (!path || !_rc || !_rctx) return;   // not this layer - the request stays for the playing one
    SFMPVDevFrameShotPath = nil;
    CGImageRef img = [self devCopyFrameOfSize:CGSizeMake(1280, 720)];
    if (!img) return;
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    if (d) { CGImageDestinationAddImage(d, img, NULL); CGImageDestinationFinalize(d); CFRelease(d); }
    CGImageRelease(img);
    SFLog(@"mpv: dev frameshot -> %@", path);
}

// Dev: render the current frame in the render context into a separate FBO and return it (+1) -
// regardless of whether CoreAnimation draws the (offscreen) window. Used by frameshot and by the
// dev screenshots / dev stream (SFRenderLayerTree), where the GL layer itself renders black.
- (CGImageRef)devCopyFrameOfSize:(CGSize)size {
    if (!SFDevMode || !_rc || !_rctx || size.width < 2 || size.height < 2) {
        if (SFDevMode) SFLog(@"mpv: dev frame unavailable (rc %d ctx %d size %.0fx%.0f)", _rc != NULL, _rctx != NULL, size.width, size.height);
        return NULL;
    }
    CGLLockContext(_rctx);
    pthread_mutex_lock(&_rcLock);
    if (!_rc) { pthread_mutex_unlock(&_rcLock); CGLUnlockContext(_rctx); return NULL; }
    CGLContextObj prev = CGLGetCurrentContext();
    CGLSetCurrentContext(_rctx);
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
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers(1, &fb);
    glDeleteTextures(1, &tex);
    CGLSetCurrentContext(prev);
    pthread_mutex_unlock(&_rcLock);
    CGLUnlockContext(_rctx);
    OSAtomicOr32Barrier(1, (volatile uint32_t *)&_redraw);   // the shown texture is unaffected; render the next one anew anyway
    [self kick];
    return img;
}

- (void)createRenderContextLocked {
    mpv_opengl_init_params gp = { .get_proc_address = glProc, .get_proc_address_ctx = NULL };
    mpv_render_param p[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gp },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    int r = mpv_render_context_create(&_rc, _mpv, p);
    if (r < 0) { SFLog(@"mpv: render context: %s", mpv_error_string(r)); _rc = NULL; return; }
    mpv_render_context_set_update_callback(_rc, onUpdate, (__bridge void *)self);
    dispatch_block_t ready = self.onRenderContext; self.onRenderContext = nil;
    if (ready) dispatch_async(dispatch_get_main_queue(), ready);
}

// Render queue: mpv's queued work, and a frame into the back buffer when there is a new one (or the
// size changed) - then it becomes the front buffer and CA's next refresh copies it.
- (void)serviceRenderWork {
    OSAtomicAnd32Barrier(0, (volatile uint32_t *)&_serviceQueued);
    if (!_rctx) return;
    CGLLockContext(_rctx);
    pthread_mutex_lock(&_rcLock);
    CGLContextObj prev = CGLGetCurrentContext();
    CGLSetCurrentContext(_rctx);
    if (!_rc && _mpv) [self createRenderContextLocked];
    if (_rc) {
        uint64_t flags = mpv_render_context_update(_rc);
        BOOL redraw = OSAtomicAnd32OrigBarrier(0, (volatile uint32_t *)&_redraw) != 0;
        if ((flags & MPV_RENDER_UPDATE_FRAME) || redraw) [self renderFrameLocked];
    }
    CGLSetCurrentContext(prev);
    pthread_mutex_unlock(&_rcLock);
    CGLUnlockContext(_rctx);
}

- (void)renderFrameLocked {
    GLint w = _pxW, h = _pxH;
    if (w <= 0 || h <= 0) { OSAtomicOr32Barrier(1, (volatile uint32_t *)&_redraw); return; }   // CA's first draw tells the size
    pthread_mutex_lock(&_bufLock);   // CA may be copying the front buffer right now: wait for its fence
    int back = _front == 0 ? 1 : 0;
    GLsync read = _buf[back].read; _buf[back].read = NULL;
    pthread_mutex_unlock(&_bufLock);
    if (read) { glWaitSync(read, 0, GL_TIMEOUT_IGNORED); glDeleteSync(read); }
    SFVideoBuffer *b = &_buf[back];
    if (!b->tex) glGenTextures(1, &b->tex);
    glBindTexture(GL_TEXTURE_2D, b->tex);
    if (b->w != w || b->h != h) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        b->w = w; b->h = h;
    }
    glBindTexture(GL_TEXTURE_2D, 0);
    if (!_fbo) glGenFramebuffers(1, &_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, b->tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        SFLog(@"mpv: render target %dx%d incomplete", w, h);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        return;
    }
    // Not blocking for the frame's target time: mpv's video thread hands each frame over when it
    // is due; blocking waited on that thread - one shutting down held the render for mpv's 200 ms
    // timeout on every player close (hitch monitor, 2026-11-07).
    mpv_opengl_fbo f = { .fbo = (int)_fbo, .w = w, .h = h, .internal_format = GL_RGBA8 };
    int flip = 1, noBlock = 0;
    mpv_render_param p[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &f },
        { MPV_RENDER_PARAM_FLIP_Y, &flip },
        { MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &noBlock },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    mpv_render_context_render(_rc, p);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    GLsync written = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    glFlush();   // the fence must reach the GPU before another context waits for it
    pthread_mutex_lock(&_bufLock);
    if (b->written) glDeleteSync(b->written);
    b->written = written;
    _front = back;
    pthread_mutex_unlock(&_bufLock);
    mpv_render_context_report_swap(_rc);
    OSAtomicOr32Barrier(1, (volatile uint32_t *)&_newFrame);
}

static void onUpdate(void *ctx) {
    // mpv thread: a new frame or work for the render thread - both run on the render queue now
    SFMPVLayer *l = (__bridge SFMPVLayer *)ctx;
    [l kick];
    if (SFMPVDevFrameShotPath) dispatch_async(dispatch_get_main_queue(), ^{ [l devFrameShot]; });
}

// CA's refresh timer: draw when a frame is waiting (or the layer asked for a draw). Main thread on
// 10.9: nothing here touches mpv.
- (BOOL)canDrawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts {
    BOOL forced = OSAtomicAnd32OrigBarrier(0, (volatile uint32_t *)&_forced) != 0;
    BOOL fresh = OSAtomicAnd32OrigBarrier(0, (volatile uint32_t *)&_newFrame) != 0;
    return forced || fresh;
}

// Copies the front buffer into CA's framebuffer (scaled if the size just changed; the render
// queue renders the next frame at the new size).
- (void)drawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts {
    CGLSetCurrentContext(ctx);
    GLint fbo = 0, vp[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
    glGetIntegerv(GL_VIEWPORT, vp);
    if (vp[2] > 0 && vp[3] > 0 && (vp[2] != _pxW || vp[3] != _pxH)) {
        OSAtomicCompareAndSwap32Barrier(_pxW, vp[2], &_pxW);
        OSAtomicCompareAndSwap32Barrier(_pxH, vp[3], &_pxH);
        OSAtomicOr32Barrier(1, (volatile uint32_t *)&_redraw);
        [self kick];
    } else if (_redraw) [self kick];   // a frame came before the size was known
    if (_readCtx != ctx) { _readCtx = ctx; _readFbo[0] = _readFbo[1] = 0; }   // FBOs belong to one context (CA's old one is gone)
    pthread_mutex_lock(&_bufLock);
    int i = _front;
    if (i >= 0 && _buf[i].tex) {
        SFVideoBuffer *b = &_buf[i];
        if (b->written) glWaitSync(b->written, 0, GL_TIMEOUT_IGNORED);
        if (!_readFbo[i]) glGenFramebuffers(1, &_readFbo[i]);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, _readFbo[i]);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, b->tex, 0);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)fbo);
        glBlitFramebuffer(0, 0, b->w, b->h, 0, 0, vp[2], vp[3], GL_COLOR_BUFFER_BIT, GL_LINEAR);
        if (b->read) glDeleteSync(b->read);
        b->read = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)fbo);
    } else {
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    pthread_mutex_unlock(&_bufLock);
    [super drawInCGLContext:ctx pixelFormat:pf forLayerTime:t displayTime:ts];
}

// Closing a player blocked the main thread ~300 ms in mpv_render_context_free and
// mpv_terminate_destroy, which wait for the vo and core threads (hitch monitor 2026-11-07, "menu").
// The main thread only lets go: the render context is detached on the render queue itself - after
// a render in progress, without the main thread waiting for it (taking _rcLock here waited for a
// first frame's shader setup, test-playback 2026-11-08) - then freed on the teardown queue with the
// render context current and locked, before the core it belongs to is destroyed. The block keeps
// the layer alive until mpv's update callback (which points at it) is gone. The last frame stays.
- (void)retireWithMPV:(mpv_handle *)mpv {
    static dispatch_queue_t teardown;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ teardown = dispatch_queue_create("sofa.mpv-teardown", DISPATCH_QUEUE_SERIAL); });
    _mpv = NULL;
    self.onRenderContext = nil;
    dispatch_async(RenderQueue(), ^{
        pthread_mutex_lock(&self->_rcLock);
        mpv_render_context *rc = self->_rc;
        self->_rc = NULL;
        if (rc) mpv_render_context_set_update_callback(rc, NULL, NULL);
        pthread_mutex_unlock(&self->_rcLock);
        if (!rc && !mpv) return;
        CGLContextObj ctx = rc && self->_rctx ? CGLRetainContext(self->_rctx) : NULL;
        dispatch_async(teardown, ^{
            if (rc) {
                if (ctx) { CGLLockContext(ctx); CGLSetCurrentContext(ctx); }
                mpv_render_context_free(rc);
                if (ctx) { CGLSetCurrentContext(NULL); CGLUnlockContext(ctx); CGLReleaseContext(ctx); }
            }
            if (mpv) mpv_terminate_destroy(mpv);
        });
    });
}
@end
