#import "SFMPVEngine.h"
#import "SFSettings.h"
#import "SFModel.h"
#import "SFUserAgent.h"

#pragma mark mpv sources (side channel from the resolver to the player)

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



#pragma mark Engine

enum { kPropTime = 1, kPropDuration, kPropPause, kPropCacheWait, kPropEOF, kPropCacheTime,
       kPropTracks, kPropVOConfigured, kPropWidth, kPropHeight };

// mpv's track-list node -> [{type, id, selected, lang?, title?, url? (external file), albumart}]
static NSArray *SFTracksFromNode(const mpv_node *list) {
    NSMutableArray *out = [NSMutableArray new];
    if (!list || list->format != MPV_FORMAT_NODE_ARRAY) return out;
    for (int i = 0; i < list->u.list->num; i++) {
        const mpv_node *m = &list->u.list->values[i];
        if (m->format != MPV_FORMAT_NODE_MAP) continue;
        NSMutableDictionary *t = [NSMutableDictionary new];
        NSString *externalFile = nil; BOOL external = NO;
        for (int j = 0; j < m->u.list->num; j++) {
            const char *k = m->u.list->keys[j];
            const mpv_node *v = &m->u.list->values[j];
            if (v->format == MPV_FORMAT_STRING) {
                NSString *str = @(v->u.string);
                if (!strcmp(k, "type")) t[@"type"] = str;
                else if (!strcmp(k, "lang") && str.length) t[@"lang"] = str;
                else if (!strcmp(k, "title") && str.length) t[@"title"] = str;
                else if (!strcmp(k, "external-filename") && str.length) externalFile = str;
            } else if (v->format == MPV_FORMAT_INT64 && !strcmp(k, "id")) t[@"id"] = @(v->u.int64);
            else if (v->format == MPV_FORMAT_FLAG) {
                if (!strcmp(k, "selected")) t[@"selected"] = @(v->u.flag != 0);
                else if (!strcmp(k, "external")) external = v->u.flag != 0;
                else if (!strcmp(k, "albumart")) t[@"albumart"] = @(v->u.flag != 0);
            }
        }
        if (external && externalFile) t[@"url"] = externalFile;
        if (t[@"type"]) [out addObject:t];
    }
    return out;
}

@implementation SFMPVEngine {
    mpv_handle *_mpv;
    SFMPVLayer *_layer;
    SFEngineStatus _status;
    NSError *_error;
    double _time, _dur, _cacheTime;
    BOOL _paused, _waiting, _eof, _loaded, _started, _statsLogged;
    NSDate *_openedAt;
    NSTimeInterval _loadedAfter;   // open -> file loaded (headers read), for the first-frame line
    NSTimer *_tick;
    dispatch_block_t _pendingLoad;   // loadfile deferred until the layer has a render context
    NSInteger _voHeals, _voDownTicks; // self-healing of a dead video output (audio-only playback)
    double _stallTime;                // stall watchdog: position at _stallSince
    NSDate *_stallSince;
    BOOL _stallFired;
    // observed, never read synchronously on the main thread: a property read takes mpv's core lock,
    // which a loading/seeking core holds - the 0.5-s tick then blocked the main thread up to 600 ms
    // (hitch monitor 2026-11-07, -[SFMPVEngine prop:] in __psynch_cvwait)
    BOOL _hasVideo, _voConfigured;   // the file has a real video track (not album art); vo is up
    int64_t _width, _height;         // displayed video size
    BOOL _coreReady;                 // the core was created (or failed): _mpv is final
    NSMutableArray *_whenReady;      // calls waiting for it (an open)
    BOOL _shutDown;
}

// Playback that should run but makes no progress for this long counts as failed, so the player's
// fallback chain takes over. 2026-11-05: the YouTube SABR service died during playback; mpv's HTTP
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

