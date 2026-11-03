#import "SFMPVEngine.h"
#import <dlfcn.h>
#import "SFModel.h"

#pragma mark mpv-Quellen (Seitenkanal vom Resolver zum Player, wie SFSetAlternateURLs)

static NSMutableDictionary *gSources;
void SFSetMPVSource(NSURL *forURL, NSDictionary *source) {
    if (!forURL) return;
    @synchronized ([SFMPVEngine class]) {
        if (!gSources) gSources = [NSMutableDictionary new];
        if (source) gSources[forURL.absoluteString] = source; else [gSources removeObjectForKey:forURL.absoluteString];
        if (gSources.count > 200) [gSources removeAllObjects];
    }
}
NSDictionary *SFMPVSourceFor(NSURL *url) {
    if (!url) return nil;
    @synchronized ([SFMPVEngine class]) { return gSources[url.absoluteString]; }
}

#if __has_include(<mpv/client.h>)
#define SF_HAVE_MPV 1
#import <mpv/client.h>
#import <mpv/render_gl.h>
#import <OpenGL/gl3.h>
#endif

BOOL SFMPVAvailable(void) {
#if SF_HAVE_MPV
    static int v = -1;
    if (v < 0) v = dlsym(RTLD_DEFAULT, "mpv_create") != NULL;   // schwach gelinkt: fehlt die dylib, ist das Symbol NULL
    return v == 1;
#else
    return NO;
#endif
}

#if SF_HAVE_MPV

#pragma mark Video-Ebene

static void *glProc(void *ctx, const char *name) {
    static CFBundleRef gl;
    if (!gl) gl = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl"));
    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
    void *p = gl ? CFBundleGetFunctionPointerForName(gl, s) : NULL;
    CFRelease(s);
    return p;
}

@interface SFMPVLayer : CAOpenGLLayer
@property (nonatomic) mpv_handle *mpv;
- (void)freeRenderContext;
@end

@implementation SFMPVLayer {
    mpv_render_context *_rc;
    CGLContextObj _ctx;
}

