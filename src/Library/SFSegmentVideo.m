// SFSegmentVideo - a video track re-encoded for the browser: decoded (VP9 natively, AV1 with dav1d),
// scaled only when it must be (above the size cap, or not 8-bit 4:2:0), frames of a faster source left
// out evenly down to the rate cap, encoded - H.264 by VideoToolbox (the GPU's encoder; measured on this
// Mac 2026-11-26, docs/pwa.md §8) or x264 (what the browser can't play as it is), AV1 by SVT-AV1 (an
// online source in fewer bytes) - with a keyframe opening every segment.
#import "SFSegmentTrack.h"
#import "SFCore.h"
#include <libswscale/swscale.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>

static const AVRational kTB = {1, 90000};
static const int64_t kSlackUs = 2000;

// The GPU's encoder takes one session at a time (measured 2026-11-26: a second one is refused with
// -8973 while the first runs). A seek's new job therefore waits for the cancelled job's session to
// close - held from opening an encoder until FreeEncoder, released on every path.
static const NSTimeInterval kHardwareWait = 15;
static NSCondition *gHardware;
static BOOL gHardwareTaken;

static BOOL IsHardware(NSString *name) { return [name isEqualToString:@"h264_videotoolbox"]; }

static BOOL TakeHardware(BOOL (^cancelled)(void)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gHardware = [NSCondition new]; });
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:kHardwareWait];
    [gHardware lock];
    while (gHardwareTaken && !(cancelled && cancelled()) && [until timeIntervalSinceNow] > 0)
        [gHardware waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    BOOL got = !gHardwareTaken && !(cancelled && cancelled());
    if (got) gHardwareTaken = YES;
    [gHardware unlock];
    return got;
}

static void ReleaseHardware(void) {
    [gHardware lock];
    gHardwareTaken = NO;
    [gHardware broadcast];
    [gHardware unlock];
}

static void FreeEncoder(AVCodecContext **e) {
    if (!*e) return;
    BOOL hardware = IsHardware(@((*e)->codec->name));
    avcodec_free_context(e);
    if (hardware) ReleaseHardware();
}

// The encoder's settings (shared by the availability test and the jobs)
static AVCodecContext *Configured(const AVCodec *c, NSString *name, int w, int h, double fps, int gop, long long bitrate) {
    AVCodecContext *e = avcodec_alloc_context3(c);
    e->width = w; e->height = h;
    e->pix_fmt = AV_PIX_FMT_YUV420P;
    e->sample_aspect_ratio = (AVRational){1, 1};
    e->color_range = AVCOL_RANGE_MPEG;
    e->time_base = kTB;
    e->framerate = av_d2q(fps, 100000);
    // a keyframe every segment: VideoToolbox on 10.9 and FFmpeg's SVT-AV1 wrapper (unless gop is 1)
    // ignore forced keyframes (measured) but keep their interval exactly from a job's first frame, so
    // the frames are constant-rate and every segment has `gop` of them (x264 is forced as well)
    e->gop_size = gop;
    e->max_b_frames = 0;                 // decode order = presentation order: every segment starts clean
    e->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;   // SPS/PPS in the init segment (avcC)
    if ([name isEqualToString:@"h264_videotoolbox"]) {
        e->bit_rate = bitrate;
        av_opt_set_int(e->priv_data, "allow_sw", 0, 0);   // the hardware or nothing (Apple's software encoder is no better than x264)
        av_opt_set(e->priv_data, "profile", "high", 0);
    } else if ([name isEqualToString:@"libsvtav1"]) {
        // SVT-AV1: constant quality under a ceiling (capped CRF), closed GOPs (a segment decodes on its
        // own). Preset 10 without lookahead: 720p50 at 2.65x real time here, VMAF 92.6 at ~1.1 Mbit/s
        // from a 3.7 Mbit/s H.264 broadcast (preset 12: 3.0x, 92.0; measured 2026-11-27, docs/pwa.md §8)
        av_opt_set_int(e->priv_data, "preset", 10, 0);
        av_opt_set_int(e->priv_data, "crf", 35, 0);
        av_opt_set(e->priv_data, "svtav1-params", "lookahead=0", 0);
        e->flags |= AV_CODEC_FLAG_CLOSED_GOP;
        e->rc_max_rate = bitrate;
        e->rc_buffer_size = (int)MIN(bitrate * 2, INT_MAX);
    } else {
        // x264: constant quality with a ceiling; no lookahead, no B-frames (tune zerolatency: measured
        // 4.7x real time at 1080p30 here, the default lookahead only 1.6x)
        av_opt_set(e->priv_data, "preset", "veryfast", 0);
        av_opt_set(e->priv_data, "tune", "zerolatency", 0);
        av_opt_set(e->priv_data, "crf", "21", 0);
        av_opt_set(e->priv_data, "forced-idr", "1", 0);
        av_opt_set(e->priv_data, "profile", "high", 0);
        e->rc_max_rate = bitrate * 3 / 2;
        e->rc_buffer_size = (int)MIN(bitrate * 2, INT_MAX);
    }
    return e;
}

