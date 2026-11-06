#import "SFMPVEngine.h"
#import <dlfcn.h>
#import "SFModel.h"

#pragma mark mpv sources (side channel from the resolver to the player, like SFSetAlternateURLs)

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

#import "SFMPVLayer.h"

NSString *SFMPVDevFrameShotPath = nil;



BOOL SFMPVAvailable(void) {
#if SF_HAVE_MPV
    static int v = -1;
    if (v < 0) v = dlsym(RTLD_DEFAULT, "mpv_create") != NULL;   // weakly linked: if the dylib is missing, the symbol is NULL
    return v == 1;
#else
    return NO;
#endif
}

#if SF_HAVE_MPV

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
    dispatch_block_t _pendingLoad;   // loadfile deferred until the layer has a render context
    NSInteger _voHeals, _voDownTicks; // self-healing of a dead video output (audio-only playback)
    double _stallTime;                // stall watchdog: position at _stallSince
    NSDate *_stallSince;
    BOOL _stallFired;
}

// Playback that should run but makes no progress for this long counts as failed, so the player's
// fallback chain takes over. 2026-11-05: the SABR sidecar died during playback; mpv's HTTP
// reconnects hit "connection refused" and a seek then hung forever with no error event.
static NSTimeInterval SFStallLimit(void) {
    static NSTimeInterval t; static dispatch_once_t o;
    dispatch_once(&o, ^{ t = SFDevSeconds(@"SOFA_STALL_LIMIT", 45); });   // tests shorten it
    return t;
}
@synthesize delegate = _delegate, muted = _muted;

- (NSString *)engineName { return @"mpv"; }
- (CALayer *)videoLayer { return _layer; }

static void onWakeup(void *ctx) {
    // mpv thread -> main: fetch events. ctx = engine (alive as long as the callback is set)
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
            {"vo", "libmpv"}, {"hwdec", "no"},   // videotoolbox hwaccel fails on 10.9 (measured 2026-11-04)
            {"ao", "coreaudio"}, {"audio-client-name", "Sofa"},
            {"ytdl", "no"}, {"input-default-bindings", "no"}, {"input-vo-keyboard", "no"}, {"osc", "no"},
            {"terminal", "no"}, {"msg-level", "all=warn"}, {"keep-open", "yes"}, {"idle", "yes"},
            {"cache", "yes"}, {"demuxer-max-bytes", "200MiB"}, {"demuxer-readahead-secs", "30"},
            {"network-timeout", "20"}, {"hr-seek", "yes"}, {"sub-auto", "no"}, {"sid", "no"},
        };
        for (size_t i = 0; i < sizeof opts / sizeof opts[0]; i++) mpv_set_option_string(_mpv, opts[i][0], opts[i][1]);
        // Deliberately without TLS certificate verification (ffmpeg default tls_verify=0, user decision
        // 2026-11-04): pure media data, an outdated CA bundle on the frozen 10.9 must never break
        // playback. Code (updater, yt-dlp/pip, node) is still loaded with verification.
        int r = mpv_initialize(_mpv);
        if (r < 0) { SFLog(@"mpv: init: %s", mpv_error_string(r)); mpv_terminate_destroy(_mpv); _mpv = NULL; return self; }
        mpv_observe_property(_mpv, kPropTime, "time-pos", MPV_FORMAT_DOUBLE);
        mpv_observe_property(_mpv, kPropDuration, "duration", MPV_FORMAT_DOUBLE);
        mpv_observe_property(_mpv, kPropPause, "pause", MPV_FORMAT_FLAG);
        mpv_observe_property(_mpv, kPropCacheWait, "paused-for-cache", MPV_FORMAT_FLAG);
        mpv_observe_property(_mpv, kPropEOF, "eof-reached", MPV_FORMAT_FLAG);
        mpv_observe_property(_mpv, kPropCacheTime, "demuxer-cache-time", MPV_FORMAT_DOUBLE);
        mpv_request_log_messages(_mpv, "warn");   // mpv warnings/errors into the Sofa log
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
    _stallSince = nil; _stallFired = NO;
    if (!_mpv) { _status = SFEngineFailed; _error = SFError(@"mpv nicht verfügbar"); [self.delegate engineStatusChanged]; return; }
    // Options for the next file (start, pause, separate audio track). URLs contain ':' and ',' ->
    // no path-list syntax, but change-list ... append (one element).
    mpv_set_property_string(_mpv, "start", start > 0 ? [NSString stringWithFormat:@"%.3f", start].UTF8String : "none");
    mpv_set_property_string(_mpv, "hr-seek", exact ? "yes" : "default");
    mpv_set_property_string(_mpv, "pause", paused ? "yes" : "no");
    mpv_set_property_string(_mpv, "mute", _muted ? "yes" : "no");
    [self command:@[@"change-list", @"audio-files", @"clr", @""]];
    if (audioURL) [self command:@[@"change-list", @"audio-files", @"append", audioURL.absoluteString]];
    _voHeals = 0; _voDownTicks = 0;
    // mpv must not open the file before the render context exists: otherwise libmpv's vo fails
    // ("No render context set"), mpv drops the video track and plays audio only (seen 2026-11-04
    // after an update restart, when the local file resumed within 30 ms of launch).
    NSString *target = url.isFileURL ? url.path : url.absoluteString;
    __weak SFMPVEngine *ws = self;
    _pendingLoad = [^{ [ws command:@[@"loadfile", target, @"replace"]]; } copy];
    if (_layer.hasRenderContext) [self flushPendingLoad];
    else {
        _layer.onRenderContext = ^{ [ws flushPendingLoad]; };
        [_layer setNeedsDisplay];
        // Fallback: never stay silent – load after 3 s anyway (the tick below heals the video later)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SFMPVEngine *s = ws;
            if (s && s->_pendingLoad) { SFLog(@"mpv: no render context after 3 s - loading anyway"); [s flushPendingLoad]; }
        });
    }
    [_tick invalidate];
    _tick = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(onTick) userInfo:nil repeats:YES];
}