// The core: created, configured and initialized off the main thread - mpv_create/mpv_initialize
// took ~220 ms of main-thread time per player open (hitch monitor 2026-11-08, once the first
// frame's render had left the main thread). NULL if mpv cannot start.
static mpv_handle *SFCreateCore(void) {
    mpv_handle *mpv = mpv_create();
    if (!mpv) return NULL;
    const char *opts[][2] = {
        {"vo", "libmpv"}, {"hwdec", "no"},   // videotoolbox hwaccel fails on 10.9 (measured 2026-11-04)
        {"ao", "coreaudio"}, {"audio-client-name", "Sofa"},
        {"ytdl", "no"}, {"input-default-bindings", "no"}, {"input-vo-keyboard", "no"}, {"osc", "no"},
        {"terminal", "no"}, {"msg-level", "all=warn"}, {"keep-open", "yes"}, {"idle", "yes"},
        {"cache", "yes"}, {"demuxer-max-bytes", "200MiB"}, {"demuxer-readahead-secs", "30"},
        {"network-timeout", "20"}, {"hr-seek", "yes"}, {"sub-auto", "no"}, {"sid", "no"},
        // the start time from the first cluster: a WebM start at the resume position made mpv read
        // media at 0 first - on a streamed track a whole fetch (5-6 s each for video and audio,
        // 2026-11-07); YouTube's and the media libraries' files start at 0
        {"demuxer-mkv-probe-start-time", "no"},
        // nor the first video packets (still-image check): with the engine serving the first
        // Cluster ID, opening reads nothing past the headers - option of our mpv overlay port
        // (patch-mkv-probe-image.diff); the start point's media is all a resumed start fetches
        {"demuxer-mkv-probe-image", "no"},
    };
    for (size_t i = 0; i < sizeof opts / sizeof opts[0]; i++) mpv_set_option_string(mpv, opts[i][0], opts[i][1]);
    // Deliberately without TLS certificate verification (ffmpeg default tls_verify=0, user decision
    // 2026-11-04): pure media data, an outdated CA bundle on the frozen 10.9 must never break
    // playback. Code (updater) is still loaded with verification.
    int r = mpv_initialize(mpv);
    if (r < 0) { SFLog(@"mpv: init: %s", mpv_error_string(r)); mpv_terminate_destroy(mpv); return NULL; }
    mpv_observe_property(mpv, kPropTime, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(mpv, kPropDuration, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(mpv, kPropPause, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(mpv, kPropCacheWait, "paused-for-cache", MPV_FORMAT_FLAG);
    mpv_observe_property(mpv, kPropEOF, "eof-reached", MPV_FORMAT_FLAG);
    mpv_observe_property(mpv, kPropCacheTime, "demuxer-cache-time", MPV_FORMAT_DOUBLE);
    mpv_observe_property(mpv, kPropTracks, "track-list", MPV_FORMAT_NODE);
    mpv_observe_property(mpv, kPropVOConfigured, "vo-configured", MPV_FORMAT_FLAG);
    mpv_observe_property(mpv, kPropWidth, "dwidth", MPV_FORMAT_INT64);
    mpv_observe_property(mpv, kPropHeight, "dheight", MPV_FORMAT_INT64);
    // mpvDebugDemux (diagnosis switch, SFSettings.h): what the demuxers read and why, into the log
    BOOL demuxDebug = SFDiagnosisEnabled(@"mpvDebugDemux");
    if (demuxDebug) mpv_set_option_string(mpv, "msg-level", "all=warn,demux=debug,mkv=debug,cplayer=v,stream=v");
    mpv_request_log_messages(mpv, demuxDebug ? "debug" : "warn");   // mpv warnings/errors into the Sofa log
    return mpv;
}

static dispatch_queue_t SetupQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("sofa.mpv-setup", DISPATCH_QUEUE_SERIAL); });
    return q;
}

- (instancetype)init {
    if ((self = [super init])) {
        _layer = [SFMPVLayer layer];
        _whenReady = [NSMutableArray new];
        dispatch_async(SetupQueue(), ^{
            mpv_handle *mpv = SFCreateCore();
            dispatch_async(dispatch_get_main_queue(), ^{ [self adoptCore:mpv]; });
        });
    }
    return self;
}

// Main thread: the core is there (or not). Shut down meanwhile: it goes the way of every core.
- (void)adoptCore:(mpv_handle *)mpv {
    _coreReady = YES;
    if (_shutDown) { if (mpv) [_layer retireWithMPV:mpv]; _whenReady = nil; return; }
    _mpv = mpv;
    if (mpv) {
        mpv_set_wakeup_callback(mpv, onWakeup, (__bridge void *)self);
        _layer.mpv = mpv;
        [self drainEvents];   // anything that came before the callback was set
    }
    NSArray *waiting = _whenReady; _whenReady = nil;
    for (dispatch_block_t b in waiting) b();
}