// An open encoder, or NULL and why. `cancelled`: when to stop waiting for the GPU's encoder.
static AVCodecContext *NewEncoder(NSString *name, int w, int h, double fps, int gop, long long bitrate,
                                  BOOL (^cancelled)(void), NSString **why) {
    const AVCodec *c = avcodec_find_encoder_by_name(name.UTF8String);
    if (!c) { if (why) *why = [NSString stringWithFormat:@"%@ not built in", name]; return NULL; }
    if (IsHardware(name) && !TakeHardware(cancelled)) {
        // (worded without "encode": a busy GPU is no reason to give up on it for good)
        if (why) *why = cancelled && cancelled() ? @"cancelled" : @"the GPU's H.264 unit stayed in use";
        return NULL;
    }
    AVCodecContext *e = Configured(c, name, w, h, fps, gop, bitrate);
    int r = avcodec_open2(e, c, NULL);
    // a session closed just before may hold the GPU's encoder a moment longer: a few more tries
    for (int i = 0; r < 0 && IsHardware(name) && i < 4 && !(cancelled && cancelled()); i++) {
        avcodec_free_context(&e);
        [NSThread sleepForTimeInterval:0.25];
        e = Configured(c, name, w, h, fps, gop, bitrate);
        r = avcodec_open2(e, c, NULL);
    }
    if (r < 0) {
        if (why) *why = [NSString stringWithFormat:@"%@: %s", name, av_err2str(r)];
        avcodec_free_context(&e);
        if (IsHardware(name)) ReleaseHardware();
    }
    return e;
}

// Whether `name` really encodes here: one small frame through it (VideoToolbox without the GPU's
// encoder, or a session the system refuses, fails here instead of in a playback)
static BOOL EncoderWorks(NSString *name) {
    NSString *why = nil;
    AVCodecContext *e = NewEncoder(name, 640, 360, 30, 120, 1000000, nil, &why);
    if (!e) { SFLog(@"transcode: %@ unavailable (%@)", name, why); return NO; }
    AVFrame *f = av_frame_alloc();
    f->format = e->pix_fmt; f->width = e->width; f->height = e->height;
    BOOL ok = av_frame_get_buffer(f, 0) >= 0;
    if (ok) {
        for (int p = 0; p < 3; p++) memset(f->data[p], p ? 128 : 16, (size_t)f->linesize[p] * (p ? e->height / 2 : e->height));
        f->pts = 0; f->pict_type = AV_PICTURE_TYPE_I;
        ok = avcodec_send_frame(e, f) >= 0 && avcodec_send_frame(e, NULL) >= 0;
    }
    AVPacket *p = av_packet_alloc();
    BOOL got = NO;
    while (ok && avcodec_receive_packet(e, p) >= 0) { got = got || p->size > 0; av_packet_unref(p); }
    av_packet_free(&p); av_frame_free(&f); FreeEncoder(&e);
    if (!got) SFLog(@"transcode: %@ opens but encodes nothing", name);
    return got;
}

static NSMutableSet *gBroken;