- (NSString *)prop:(NSString *)name {
    if (!_mpv) return nil;
    char *v = mpv_get_property_string(_mpv, name.UTF8String);
    NSString *s = v ? @(v) : nil;
    if (v) mpv_free(v);
    return s;
}

- (NSArray *)tracksOfType:(NSString *)type {
    NSMutableArray *out = [NSMutableArray new];
    NSInteger n = [[self prop:@"track-list/count"] integerValue];
    for (NSInteger i = 0; i < n; i++) {
        NSString *(^p)(NSString *) = ^NSString *(NSString *k) { return [self prop:[NSString stringWithFormat:@"track-list/%ld/%@", (long)i, k]]; };
        if (![p(@"type") isEqualToString:type]) continue;
        NSMutableDictionary *t = [NSMutableDictionary new];
        t[@"id"] = @([p(@"id") integerValue]);
        t[@"selected"] = @([p(@"selected") isEqualToString:@"yes"]);
        if (p(@"lang").length) t[@"lang"] = p(@"lang");
        if (p(@"title").length) t[@"title"] = p(@"title");
        if ([p(@"external") isEqualToString:@"yes"] && p(@"external-filename").length) t[@"url"] = p(@"external-filename");
        [out addObject:t];
    }
    return out;
}

- (void)selectTrack:(NSString *)type trackID:(NSInteger)tid {
    if (!_mpv) return;
    NSString *prop = [type isEqualToString:@"sub"] ? @"sid" : @"aid";
    mpv_set_property_string(_mpv, prop.UTF8String, tid > 0 ? @(tid).stringValue.UTF8String : "no");
}

- (void)addTrack:(NSString *)type url:(NSURL *)url title:(NSString *)title lang:(NSString *)lang {
    if (!_mpv || !url) return;
    for (NSDictionary *t in [self tracksOfType:type])
        if ([t[@"url"] isEqualToString:url.absoluteString]) { [self selectTrack:type trackID:[t[@"id"] integerValue]]; return; }
    [self command:@[[type isEqualToString:@"sub"] ? @"sub-add" : @"audio-add", url.absoluteString, @"select", title ?: @"", lang ?: @""]];
}