- (instancetype)init {
    if ((self = [super init])) {
        self.asynchronous = NO;              // gezeichnet wird auf Anforderung (mpv-Update-Callback)
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
    return [super copyCGLPixelFormatForDisplayMask:mask];   // Fallback: Legacy-Profil
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pf {
    _ctx = [super copyCGLContextForPixelFormat:pf];
    return _ctx;
}

static void onUpdate(void *ctx) {
    // mpv-Thread -> Main: neuer Frame bereit
    SFMPVLayer *l = (__bridge SFMPVLayer *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{ [l setNeedsDisplay]; });
}

- (BOOL)canDrawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts {
    return YES;
}

- (void)drawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts {
    CGLSetCurrentContext(ctx);
    if (!_rc && _mpv) {
        mpv_opengl_init_params gp = { .get_proc_address = glProc, .get_proc_address_ctx = NULL };
        mpv_render_param p[] = {
            { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
            { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gp },
            { MPV_RENDER_PARAM_INVALID, NULL },
        };
        int r = mpv_render_context_create(&_rc, _mpv, p);
        if (r < 0) { SFLog(@"mpv: render context: %s", mpv_error_string(r)); _rc = NULL; }
        else mpv_render_context_set_update_callback(_rc, onUpdate, (__bridge void *)self);
    }
    GLint fbo = 0, vp[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
    glGetIntegerv(GL_VIEWPORT, vp);
    if (_rc && vp[2] > 0 && vp[3] > 0) {   // ohne Größe (vor dem ersten Layout) nicht rendern
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
    }
    [super drawInCGLContext:ctx pixelFormat:pf forLayerTime:t displayTime:ts];
    if (_rc) mpv_render_context_report_swap(_rc);
}

// Muss vor mpv_terminate_destroy laufen, mit aktivem GL-Kontext der Ebene
- (void)freeRenderContext {
    if (!_rc) return;
    mpv_render_context_set_update_callback(_rc, NULL, NULL);
    if (_ctx) CGLSetCurrentContext(_ctx);
    mpv_render_context_free(_rc);
    _rc = NULL;
}
@end

#pragma mark Engine

enum { kPropTime = 1, kPropDuration, kPropPause, kPropCacheWait, kPropEOF, kPropCacheTime };

@implementation SFMPVEngine {
    mpv_handle *_mpv;
    SFMPVLayer *_layer;
    SFEngineStatus _status;
    NSError *_error;
    double _time, _dur, _cacheTime;
    BOOL _paused, _waiting, _eof, _loaded;
    NSTimer *_tick;
}
@synthesize delegate = _delegate, muted = _muted;

- (NSString *)engineName { return @"mpv"; }
- (CALayer *)videoLayer { return _layer; }

static void onWakeup(void *ctx) {
    // mpv-Thread -> Main: Ereignisse abholen. ctx = Engine (lebt, solange der Callback gesetzt ist)
    SFMPVEngine *e = (__bridge SFMPVEngine *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{ [e drainEvents]; });
}

- (instancetype)init {
    if ((self = [super init])) {
        _layer = [SFMPVLayer layer];
        if (!SFMPVAvailable()) return self;
        _mpv = mpv_create();
        if (!_mpv) return self;
        const char *opts[][2] = {
            {"vo", "libmpv"}, {"hwdec", "no"},   // VP9/AV1 nur in Software möglich; H.264 läuft über AVFoundation
            {"ao", "coreaudio"}, {"audio-client-name", "Sofa"},
            {"ytdl", "no"}, {"input-default-bindings", "no"}, {"input-vo-keyboard", "no"}, {"osc", "no"},
            {"terminal", "no"}, {"msg-level", "all=warn"}, {"keep-open", "yes"}, {"idle", "yes"},
            {"cache", "yes"}, {"demuxer-max-bytes", "200MiB"}, {"demuxer-readahead-secs", "30"},
            {"network-timeout", "20"}, {"hr-seek", "yes"}, {"sub-auto", "no"}, {"sid", "no"},
        };
        for (size_t i = 0; i < sizeof opts / sizeof opts[0]; i++) mpv_set_option_string(_mpv, opts[i][0], opts[i][1]);
        int r = mpv_initialize(_mpv);
        if (r < 0) { SFLog(@"mpv: init: %s", mpv_error_string(r)); mpv_terminate_destroy(_mpv); _mpv = NULL; return self; }
        mpv_observe_property(_mpv, kPropTime, "time-pos", MPV_FORMAT_DOUBLE);
        mpv_observe_property(_mpv, kPropDuration, "duration", MPV_FORMAT_DOUBLE);
        mpv_observe_property(_mpv, kPropPause, "pause", MPV_FORMAT_FLAG);
        mpv_observe_property(_mpv, kPropCacheWait, "paused-for-cache", MPV_FORMAT_FLAG);
        mpv_observe_property(_mpv, kPropEOF, "eof-reached", MPV_FORMAT_FLAG);
        mpv_observe_property(_mpv, kPropCacheTime, "demuxer-cache-time", MPV_FORMAT_DOUBLE);
        mpv_request_log_messages(_mpv, "warn");   // mpv-Warnungen/Fehler ins Sofa-Log
        mpv_set_wakeup_callback(_mpv, onWakeup, (__bridge void *)self);
        _layer.mpv = _mpv;
    }
    return self;
}

- (void)command:(NSArray *)args {
    if (!_mpv) return;
    const char *argv[args.count + 1];
    for (NSUInteger i = 0; i < args.count; i++) argv[i] = [args[i] UTF8String];
    argv[args.count] = NULL;
    int r = mpv_command(_mpv, argv);
    if (r < 0) SFLog(@"mpv: %@: %s", args.firstObject, mpv_error_string(r));
}

- (void)openURL:(NSURL *)url audioURL:(NSURL *)audioURL start:(NSTimeInterval)start exact:(BOOL)exact paused:(BOOL)paused {
    _status = SFEngineLoading; _error = nil; _loaded = NO; _eof = NO; _time = 0; _dur = 0; _cacheTime = 0;
    if (!_mpv) { _status = SFEngineFailed; _error = SFError(@"mpv nicht verfügbar"); [self.delegate engineStatusChanged]; return; }
    // Optionen für die nächste Datei (Start, Pause, getrennte Tonspur). URLs enthalten ':' und ',' ->
    // keine Pfadlisten-Syntax, sondern change-list … append (ein Element).
    mpv_set_property_string(_mpv, "start", start > 0 ? [NSString stringWithFormat:@"%.3f", start].UTF8String : "none");
    mpv_set_property_string(_mpv, "hr-seek", exact ? "yes" : "default");
    mpv_set_property_string(_mpv, "pause", paused ? "yes" : "no");
    mpv_set_property_string(_mpv, "mute", _muted ? "yes" : "no");
    [self command:@[@"change-list", @"audio-files", @"clr", @""]];
    if (audioURL) [self command:@[@"change-list", @"audio-files", @"append", audioURL.absoluteString]];
    [self command:@[@"loadfile", url.isFileURL ? url.path : url.absoluteString, @"replace"]];
    [_tick invalidate];
    _tick = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(onTick) userInfo:nil repeats:YES];
}

- (void)onTick { if (_loaded) [self.delegate engineTick]; }

- (void)drainEvents {
    while (_mpv) {
        mpv_event *ev = mpv_wait_event(_mpv, 0);
        if (!ev || ev->event_id == MPV_EVENT_NONE) break;
        switch (ev->event_id) {
            case MPV_EVENT_FILE_LOADED:
                _loaded = YES; _status = SFEngineReady;
                [self.delegate engineStatusChanged];
                break;
            case MPV_EVENT_END_FILE: {
                mpv_event_end_file *ef = ev->data;
                if (ef && ef->reason == MPV_END_FILE_REASON_ERROR) {
                    BOOL wasLoaded = _loaded;
                    _status = SFEngineFailed; _loaded = NO;
                    _error = SFError([NSString stringWithFormat:@"mpv: %s", mpv_error_string(ef->error)]);
                    SFLog(@"mpv: Fehler %s", mpv_error_string(ef->error));
                    if (wasLoaded) [self.delegate engineInterrupted]; else [self.delegate engineStatusChanged];
                }
                break;
            }
            case MPV_EVENT_PROPERTY_CHANGE: {
                mpv_event_property *p = ev->data;
                BOOL has = p->format != MPV_FORMAT_NONE && p->data;
                switch (ev->reply_userdata) {
                    case kPropTime: _time = has ? *(double *)p->data : 0; break;
                    case kPropDuration: _dur = has ? *(double *)p->data : 0; break;
                    case kPropCacheTime: _cacheTime = has ? *(double *)p->data : 0; break;
                    case kPropPause: _paused = has && *(int *)p->data; [self.delegate engineRateChanged]; break;
                    case kPropCacheWait: _waiting = has && *(int *)p->data; [self.delegate engineBufferingChanged]; [self.delegate engineRateChanged]; break;
                    case kPropEOF: {
                        BOOL eof = has && *(int *)p->data;
                        if (eof && !_eof && _loaded) { _eof = YES; [self.delegate engineRateChanged]; [self.delegate engineDidEnd]; }
                        else if (!eof) _eof = NO;
                        break;
                    }
                }
                break;
            }
            case MPV_EVENT_LOG_MESSAGE: {
                mpv_event_log_message *lm = ev->data;
                NSString *t = [[NSString stringWithUTF8String:lm->text ?: ""] stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                SFLog(@"mpv[%s/%s]: %@", lm->prefix, lm->level, t);
                break;
            }
            default: break;
        }
    }
}

- (SFEngineStatus)status { return _status; }
- (NSError *)error { return _error; }
- (BOOL)playing { return _loaded && !_paused && !_eof; }   // wie AVPlayer.rate: auch beim Nachladen "läuft"
- (BOOL)likelyToKeepUp { return !_waiting; }
- (NSTimeInterval)currentTime { return _time > 0 ? _time : 0; }
- (NSTimeInterval)duration { return _dur > 0 ? _dur : 0; }
- (NSTimeInterval)bufferedUntil { return _cacheTime; }
- (void)setMuted:(BOOL)m { _muted = m; if (_mpv) mpv_set_property_string(_mpv, "mute", m ? "yes" : "no"); }

- (void)play { if (_mpv) mpv_set_property_string(_mpv, "pause", "no"); }
- (void)pause { if (_mpv) mpv_set_property_string(_mpv, "pause", "yes"); }
- (void)seekTo:(NSTimeInterval)t exact:(BOOL)exact {
    _eof = NO;
    [self command:@[@"seek", [NSString stringWithFormat:@"%.3f", MAX(0, t)], exact ? @"absolute+exact" : @"absolute"]];
}

- (void)close {
    [_tick invalidate]; _tick = nil;
    if (!_mpv) return;
    [self command:@[@"stop"]];
    _loaded = NO; _status = SFEngineLoading;
}

- (void)shutdown {
    [_tick invalidate]; _tick = nil;
    if (!_mpv) return;
    mpv_set_wakeup_callback(_mpv, NULL, NULL);
    _layer.mpv = NULL;
    [_layer freeRenderContext];          // vor terminate (GL-Kontext der Ebene)
    mpv_terminate_destroy(_mpv);
    _mpv = NULL;
}

- (void)dealloc { [self shutdown]; }
@end

#else   // ohne mpv-Header gebaut: Stub (SFMPVAvailable() == NO)

@implementation SFMPVEngine
@synthesize delegate = _delegate, muted = _muted;
- (NSString *)engineName { return @"mpv (nicht verfügbar)"; }
- (CALayer *)videoLayer { return nil; }
- (SFEngineStatus)status { return SFEngineFailed; }
- (NSError *)error { return SFError(@"mpv nicht verfügbar"); }
- (BOOL)playing { return NO; }
- (BOOL)likelyToKeepUp { return YES; }
- (NSTimeInterval)currentTime { return 0; }
- (NSTimeInterval)duration { return 0; }
- (NSTimeInterval)bufferedUntil { return 0; }
- (void)openURL:(NSURL *)u audioURL:(NSURL *)a start:(NSTimeInterval)s exact:(BOOL)e paused:(BOOL)p {
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate engineStatusChanged]; });
}
- (void)play {}
- (void)pause {}
- (void)seekTo:(NSTimeInterval)t exact:(BOOL)e {}
- (void)close {}
- (void)shutdown {}
@end

#endif