@implementation SFSegmentVideo {
    NSString *_url, *_encoderName;
    int _w, _h;
    double _fps;
    long long _bitrate;
    AVRational _rate;           // output frames per second
    int64_t _startUs, _outFrameUs, _slot, _curT, _nextT;   // _slot: the next output frame's number since 0
    int _perSegment;            // output frames per segment
    NSTimeInterval _timeout;
    SFAVInput *_in;
    AVCodecContext *_dec, *_enc;
    AVCodecParameters *_par;
    struct SwsContext *_sws;
    AVFrame *_frame, *_cur, *_next, *_emit, *_scaled;   // decoded: the frame for the slot, the one after it
    AVPacket *_pkt;
    SFAVPacket *_pending;     // encoded, belongs to the next segment
    BOOL _seeking;            // the packets up to the start's keyframe are still to be passed over
    NSMutableArray *_queued;  // read after a seek, to decode first (SFAVPacket)
    BOOL _inputDone, _encoderFlushed, _cancelled, _clearColors, _haveCur, _haveNext, _decoderDone;
    NSUInteger _unkeyed;      // boundaries the encoder did not start with a keyframe (logged)
}

// Every encoder Sofa uses, by codec, best first
static NSDictionary *EncoderOrder(void) {
    return @{@"avc1": @[@"h264_videotoolbox", @"libx264"], @"av01": @[@"libsvtav1"]};
}

+ (NSArray *)encodersFor:(NSString *)codec {
    static NSMutableDictionary *found;   // codec -> those that work (tried once each)
    NSArray *ok;
    @synchronized (self) {
        if (!found) found = [NSMutableDictionary new];
        if (!(ok = found[codec ?: @""])) {
            // dev instances may narrow the choice (tests of the fallbacks): SOFA_TRANSCODE_ENCODERS=libx264 | none
            NSString *only = SFDevEnv(@"SOFA_TRANSCODE_ENCODERS");
            NSArray *allowed = only ? [only componentsSeparatedByString:@","] : nil;
            NSMutableArray *works = [NSMutableArray new];
            for (NSString *n in EncoderOrder()[codec ?: @""] ?: @[])
                if ((!allowed || [allowed containsObject:n]) && EncoderWorks(n)) [works addObject:n];
            SFLog(@"transcode: %@ encoders here: %@", [codec isEqualToString:@"av01"] ? @"AV1" : @"H.264",
                  works.count ? [works componentsJoinedByString:@", "] : @"none");
            found[codec ?: @""] = ok = works;
        }
        return [ok filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *n, NSDictionary *b) { return ![gBroken containsObject:n]; }]];
    }
}

+ (NSArray *)encodersFor:(NSString *)codec width:(int)width height:(int)height {
    return [[self encodersFor:codec] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *n, NSDictionary *b) {
        return ![n isEqualToString:@"h264_videotoolbox"] || MAX(width, height) >= 640;
    }]];
}

+ (void)encoderFailed:(NSString *)encoder {
    @synchronized (self) {
        if (!gBroken) gBroken = [NSMutableSet new];
        [gBroken addObject:encoder];
    }
    SFLog(@"transcode: %@ failed in a job - not used again until Sofa restarts", encoder);
}

- (instancetype)initWithURL:(NSString *)url encoder:(NSString *)encoder width:(int)width height:(int)height fps:(double)fps
                    bitrate:(long long)bitrate segment:(int64_t)segmentUs timeout:(NSTimeInterval)seconds {
    if ((self = [super init])) {
        _url = [url copy]; _encoderName = [encoder copy];
        _w = width; _h = height; _fps = fps; _bitrate = bitrate; _timeout = seconds;
        _rate = av_d2q(fps, 100000);
        _perSegment = MAX(1, (int)llround(segmentUs / 1e6 * fps));
        _outFrameUs = av_rescale(AV_TIME_BASE, _rate.den, _rate.num);
        _clearColors = [encoder isEqualToString:@"h264_videotoolbox"];
        _pkt = av_packet_alloc(); _frame = av_frame_alloc(); _cur = av_frame_alloc(); _next = av_frame_alloc(); _emit = av_frame_alloc();
    }
    return self;
}

- (void)dealloc {
    [_inputs keep:_in url:_url];   // whole: the playback's next job goes on with it
    if (_unkeyed) SFLog(@"transcode: %lu segment(s) did not start with a keyframe", (unsigned long)_unkeyed);
    avcodec_free_context(&_dec); FreeEncoder(&_enc);
    avcodec_parameters_free(&_par);
    sws_freeContext(_sws);
    av_frame_free(&_frame); av_frame_free(&_cur); av_frame_free(&_next); av_frame_free(&_emit); av_frame_free(&_scaled); av_packet_free(&_pkt);
}

