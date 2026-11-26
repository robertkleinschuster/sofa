#import "SFSegmentJob.h"
#import "SFSegmentTrack.h"
#import "SFCore.h"
#include <libavutil/opt.h>

static const NSTimeInterval kReadTimeout = 20;   // one blocking read of a source (a local route or file)

@implementation SFSegmentPlan
- (NSUInteger)segmentAt:(double)seconds {
    NSUInteger n = 0;
    for (NSUInteger i = 1; i < _starts.count; i++) if ([_starts[i] doubleValue] <= seconds + 0.001) n = i; else break;
    return n;
}
@end

static int CollectBytes(void *opaque, const uint8_t *buf, int size) {
    [(__bridge NSMutableData *)opaque appendBytes:buf length:(NSUInteger)size];
    return size;
}

@implementation SFSegmentJob {
    SFSegmentPlan *_plan;
    id<SFSegmentTrack> _video, _audio;
    AVFormatContext *_mux;
    NSMutableData *_bytes;     // what the muxer wrote since it was last taken
}

- (instancetype)initWithPlan:(SFSegmentPlan *)plan from:(NSUInteger)first {
    if ((self = [super init])) { _plan = plan; _first = first; _next = first; _bytes = [NSMutableData new]; }
    return self;
}

- (void)dealloc {
    if (_mux) {
        if (_mux->pb) { av_freep(&_mux->pb->buffer); avio_context_free(&_mux->pb); }
        avformat_free_context(_mux);
    }
}

- (void)start {
    [NSThread detachNewThreadSelector:@selector(run) toTarget:self withObject:nil];
}

- (void)cancel {
    _cancelled = YES;
    @synchronized (self) { [_video cancel]; [_audio cancel]; }
}

- (void)run {
    @autoreleasepool {
        [NSThread currentThread].name = @"Sofa transcode";
        [NSThread setThreadPriority:0.25];   // below the player and the UI
        NSString *failure = [self work];
        // the tracks go now, not whenever the job object does: the GPU's encoder is free for the next job
        @synchronized (self) { _video = nil; _audio = nil; }
        if (self.cancelled) failure = nil;
        void (^end)(NSString *) = self.onEnd;
        if (end) end(failure);
    }
}

- (NSString *)work {
    SFSegmentPlan *p = _plan;
    id<SFSegmentTrack> video = p.videoMode == SFSegmentModeCopy ? [[SFSegmentCopy alloc] initWithURL:p.videoURL type:AVMEDIA_TYPE_VIDEO timeout:kReadTimeout]
           : [[SFSegmentVideo alloc] initWithURL:p.videoURL encoder:p.encoder width:p.width height:p.height fps:p.fps
                                         bitrate:p.bitrate segment:(int64_t)(p.segment * 1e6) timeout:kReadTimeout];
    NSString *audioURL = p.audioURL ?: p.videoURL;
    id<SFSegmentTrack> audio = nil;
    if (p.audioMode == SFSegmentModeCopy) audio = [[SFSegmentCopy alloc] initWithURL:audioURL type:AVMEDIA_TYPE_AUDIO timeout:kReadTimeout];
    else if (p.audioMode == SFSegmentModeEncode) audio = [[SFSegmentAudio alloc] initWithURL:audioURL timeout:kReadTimeout];
    @synchronized (self) { _video = video; _audio = audio; }
    if (self.cancelled) return nil;
    int64_t startUs = (int64_t)([p.starts[_first] doubleValue] * 1e6);
    NSString *why = nil;
    if (![_video startAt:startUs error:&why]) return [@"video: " stringByAppendingString:why ?: @"?"];
    if (_audio && ![_audio startAt:startUs error:&why]) return [@"audio: " stringByAppendingString:why ?: @"?"];
    if ((why = [self openMuxer])) return why;
    if (self.onInit) self.onInit([self takeBytes]);
    BOOL videoEnded = NO, audioEnded = NO;
    for (NSUInteger n = _first; n < p.starts.count && !self.cancelled; n++) {
        int64_t endUs = n + 1 < p.starts.count ? (int64_t)([p.starts[n + 1] doubleValue] * 1e6) : INT64_MAX;
        NSArray *v = [_video packetsUntil:endUs eof:&videoEnded error:&why];
        if (!v) return self.cancelled ? nil : [@"video: " stringByAppendingString:why ?: @"?"];
        NSArray *a = _audio ? [_audio packetsUntil:endUs eof:&audioEnded error:&why] : @[];
        if (!a) return self.cancelled ? nil : [@"audio: " stringByAppendingString:why ?: @"?"];
        if ((why = [self writeFragment:v audio:a])) return why;
        NSData *segment = [self takeBytes];
        _next = n + 1;
        if (!self.onSegment || !self.onSegment(n, segment)) return nil;
        if (videoEnded && (!_audio || audioEnded)) break;   // the source is shorter than its stated duration
    }
    if (!self.cancelled) _finished = YES;
    return nil;
}

