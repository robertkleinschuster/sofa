#import "SFAVInput.h"
#import "SFCore.h"
#include <libavutil/pixdesc.h>
#include <libavutil/time.h>

NSString *SFAVBrowserCodec(enum AVCodecID codec) {
    switch (codec) {
        case AV_CODEC_ID_H264: return @"avc1";
        case AV_CODEC_ID_HEVC: return @"hvc1";
        case AV_CODEC_ID_VP9:  return @"vp09";
        case AV_CODEC_ID_AV1:  return @"av01";
        case AV_CODEC_ID_AAC:  return @"mp4a";
        case AV_CODEC_ID_OPUS: return @"opus";
        default: return nil;
    }
}

// The interrupt callback's state: a C struct (libavformat calls it from inside its blocking reads)
typedef struct { volatile int cancelled; volatile int64_t deadline; } SFAVGuard;

static int Interrupted(void *opaque) {
    SFAVGuard *g = opaque;
    return g->cancelled || (g->deadline > 0 && av_gettime_relative() > g->deadline);
}

@implementation SFAVInput {
    SFAVGuard *_guard;
    int64_t _step;   // µs a blocking step may take
}

+ (instancetype)open:(NSString *)url type:(enum AVMediaType)type timeout:(NSTimeInterval)seconds error:(NSString **)why {
    SFAVInput *i = [SFAVInput new];
    return [i openURL:url type:type timeout:seconds error:why] ? i : nil;
}

- (instancetype)init {
    if ((self = [super init])) _guard = calloc(1, sizeof *_guard);
    return self;
}

- (void)dealloc {
    if (_format) avformat_close_input(&_format);
    free(_guard);
}

- (void)arm { _guard->deadline = av_gettime_relative() + _step; }

- (BOOL)openURL:(NSString *)url type:(enum AVMediaType)type timeout:(NSTimeInterval)seconds error:(NSString **)why {
    _step = (int64_t)(seconds * 1e6);
    AVFormatContext *fc = avformat_alloc_context();
    if (!fc) { if (why) *why = @"no memory"; return NO; }
    fc->interrupt_callback = (AVIOInterruptCB){ Interrupted, _guard };
    AVDictionary *o = NULL;
    if ([url hasPrefix:@"http"]) {
        av_dict_set(&o, "seekable", "1", 0);              // the local routes all answer Range
        av_dict_set(&o, "reconnect", "0", 0);             // a failed read is the job's to handle (the deadline)
    }
    [self arm];
    int r = avformat_open_input(&fc, url.UTF8String, NULL, &o);
    av_dict_free(&o);
    if (r < 0) { if (why) *why = [NSString stringWithFormat:@"open: %s", av_err2str(r)]; return NO; }
    _format = fc;
    [self arm];
    if ((r = avformat_find_stream_info(fc, NULL)) < 0) { if (why) *why = [NSString stringWithFormat:@"stream info: %s", av_err2str(r)]; return NO; }
    int s = av_find_best_stream(fc, type, -1, -1, NULL, 0);
    if (s < 0) { if (why) *why = type == AVMEDIA_TYPE_VIDEO ? @"no video track" : @"no audio track"; return NO; }
    for (unsigned k = 0; k < fc->nb_streams; k++) fc->streams[k]->discard = (int)k == s ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    _stream = fc->streams[s];
    _guard->deadline = 0;
    return YES;
}

- (int)read:(AVPacket *)packet {
    for (;;) {
        [self arm];
        int r = av_read_frame(_format, packet);
        _guard->deadline = 0;
        if (r < 0) return _guard->cancelled ? AVERROR_EXIT : r;
        if (packet->stream_index == _stream->index) return 0;
        av_packet_unref(packet);
    }
}

// HLS: FFmpeg's demuxer drops a non-video stream's packets before the target as measured on that
// playlist's own baseline (hls.c, ts_offset) - a separate audio rendition started 257 ms past it
// (test-web 16). Such a stream is sought this much earlier; the tracks cut to the exact start themselves.
static const int64_t kHLSAudioLeadUs = 10000000;

- (BOOL)seek:(int64_t)us {
    if (_stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO && strcmp(_format->iformat->name, "hls") == 0) us -= kHLSAudioLeadUs;
    int64_t ts = av_rescale_q(us + _originUs, AV_TIME_BASE_Q, _stream->time_base);
    if (_stream->start_time != AV_NOPTS_VALUE && ts < _stream->start_time) ts = _stream->start_time;
    [self arm];
    int r = avformat_seek_file(_format, _stream->index, INT64_MIN, ts, ts, 0);
    if (r < 0) r = av_seek_frame(_format, _stream->index, ts, AVSEEK_FLAG_BACKWARD);
    _guard->deadline = 0;
    return r >= 0;
}