- (void)setProp:(NSString *)name value:(NSString *)value { if (_mpv) mpv_set_property_string(_mpv, name.UTF8String, value.UTF8String); }

- (void)flushPendingLoad {
    dispatch_block_t b = _pendingLoad; _pendingLoad = nil;
    if (b) b();
}

- (void)onTick {
    [self watchStall];
    if (!_loaded || _stallFired) return;
    [self healVideoOutput];
    [self.delegate engineTick];
}

- (void)watchStall {
    if (_stallFired || _status == SFEngineFailed) return;
    BOOL shouldRun = !_paused && !_eof;   // loading counts too: an open that never finishes is a stall
    if (!shouldRun || _time != _stallTime || !_stallSince) { _stallTime = _time; _stallSince = [NSDate date]; return; }
    if (-[_stallSince timeIntervalSinceNow] < SFStallLimit()) return;
    _stallFired = YES;
    SFLog(@"mpv: no progress for %.0f s at %.1f s (%@) - treating as failed", SFStallLimit(), _time, _loaded ? @"playing" : @"loading");
    _status = SFEngineFailed; _loaded = NO;
    _error = SFError(@"Die Wiedergabe hängt.");
    [self.delegate engineStatusChanged];
}

// Self-healing: the file has a video track but no video output is configured (vo init failed,
// e.g. a render-context race) -> re-select the video track so mpv re-creates the vo. Up to 3 tries.
- (void)healVideoOutput {
    if (_voHeals >= 3 || !_layer.hasRenderContext) return;
    BOOL hasVideo = NO;
    NSInteger n = [[self prop:@"track-list/count"] integerValue];
    for (NSInteger i = 0; i < n && !hasVideo; i++)
        hasVideo = [[self prop:[NSString stringWithFormat:@"track-list/%ld/type", (long)i]] isEqualToString:@"video"]
                   && ![[self prop:[NSString stringWithFormat:@"track-list/%ld/albumart", (long)i]] isEqualToString:@"yes"];
    if (!hasVideo || [[self prop:@"vo-configured"] isEqualToString:@"yes"]) { _voDownTicks = 0; return; }
    if (++_voDownTicks < 3) return;   // allow ~1.5 s for normal vo start-up
    _voDownTicks = 0; _voHeals++;
    SFLog(@"mpv: video output missing although the file has video - re-selecting video track (attempt %ld)", (long)_voHeals);
    mpv_set_property_string(_mpv, "vid", "no");
    mpv_set_property_string(_mpv, "vid", "auto");
}

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
                    SFLog(@"mpv: error %s", mpv_error_string(ef->error));
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
- (BOOL)playing { return _loaded && !_paused && !_eof; }   // like AVPlayer.rate: "running" while buffering too
- (BOOL)likelyToKeepUp { return !_waiting; }
- (NSTimeInterval)currentTime { return _time > 0 ? _time : 0; }
- (NSTimeInterval)duration { return _dur > 0 ? _dur : 0; }
- (NSTimeInterval)bufferedUntil { return _cacheTime; }
- (CGSize)videoSize {
    double w = [[self prop:@"dwidth"] doubleValue], h = [[self prop:@"dheight"] doubleValue];
    return w > 0 && h > 0 ? CGSizeMake(w, h) : CGSizeZero;
}
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
    [_layer freeRenderContext];          // before terminate (the layer's GL context)
    mpv_terminate_destroy(_mpv);
    _mpv = NULL;
}

- (void)dealloc { [self shutdown]; }
@end

#else   // built without mpv headers: stub (SFMPVAvailable() == NO)

@implementation SFMPVEngine
@synthesize delegate = _delegate, muted = _muted;
- (NSString *)engineName { return @"mpv (not available)"; }
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

void SFMPVDevFrameShot(NSString *path) {
#if SF_HAVE_MPV
    SFMPVDevFrameShotPath = path;
    dispatch_async(dispatch_get_main_queue(), ^{ [[SFMPVLayer devCurrent] devFrameShot]; });
#else
    SFLog(@"mpv: built without libmpv - no frameshot");
#endif
}
