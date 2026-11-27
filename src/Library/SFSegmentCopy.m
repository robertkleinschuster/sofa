// SFSegmentCopy - a track whose codec the browser plays: its packets as they are, only cut at the
// segment boundaries (video: at the keyframe that starts a segment) and shifted by SFSegmentOffsetUs.
#import "SFSegmentTrack.h"

static const int64_t kSlackUs = 2000;   // timestamps of one instant may differ by rounding between tracks/index

@implementation SFAVPacket {
    AVPacket *_packet;
}
+ (instancetype)taking:(AVPacket *)packet {
    SFAVPacket *p = [SFAVPacket new];
    p->_packet = av_packet_alloc();
    av_packet_move_ref(p->_packet, packet);
    return p;
}
- (AVPacket *)packet { return _packet; }
- (void)dealloc { av_packet_free(&_packet); }
@end

@implementation SFSegmentCopy {
    int64_t _originUs;
    NSString *_url;
    enum AVMediaType _type;
    NSTimeInterval _timeout;
    SFAVInput *_in;
    SFAVPacket *_pending;    // read past the last boundary: the next segment's first packet
    int64_t _startUs, _offset, _lastDuration;
    BOOL _skipping, _cancelled;
}

- (instancetype)initWithURL:(NSString *)url type:(enum AVMediaType)type timeout:(NSTimeInterval)seconds {
    if ((self = [super init])) { _url = [url copy]; _type = type; _timeout = seconds; }
    return self;
}

@synthesize originUs = _originUs;
- (const AVCodecParameters *)parameters { return _in.stream->codecpar; }
- (AVRational)timeBase { return _in.stream->time_base; }
- (void)cancel { _cancelled = YES; [_in cancel]; }

- (BOOL)startAt:(int64_t)us error:(NSString **)why {
    if (!_in && !(_in = [SFAVInput open:_url type:_type timeout:_timeout error:why])) return NO;
    if (_cancelled) [_in cancel];
    _in.originUs = _originUs;
    _offset = av_rescale_q(SFSegmentOffsetUs - _originUs, AV_TIME_BASE_Q, _in.stream->time_base);
    _pending = nil;
    _startUs = us;
    _skipping = YES;
    if (![_in seek:us]) { if (why) *why = @"seek failed"; return NO; }
    return YES;
}

- (int64_t)timeOf:(AVPacket *)p { return [_in microseconds:p->pts != AV_NOPTS_VALUE ? p->pts : p->dts]; }

- (NSArray *)packetsUntil:(int64_t)endUs eof:(BOOL *)eof error:(NSString **)why {
    NSMutableArray *out = [NSMutableArray new];
    BOOL video = _type == AVMEDIA_TYPE_VIDEO;
    *eof = NO;
    AVPacket *pkt = av_packet_alloc();
    for (;;) {
        SFAVPacket *p = _pending;
        _pending = nil;
        if (!p) {
            int r = [_in read:pkt];
            if (r == AVERROR_EOF) { *eof = YES; break; }
            if (r < 0) { if (why) *why = [NSString stringWithFormat:@"read: %s", av_err2str(r)]; av_packet_free(&pkt); return nil; }
            p = [SFAVPacket taking:pkt];
        }
        AVPacket *q = p.packet;
        int64_t t = [self timeOf:q], dur = [_in durationMicroseconds:q->duration];
        BOOL key = (q->flags & AV_PKT_FLAG_KEY) != 0;
        if (t == AV_NOPTS_VALUE) continue;   // no time: no place in a segment
        if (_skipping) {   // after a seek: from the keyframe at the start / the audio around it
            if (video ? !(key && t >= _startUs - kSlackUs) : t + MAX(dur, 0) <= _startUs) continue;
            _skipping = NO;
        }
        if (out.count && (video ? (key && t >= endUs - kSlackUs) : t >= endUs)) { _pending = p; break; }
        if (q->dts == AV_NOPTS_VALUE) q->dts = q->pts;
        if (q->pts == AV_NOPTS_VALUE) q->pts = q->dts;
        [out addObject:p];
    }
    av_packet_free(&pkt);
    // durations from the next packet where the container gave none; shifted onto the output timeline
    for (NSUInteger i = 0; i < out.count; i++) {
        AVPacket *q = [out[i] packet];
        AVPacket *next = i + 1 < out.count ? [out[i + 1] packet] : _pending.packet;
        if (q->duration <= 0) q->duration = next && next->dts != AV_NOPTS_VALUE && next->dts > q->dts ? next->dts - q->dts : _lastDuration;
        if (q->duration > 0) _lastDuration = q->duration;
        q->pts += _offset; q->dts += _offset;
    }
    return out;
}
@end