- (void)whenReady:(dispatch_block_t)b {
    if (_coreReady) b(); else [_whenReady addObject:[b copy]];
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
    _status = SFEngineLoading; _error = nil; _loaded = NO; _started = NO; _statsLogged = NO; _eof = NO; _time = 0; _dur = 0; _cacheTime = 0;
    _openedAt = [NSDate date]; _stallSince = nil; _stallFired = NO;   // the core's creation counts to the open
    _voHeals = 0; _voDownTicks = 0;
    [_tick invalidate];
    _tick = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(onTick) userInfo:nil repeats:YES];
    __weak SFMPVEngine *ws = self;
    [self whenReady:^{ [ws loadURL:url audioURL:audioURL start:start exact:exact paused:paused]; }];
}

- (void)loadURL:(NSURL *)url audioURL:(NSURL *)audioURL start:(NSTimeInterval)start exact:(BOOL)exact paused:(BOOL)paused {
    if (!_mpv) { _status = SFEngineFailed; _error = SFError(@"mpv nicht verfügbar"); [self.delegate engineStatusChanged]; return; }
    // Options for the next file (start, pause, separate audio track). URLs contain ':' and ',' ->
    // no path-list syntax, but change-list ... append (one element).
    mpv_set_property_string(_mpv, "start", start > 0 ? [NSString stringWithFormat:@"%.3f", start].UTF8String : "none");
    mpv_set_property_string(_mpv, "hr-seek", exact ? "yes" : "default");
    mpv_set_property_string(_mpv, "pause", paused ? "yes" : "no");
    mpv_set_property_string(_mpv, "mute", _muted ? "yes" : "no");
    if (!url.isFileURL) mpv_set_property_string(_mpv, "user-agent", SFNativeUserAgent().UTF8String);   // the app's identity, not "libmpv"
    // A DASH track (separate audio) is one self-contained media file - nothing to follow. And mpv's
    // reference-following probes (playlist/directory) peek 8 KiB: past an Opus track's 4.7 KB
    // header, into media at 0 that a resumed start never needs - one whole fetch (~7 s) before the
    // audio opened (demux log 2026-11-08). Everything else keeps them (HLS, ordered chapters).
    mpv_set_property_string(_mpv, "access-references", audioURL ? "no" : "yes");
    [self command:@[@"change-list", @"audio-files", @"clr", @""]];
    if (audioURL) [self command:@[@"change-list", @"audio-files", @"append", audioURL.absoluteString]];
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
}

- (NSString *)prop:(NSString *)name {
    if (!_mpv) return nil;
    char *v = mpv_get_property_string(_mpv, name.UTF8String);
    NSString *s = v ? @(v) : nil;
    if (v) mpv_free(v);
    return s;
}

// Read now, not from the observed copy: callers act right after their own sub-add/audio-add (menus,
// duplicate check), which the observation reports only later. One read of the whole list.
- (NSArray *)tracksOfType:(NSString *)type {
    if (!_mpv) return @[];
    mpv_node list;
    if (mpv_get_property(_mpv, "track-list", MPV_FORMAT_NODE, &list) < 0) return @[];
    NSArray *all = SFTracksFromNode(&list);
    mpv_free_node_contents(&list);
    return [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"type == %@", type]];
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
    // loading counts too, paused or not: an open that never shows its first frame is a stall (a
    // paused open decodes that frame as well - until then it waits for data like any other)
    BOOL shouldRun = !_eof && (!_paused || !_started);
    if (!shouldRun || _time != _stallTime || !_stallSince) { _stallTime = _time; _stallSince = [NSDate date]; return; }
    if (-[_stallSince timeIntervalSinceNow] < SFStallLimit()) return;
    _stallFired = YES;
    SFLog(@"mpv: no progress for %.0f s at %.1f s (%@) - treating as failed", SFStallLimit(), _time, _loaded ? @"playing" : @"loading");
    _status = SFEngineFailed; _loaded = NO;
    _error = SFError(@"Die Wiedergabe hängt.");
    [self.delegate engineStatusChanged];
}