- (int64_t)microseconds:(int64_t)ts {
    return ts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : av_rescale_q(ts, _stream->time_base, AV_TIME_BASE_Q) - _originUs;
}

- (int64_t)durationMicroseconds:(int64_t)d { return av_rescale_q(d, _stream->time_base, AV_TIME_BASE_Q); }

- (void)cancel { _guard->cancelled = 1; }
- (BOOL)cancelled { return _guard->cancelled != 0; }
@end

@implementation SFAVProbe

+ (instancetype)probeVideo:(NSString *)videoURL audio:(NSString *)audioURL timeout:(NSTimeInterval)seconds error:(NSString **)why {
    SFAVInput *v = [SFAVInput open:videoURL type:AVMEDIA_TYPE_VIDEO timeout:seconds error:why];
    if (!v) return nil;
    NSString *ignored = nil;   // a video without sound is still a video
    SFAVInput *a = [SFAVInput open:audioURL ?: videoURL type:AVMEDIA_TYPE_AUDIO timeout:seconds error:&ignored];
    SFAVProbe *p = [SFAVProbe new];
    [p describeVideo:v audio:a separate:audioURL != nil];
    return p;
}

- (void)describeVideo:(SFAVInput *)v audio:(SFAVInput *)a separate:(BOOL)separate {
    AVCodecParameters *vp = v.stream->codecpar;
    _videoCodec = vp->codec_id;
    _videoTag = SFAVBrowserCodec(vp->codec_id);
    _width = vp->width; _height = vp->height;
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(vp->format);
    _bitDepth = d ? d->comp[0].depth : 8;
    AVRational fr = v.stream->avg_frame_rate.num > 0 ? v.stream->avg_frame_rate : v.stream->r_frame_rate;
    _fps = fr.num > 0 && fr.den > 0 ? av_q2d(fr) : 0;
    double dur = v.stream->duration != AV_NOPTS_VALUE ? v.stream->duration * av_q2d(v.stream->time_base) : 0;
    if (!(dur > 0) && v.format->duration != AV_NOPTS_VALUE) dur = v.format->duration / (double)AV_TIME_BASE;
    _duration = dur;
    if (a) {
        AVCodecParameters *ap = a.stream->codecpar;
        _audioCodec = ap->codec_id;
        _audioTag = SFAVBrowserCodec(ap->codec_id);
        // AAC needs its AudioSpecificConfig (an ADTS stream from a TS has none); Opus always has its header
        _audioCopyable = (ap->codec_id == AV_CODEC_ID_AAC && ap->extradata_size > 0) || ap->codec_id == AV_CODEC_ID_OPUS;
    }
    _mp4File = !separate && strstr(v.format->iformat->name, "mp4") != NULL;
    const char *fmt = v.format->iformat->name;
    _hls = strcmp(fmt, "hls") == 0;
    if ((_hls || strcmp(fmt, "mpegts") == 0) && v.stream->start_time != AV_NOPTS_VALUE)
        _originUs = av_rescale_q(v.stream->start_time, v.stream->time_base, AV_TIME_BASE_Q);
    NSMutableArray *keys = [NSMutableArray new];
    // a Matroska/WebM file's cues are read at its first seek (a DASH WebM has them up front, a
    // muxer's at the end): one seek to the start makes the demuxer read them
    if (avformat_index_get_entries_count(v.stream) < 2) [v seek:0];
    int n = avformat_index_get_entries_count(v.stream);
    double last = -1;
    for (int k = 0; k < n; k++) {
        const AVIndexEntry *e = avformat_index_get_entry(v.stream, k);
        if (!(e->flags & AVINDEX_KEYFRAME)) continue;
        double t = MAX(0, [v microseconds:e->timestamp] / 1e6);
        if (t > last) { [keys addObject:@(t)]; last = t; }
    }
    _keyframes = keys.count > 1 ? keys : nil;
    _summary = [NSString stringWithFormat:@"%s %dx%d%@ %.4g fps%@", avcodec_get_name(_videoCodec), _width, _height,
                _bitDepth > 8 ? [NSString stringWithFormat:@" %d-bit", _bitDepth] : @"", _fps,
                a ? [NSString stringWithFormat:@" + %s", avcodec_get_name(_audioCodec)] : @" (no audio)"];
}
@end