@synthesize originUs = _originUs, inputs = _inputs;
- (const AVCodecParameters *)parameters { return _par; }
- (AVRational)timeBase { return kTB; }
- (void)cancel { _cancelled = YES; [_in cancel]; }

- (BOOL)startAt:(int64_t)us error:(NSString **)why {
    if (!_in && ![self openWithError:why]) return NO;
    if (![_in seek:us]) { if (why) *why = @"seek failed"; return NO; }
    avcodec_flush_buffers(_dec);
    _startUs = us; _pending = nil; _inputDone = _decoderDone = _haveCur = _haveNext = NO;
    _seeking = YES; _queued = nil;
    _slot = av_rescale(us, _rate.num, (int64_t)AV_TIME_BASE * _rate.den);   // a segment boundary: a multiple of _perSegment
    return YES;
}

- (BOOL)openWithError:(NSString **)why {
    if (!(_in = _inputs ? [_inputs open:_url type:AVMEDIA_TYPE_VIDEO timeout:_timeout error:why]
                        : [SFAVInput open:_url type:AVMEDIA_TYPE_VIDEO timeout:_timeout error:why])) return NO;
    _in.originUs = _originUs;
    if (_cancelled) [_in cancel];
    AVCodecParameters *sp = _in.stream->codecpar;
    // AV1: dav1d (FFmpeg's own av1 decoder needs a hardware decoder this Mac lacks)
    const AVCodec *dc = sp->codec_id == AV_CODEC_ID_AV1 ? avcodec_find_decoder_by_name("libdav1d") : NULL;
    if (!dc) dc = avcodec_find_decoder(sp->codec_id);
    if (!dc) { if (why) *why = [NSString stringWithFormat:@"no decoder for %s", avcodec_get_name(sp->codec_id)]; return NO; }
    _dec = avcodec_alloc_context3(dc);
    avcodec_parameters_to_context(_dec, sp);
    _dec->pkt_timebase = _in.stream->time_base;
    _dec->thread_count = 0;   // as many as the decoder likes (the cores)
    int r = avcodec_open2(_dec, dc, NULL);
    if (r < 0) { if (why) *why = [NSString stringWithFormat:@"decoder: %s", av_err2str(r)]; return NO; }
    if (!(_enc = NewEncoder(_encoderName, _w, _h, _fps, _perSegment, _bitrate, ^BOOL { return self->_cancelled; }, why))) return NO;
    if (!_clearColors) {   // x264 writes the source's colour description into the stream (VUI)
        _enc->color_primaries = sp->color_primaries; _enc->color_trc = sp->color_trc;
        _enc->colorspace = sp->color_space;
    }
    _enc->color_range = AVCOL_RANGE_MPEG;   // what it gets (converted(): a full-range source is brought into it)
    _par = avcodec_parameters_alloc();
    avcodec_parameters_from_context(_par, _enc);
    return YES;
}

// The next decoded frame at or after the start into `into`, its time in *t; NO at the end (*why on an error)
- (BOOL)decode:(AVFrame *)into time:(int64_t *)t error:(NSString **)why {
    for (;;) {
        int r = _decoderDone ? AVERROR_EOF : avcodec_receive_frame(_dec, into);
        if (r == 0) {
            *t = [_in microseconds:into->best_effort_timestamp];
            if (*t == AV_NOPTS_VALUE || *t < _startUs - _outFrameUs) { av_frame_unref(into); continue; }
            return YES;
        }
        if (r == AVERROR_EOF) { _decoderDone = YES; return NO; }
        if (r != AVERROR(EAGAIN)) { if (why) *why = [NSString stringWithFormat:@"decode: %s", av_err2str(r)]; return NO; }
        if (_inputDone) { avcodec_send_packet(_dec, NULL); continue; }
        r = [self nextPacket:_pkt];
        if (r == AVERROR_EOF) { _inputDone = YES; avcodec_send_packet(_dec, NULL); continue; }
        if (r < 0) { if (why) *why = [NSString stringWithFormat:@"read: %s", av_err2str(r)]; return NO; }
        r = avcodec_send_packet(_dec, _pkt);
        av_packet_unref(_pkt);
        if (r < 0 && r != AVERROR_INVALIDDATA) { if (why) *why = [NSString stringWithFormat:@"decode: %s", av_err2str(r)]; return NO; }
    }
}