// Self-healing: playback runs, the file has a video track, but no video output is configured (vo
// init failed, e.g. a render-context race: audio only) -> re-select the video track so mpv
// re-creates the vo. Up to 3 tries.
- (void)healVideoOutput {
    if (_voHeals >= 3 || !_layer.hasRenderContext) return;
    // only once playback runs: before it, mpv has simply not decoded a first frame yet - a slow
    // stream start looked "missing" and re-selecting the track restarted its decoding (2026-11-07)
    if (!_started) { _voDownTicks = 0; return; }
    if (!_hasVideo || _voConfigured) { _voDownTicks = 0; return; }
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
                if (!_loaded) _loadedAfter = -[_openedAt timeIntervalSinceNow];   // the start's two halves: open, then seek + decode
                _loaded = YES; _status = SFEngineReady;
                [self.delegate engineStatusChanged];
                break;
            case MPV_EVENT_PLAYBACK_RESTART:
                // after loading (and after every seek): decoding caught up, the frame is shown. "file
                // loaded" comes seconds earlier for a network stream - a spinner hidden then left a
                // black screen (user 2026-11-07)
                if (!_started && _loaded) {
                    _started = YES;
                    SFLog(@"mpv: first frame %.1f s after open (loaded after %.1f s)", -[_openedAt timeIntervalSinceNow], _loadedAfter);
                    [self.delegate engineBufferingChanged];
                }
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
                    case kPropVOConfigured: _voConfigured = has && *(int *)p->data; break;
                    case kPropWidth: _width = has ? *(int64_t *)p->data : 0; break;
                    case kPropHeight: _height = has ? *(int64_t *)p->data : 0; break;
                    case kPropTracks: {
                        _hasVideo = NO;
                        for (NSDictionary *t in has ? SFTracksFromNode(p->data) : @[])
                            if ([t[@"type"] isEqualToString:@"video"] && ![t[@"albumart"] boolValue]) _hasVideo = YES;
                        break;
                    }
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
- (BOOL)playing { return _loaded && !_paused && !_eof; }   // "running" while buffering too
- (BOOL)likelyToKeepUp { return !_waiting; }
- (BOOL)started { return _started; }
- (NSTimeInterval)currentTime { return _time > 0 ? _time : 0; }
- (NSTimeInterval)duration { return _dur > 0 ? _dur : 0; }
- (NSTimeInterval)bufferedUntil { return _cacheTime; }
- (CGSize)videoSize { return _width > 0 && _height > 0 ? CGSizeMake(_width, _height) : CGSizeZero; }
- (void)setMuted:(BOOL)m { _muted = m; if (_mpv) mpv_set_property_string(_mpv, "mute", m ? "yes" : "no"); }

- (void)play { if (_mpv) mpv_set_property_string(_mpv, "pause", "no"); }
- (void)pause { if (_mpv) mpv_set_property_string(_mpv, "pause", "yes"); }
- (void)seekTo:(NSTimeInterval)t exact:(BOOL)exact {
    _eof = NO;
    [self command:@[@"seek", [NSString stringWithFormat:@"%.3f", MAX(0, t)], exact ? @"absolute+exact" : @"absolute"]];
}

// What a playback cost the display: frames mpv dropped (decoder too slow vs. output too late) over
// the playing time - measured on the real screen (an offscreen dev window drops at output by
// design), so stutter is judged by numbers. Once per open, when it ends.
- (void)logPlaybackStats {
    if (!_mpv || !_started || _statsLogged) return;
    _statsLogged = YES;
    SFLog(@"mpv: played to %.0f s at %@ fps - dropped %@ (decoder %@), delayed %@", _time,
          [self prop:@"estimated-vf-fps"] ?: @"?", [self prop:@"frame-drop-count"] ?: @"?",
          [self prop:@"decoder-frame-drop-count"] ?: @"?", [self prop:@"vo-delayed-frame-count"] ?: @"?");
}

- (void)close {
    [_tick invalidate]; _tick = nil;
    if (!_mpv) return;
    [self logPlaybackStats];
    [self command:@[@"stop"]];
    _loaded = NO; _started = NO; _status = SFEngineLoading;
}

- (void)shutdown {
    [_tick invalidate]; _tick = nil;
    _shutDown = YES;   // a core still being created is retired when it arrives (adoptCore:)
    if (!_mpv) return;
    [self logPlaybackStats];
    mpv_set_wakeup_callback(_mpv, NULL, NULL);
    mpv_handle *mpv = _mpv;
    _mpv = NULL;
    [_layer retireWithMPV:mpv];   // render context, then core - off the main thread
}

- (void)dealloc { [self shutdown]; }
@end


void SFMPVDevFrameShot(NSString *path) {
    SFMPVDevFrameShotPath = path;
    dispatch_async(dispatch_get_main_queue(), ^{ [[SFMPVLayer devCurrent] devFrameShot]; });
}