// The fragmented-MP4 muxer into memory: the init (ftyp + empty moov) now, a fragment per flush
- (NSString *)openMuxer {
    int r = avformat_alloc_output_context2(&_mux, NULL, "mp4", NULL);
    if (r < 0 || !_mux) return @"no MP4 muxer";
    for (id<SFSegmentTrack> t in _audio ? @[_video, _audio] : @[_video]) {
        AVStream *st = avformat_new_stream(_mux, NULL);
        if (!st || avcodec_parameters_copy(st->codecpar, t.parameters) < 0) return @"muxer stream";
        st->codecpar->codec_tag = 0;
        if (st->codecpar->codec_id == AV_CODEC_ID_HEVC) st->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');   // what Apple's players read
        st->time_base = t.timeBase;
    }
    unsigned char *buf = av_malloc(1 << 16);
    _mux->pb = avio_alloc_context(buf, 1 << 16, 1, (__bridge void *)_bytes, NULL, CollectBytes, NULL);
    if (!_mux->pb) return @"no memory";
    _mux->flags |= AVFMT_FLAG_CUSTOM_IO;
    // the timestamps stay the source's (+ the offset, never negative): without an edit list the muxer
    // would otherwise shift every job to start at 0, and segments of different jobs would not line up
    _mux->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    AVDictionary *o = NULL;
    // fragments only when told (one per segment), an empty moov, offsets from the moof (what MSE
    // and Safari expect), no edit list: every fragment's decode time (tfdt) is its first packet's
    av_dict_set(&o, "movflags", "frag_custom+empty_moov+default_base_moof", 0);
    av_dict_set(&o, "use_editlist", "0", 0);
    av_dict_set(&o, "video_track_timescale", "90000", 0);
    r = avformat_write_header(_mux, &o);
    av_dict_free(&o);
    if (r < 0) return [NSString stringWithFormat:@"MP4 header: %s", av_err2str(r)];
    avio_flush(_mux->pb);
    return nil;
}

- (NSString *)writeFragment:(NSArray *)video audio:(NSArray *)audio {
    // each fragment's decode time from its own first packet (segments of separate jobs line up exactly)
    av_opt_set(_mux->priv_data, "movflags", "+frag_discont", 0);
    NSArray *tracks = @[video, audio];
    NSArray *sources = _audio ? @[_video, _audio] : @[_video];
    for (NSUInteger i = 0; i < sources.count; i++) {
        AVStream *st = _mux->streams[i];
        id<SFSegmentTrack> t = sources[i];
        AVRational from = t.timeBase;
        for (SFAVPacket *p in tracks[i]) {
            AVPacket *q = p.packet;
            av_packet_rescale_ts(q, from, st->time_base);
            q->stream_index = (int)i;
            q->pos = -1;
            int r = av_write_frame(_mux, q);
            if (r < 0) return [NSString stringWithFormat:@"MP4 write: %s", av_err2str(r)];
        }
    }
    int r = av_write_frame(_mux, NULL);   // flush: the fragment
    if (r < 0) return [NSString stringWithFormat:@"MP4 fragment: %s", av_err2str(r)];
    avio_flush(_mux->pb);
    return nil;
}

- (NSData *)takeBytes {
    NSData *d = [_bytes copy];
    [_bytes setLength:0];
    return d;
}
@end