// The packets to decode after a seek: from the last keyframe at or before the start - read, not decoded,
// up to it. A seek lands on the keyframe before the target where the container has an index; HLS lands
// on a segment's start (FFmpeg's demuxer: the one before, at a boundary) - ORF's 9.6 s segments with a
// keyframe every 4.8 s made a seek decode (and drop) 9 s of 720p50 first: 2.2 s; from the keyframe
// 0.3 s (measured 2026-11-27).
- (int)nextPacket:(AVPacket *)pkt {
    if (_seeking) {
        _seeking = NO;
        NSMutableArray *gop = nil;   // from the last keyframe at or before the start
        for (;;) {
            int r = [_in read:pkt];
            if (r == AVERROR_EOF) break;
            if (r < 0) return r;
            int64_t pts = [_in microseconds:pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts];
            int64_t dts = [_in microseconds:pkt->dts != AV_NOPTS_VALUE ? pkt->dts : pkt->pts];
            BOOL key = (pkt->flags & AV_PKT_FLAG_KEY) != 0;
            BOOL atStart = dts != AV_NOPTS_VALUE && dts >= _startUs;   // no later keyframe can show at or before it
            if (key && pts != AV_NOPTS_VALUE && pts <= _startUs + kSlackUs) gop = [NSMutableArray new];
            if (gop || atStart) { if (!gop) gop = [NSMutableArray new]; [gop addObject:[SFAVPacket taking:pkt]]; }
            else av_packet_unref(pkt);
            if (atStart) break;
        }
        _queued = gop;
    }
    if (_queued.count) {
        av_packet_move_ref(pkt, [_queued.firstObject packet]);
        [_queued removeObjectAtIndex:0];
        return 0;
    }
    return [_in read:pkt];
}

// The frame for the next output slot (constant rate: the decoded frame nearest the slot's time - a
// 60 fps source at 30 gives every second frame, a gap repeats the last one); nil at the end
- (AVFrame *)nextFrame:(NSString **)why {
    int64_t slotUs = av_rescale(_slot, (int64_t)AV_TIME_BASE * _rate.den, _rate.num);
    if (!_haveCur) {
        if (![self decode:_cur time:&_curT error:why]) return nil;
        _haveCur = YES;
    }
    for (;;) {   // on to the decoded frame nearest the slot
        if (!_haveNext && !_decoderDone) {
            NSString *err = nil;
            _haveNext = [self decode:_next time:&_nextT error:&err];
            if (err) { if (why) *why = err; return nil; }
        }
        if (!_haveNext || !(_nextT <= slotUs || _nextT - slotUs < slotUs - _curT)) break;
        av_frame_unref(_cur);
        av_frame_move_ref(_cur, _next);
        _curT = _nextT; _haveNext = NO;
    }
    if (!_haveNext && slotUs >= _curT + _outFrameUs) return nil;   // the source's last frame had its time
    av_frame_unref(_emit);
    av_frame_ref(_emit, _cur);
    // the encoder's clock starts at 0 with the job: VideoToolbox's rate control budgets from
    // timestamp 0 (a job starting at 40 min made a first segment 4x the bit rate, measured)
    _emit->pts = av_rescale_q(slotUs - _startUs, AV_TIME_BASE_Q, kTB);
    _emit->pict_type = _slot % _perSegment == 0 ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;   // an IDR opens every segment
    _emit->duration = 0;
    _slot++;
    return _emit;
}

// A decoded frame as the encoder takes it: 8-bit 4:2:0, TV range (16-235), at the output size. A
// full-range source (JPEG range: a yuvj* format - FFmpeg's deprecated way of saying it, which swscale
// warns about on every frame - or the frame's range) is converted: swscale's frame API takes both
// ranges from the frames (the older sws_setColorspaceDetails left the values full-range here, measured
// 2026-11-27 on a Tagesschau file: luma 0-255 in a stream marked TV range).
- (AVFrame *)converted:(AVFrame *)f {
    switch (f->format) {   // the same planes; the range said as the range
        case AV_PIX_FMT_YUVJ420P: f->format = AV_PIX_FMT_YUV420P; f->color_range = AVCOL_RANGE_JPEG; break;
        case AV_PIX_FMT_YUVJ422P: f->format = AV_PIX_FMT_YUV422P; f->color_range = AVCOL_RANGE_JPEG; break;
        case AV_PIX_FMT_YUVJ444P: f->format = AV_PIX_FMT_YUV444P; f->color_range = AVCOL_RANGE_JPEG; break;
        default: break;
    }
    if (f->format == AV_PIX_FMT_YUV420P && f->color_range != AVCOL_RANGE_JPEG && f->width == _w && f->height == _h) return f;
    if (!_sws && !(_sws = sws_alloc_context())) return NULL;
    av_opt_set_int(_sws, "sws_flags", SWS_BILINEAR, 0);
    av_frame_unref(_scaled ?: (_scaled = av_frame_alloc()));
    _scaled->format = AV_PIX_FMT_YUV420P; _scaled->width = _w; _scaled->height = _h;
    _scaled->color_range = AVCOL_RANGE_MPEG;
    _scaled->colorspace = f->colorspace; _scaled->color_primaries = f->color_primaries; _scaled->color_trc = f->color_trc;
    if (sws_scale_frame(_sws, _scaled, f) < 0) return NULL;
    av_frame_copy_props(_scaled, f);
    _scaled->color_range = AVCOL_RANGE_MPEG;
    return _scaled;
}

- (BOOL)encode:(AVFrame *)f error:(NSString **)why {
    AVFrame *e = [self converted:f];
    if (!e) { if (why) *why = @"scale failed"; return NO; }
    e->pts = f->pts; e->pict_type = f->pict_type;
    // VideoToolbox on 10.9 refuses frames with colour tags (-12917, measured): sent untagged (H.264's
    // default for HD is BT.709 anyway)
    if (_clearColors) { e->color_primaries = AVCOL_PRI_UNSPECIFIED; e->color_trc = AVCOL_TRC_UNSPECIFIED; e->colorspace = AVCOL_SPC_UNSPECIFIED; }
    int r = avcodec_send_frame(_enc, e);
    av_frame_unref(f);   // the encoder holds its own reference
    if (r < 0) { if (why) *why = [NSString stringWithFormat:@"encode: %s", av_err2str(r)]; return NO; }
    return YES;
}

- (NSArray *)packetsUntil:(int64_t)endUs eof:(BOOL *)eof error:(NSString **)why {
    NSMutableArray *out = [NSMutableArray new];
    *eof = NO;
    for (;;) {
        SFAVPacket *p = _pending;
        _pending = nil;
        if (!p) {
            int r = avcodec_receive_packet(_enc, _pkt);
            if (r == AVERROR_EOF) { *eof = YES; break; }
            if (r == AVERROR(EAGAIN)) {
                if (_cancelled) { if (why) *why = @"cancelled"; return nil; }
                if (_encoderFlushed) { *eof = YES; break; }
                NSString *err = nil;
                AVFrame *f = [self nextFrame:&err];
                if (err) { if (why) *why = err; return nil; }
                if (!f) { avcodec_send_frame(_enc, NULL); _encoderFlushed = YES; continue; }
                if (![self encode:f error:why]) return nil;
                continue;
            }
            if (r < 0) { if (why) *why = [NSString stringWithFormat:@"encode: %s", av_err2str(r)]; return nil; }
            p = [SFAVPacket taking:_pkt];
            if (p.packet->dts == AV_NOPTS_VALUE) p.packet->dts = p.packet->pts;
        }
        if (av_rescale_q(p.packet->pts, kTB, AV_TIME_BASE_Q) + _startUs >= endUs - kSlackUs) {   // the next segment's IDR
            if (!(p.packet->flags & AV_PKT_FLAG_KEY)) _unkeyed++;
            _pending = p;
            break;
        }
        [out addObject:p];
    }
    // durations exactly to the next packet (the muxer checks each fragment's start against the sum),
    // then onto the source's timeline (+ the offset)
    int64_t base = av_rescale_q(_startUs + SFSegmentOffsetUs, AV_TIME_BASE_Q, kTB), nominal = av_rescale_q(_outFrameUs, AV_TIME_BASE_Q, kTB);
    for (NSUInteger i = 0; i < out.count; i++) {
        AVPacket *q = [out[i] packet], *next = i + 1 < out.count ? [out[i + 1] packet] : _pending.packet;
        q->duration = next && next->dts > q->dts ? next->dts - q->dts : nominal;
        q->pts += base; q->dts += base;
    }
    return out;
}
@end
