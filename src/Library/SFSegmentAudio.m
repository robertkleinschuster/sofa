// SFSegmentAudio - an audio track the browser can't play (Opus for Safari, AC-3, MP3, ...) as AAC-LC
// stereo 48 kHz: decoded, resampled/downmixed, encoded by FFmpeg's AAC encoder (cheap: a few percent of
// one core), its samples continuous from the start position on.
#import "SFSegmentTrack.h"
#include <libswresample/swresample.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/opt.h>

static const int kRate = 48000;

@implementation SFSegmentAudio {
    NSString *_url;
    NSTimeInterval _timeout;
    SFAVInput *_in;
    AVCodecContext *_dec, *_enc;
    AVCodecParameters *_par;
    SwrContext *_swr;
    AVAudioFifo *_fifo;
    AVFrame *_frame, *_chunk;
    AVPacket *_pkt;
    SFAVPacket *_pending;            // encoded, belongs to the next segment
    int64_t _startUs, _nextSample;   // the next encoded frame's first sample (1/48000 s)
    BOOL _started, _inputDone, _decoderDone, _encoderFlushed, _cancelled;
}

- (instancetype)initWithURL:(NSString *)url timeout:(NSTimeInterval)seconds {
    if ((self = [super init])) { _url = [url copy]; _timeout = seconds; _pkt = av_packet_alloc(); _frame = av_frame_alloc(); _chunk = av_frame_alloc(); }
    return self;
}

- (void)dealloc {
    [_inputs keep:_in url:_url];   // whole: the playback's next job goes on with it
    avcodec_free_context(&_dec); avcodec_free_context(&_enc); avcodec_parameters_free(&_par);
    swr_free(&_swr);
    if (_fifo) av_audio_fifo_free(_fifo);
    av_frame_free(&_frame); av_frame_free(&_chunk); av_packet_free(&_pkt);
}

@synthesize originUs = _originUs, inputs = _inputs;
- (const AVCodecParameters *)parameters { return _par; }
- (AVRational)timeBase { return (AVRational){1, kRate}; }
- (void)cancel { _cancelled = YES; [_in cancel]; }

- (BOOL)startAt:(int64_t)us error:(NSString **)why {
    if (!_in && ![self openWithError:why]) return NO;
    if (![_in seek:us]) { if (why) *why = @"seek failed"; return NO; }
    avcodec_flush_buffers(_dec);
    av_audio_fifo_reset(_fifo);
    swr_close(_swr); swr_init(_swr);
    _startUs = us; _started = NO; _inputDone = _decoderDone = NO; _pending = nil;
    return YES;
}

- (BOOL)openWithError:(NSString **)why {
    if (!(_in = _inputs ? [_inputs open:_url type:AVMEDIA_TYPE_AUDIO timeout:_timeout error:why]
                        : [SFAVInput open:_url type:AVMEDIA_TYPE_AUDIO timeout:_timeout error:why])) return NO;
    _in.originUs = _originUs;
    if (_cancelled) [_in cancel];
    AVCodecParameters *sp = _in.stream->codecpar;
    const AVCodec *dc = avcodec_find_decoder(sp->codec_id);
    if (!dc) { if (why) *why = [NSString stringWithFormat:@"no decoder for %s", avcodec_get_name(sp->codec_id)]; return NO; }
    _dec = avcodec_alloc_context3(dc);
    avcodec_parameters_to_context(_dec, sp);
    _dec->pkt_timebase = _in.stream->time_base;
    int r = avcodec_open2(_dec, dc, NULL);
    if (r < 0) { if (why) *why = [NSString stringWithFormat:@"audio decoder: %s", av_err2str(r)]; return NO; }
    const AVCodec *ec = avcodec_find_encoder_by_name("aac");
    _enc = ec ? avcodec_alloc_context3(ec) : NULL;
    if (!_enc) { if (why) *why = @"no AAC encoder"; return NO; }
    _enc->sample_rate = kRate;
    _enc->sample_fmt = AV_SAMPLE_FMT_FLTP;
    av_channel_layout_default(&_enc->ch_layout, 2);
    _enc->bit_rate = 160000;
    _enc->time_base = (AVRational){1, kRate};
    _enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if ((r = avcodec_open2(_enc, ec, NULL)) < 0) { if (why) *why = [NSString stringWithFormat:@"AAC encoder: %s", av_err2str(r)]; return NO; }
    _par = avcodec_parameters_alloc();
    avcodec_parameters_from_context(_par, _enc);
    AVChannelLayout in = {0};
    if (_dec->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC || !_dec->ch_layout.nb_channels) av_channel_layout_default(&in, MAX(1, _dec->ch_layout.nb_channels));
    else av_channel_layout_copy(&in, &_dec->ch_layout);
    r = swr_alloc_set_opts2(&_swr, &_enc->ch_layout, AV_SAMPLE_FMT_FLTP, kRate, &in, _dec->sample_fmt, _dec->sample_rate, 0, NULL);
    av_channel_layout_uninit(&in);
    if (r < 0 || swr_init(_swr) < 0) { if (why) *why = @"resampler"; return NO; }
    _fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, 2, _enc->frame_size * 4);
    return _fifo != NULL;
}

// More samples into the FIFO (one decoded frame, the part at/after the start); NO at the end of the input
- (BOOL)decodeMore:(NSString **)why {
    for (;;) {
        int r = avcodec_receive_frame(_dec, _frame);
        if (r == 0) break;
        if (r == AVERROR_EOF) { _decoderDone = YES; return [self drainResampler]; }
        if (r != AVERROR(EAGAIN)) { if (why) *why = [NSString stringWithFormat:@"audio decode: %s", av_err2str(r)]; return NO; }
        if (_inputDone) { avcodec_send_packet(_dec, NULL); continue; }
        r = [_in read:_pkt];
        if (r == AVERROR_EOF) { _inputDone = YES; avcodec_send_packet(_dec, NULL); continue; }
        if (r < 0) { if (why) *why = [NSString stringWithFormat:@"audio read: %s", av_err2str(r)]; return NO; }
        r = avcodec_send_packet(_dec, _pkt);
        av_packet_unref(_pkt);
        if (r < 0 && r != AVERROR_INVALIDDATA) { if (why) *why = [NSString stringWithFormat:@"audio decode: %s", av_err2str(r)]; return NO; }
    }
    int64_t t = [_in microseconds:_frame->best_effort_timestamp];
    int64_t frameUs = av_rescale(_frame->nb_samples, AV_TIME_BASE, MAX(1, _frame->sample_rate));
    if (!_started && (t == AV_NOPTS_VALUE || t + frameUs <= _startUs)) { av_frame_unref(_frame); return YES; }
    int skip = 0;
    if (!_started) {   // the samples before the start go; the timeline begins exactly there (or at the first sample after it)
        int64_t first = MAX(t, _startUs);
        _nextSample = av_rescale(first, kRate, AV_TIME_BASE);
        skip = t < _startUs ? (int)av_rescale(_startUs - t, kRate, AV_TIME_BASE) : 0;
        _started = YES;
    }
    int max = swr_get_out_samples(_swr, _frame->nb_samples);
    uint8_t **buf = NULL;
    if (av_samples_alloc_array_and_samples(&buf, NULL, 2, max, AV_SAMPLE_FMT_FLTP, 0) < 0) { av_frame_unref(_frame); if (why) *why = @"no memory"; return NO; }
    int n = swr_convert(_swr, buf, max, (const uint8_t **)_frame->extended_data, _frame->nb_samples);
    av_frame_unref(_frame);
    if (n > skip) {
        uint8_t *planes[2] = { buf[0] + skip * sizeof(float), buf[1] + skip * sizeof(float) };
        av_audio_fifo_write(_fifo, (void **)planes, n - skip);
    }
    av_freep(&buf[0]); av_freep(&buf);
    return YES;
}

- (BOOL)drainResampler {
    int max = swr_get_out_samples(_swr, 0);
    if (max <= 0 || !_started) return NO;
    uint8_t **buf = NULL;
    if (av_samples_alloc_array_and_samples(&buf, NULL, 2, max, AV_SAMPLE_FMT_FLTP, 0) < 0) return NO;
    int n = swr_convert(_swr, buf, max, NULL, 0);
    if (n > 0) av_audio_fifo_write(_fifo, (void **)buf, n);
    av_freep(&buf[0]); av_freep(&buf);
    return NO;
}

// One encoder frame from the FIFO (a short last one at the end); NO when there was nothing to send
- (BOOL)sendFrame:(NSString **)why {
    int size = _enc->frame_size;
    while (av_audio_fifo_size(_fifo) < size && !_decoderDone) {
        NSString *err = nil;
        if (![self decodeMore:&err] && err) { if (why) *why = err; return NO; }
        if (_cancelled) { if (why) *why = @"cancelled"; return NO; }
    }
    int n = MIN(size, av_audio_fifo_size(_fifo));
    if (n <= 0) return NO;
    _chunk->nb_samples = n; _chunk->format = AV_SAMPLE_FMT_FLTP; _chunk->sample_rate = kRate;
    av_channel_layout_copy(&_chunk->ch_layout, &_enc->ch_layout);
    if (av_frame_get_buffer(_chunk, 0) < 0) { if (why) *why = @"no memory"; return NO; }
    av_audio_fifo_read(_fifo, (void **)_chunk->data, n);
    _chunk->pts = _nextSample;
    _nextSample += n;
    int r = avcodec_send_frame(_enc, _chunk);
    av_frame_unref(_chunk);
    if (r < 0) { if (why) *why = [NSString stringWithFormat:@"AAC encode: %s", av_err2str(r)]; return NO; }
    return YES;
}

- (NSArray *)packetsUntil:(int64_t)endUs eof:(BOOL *)eof error:(NSString **)why {
    NSMutableArray *out = [NSMutableArray new];
    int64_t offset = av_rescale_q(SFSegmentOffsetUs, AV_TIME_BASE_Q, self.timeBase);
    *eof = NO;
    for (;;) {
        SFAVPacket *p = _pending;
        _pending = nil;
        if (!p) {
            int r = avcodec_receive_packet(_enc, _pkt);
            if (r == AVERROR_EOF) { *eof = YES; return out; }
            if (r == AVERROR(EAGAIN)) {
                if (_encoderFlushed) { *eof = YES; return out; }
                NSString *err = nil;
                if (![self sendFrame:&err]) {
                    if (err) { if (why) *why = err; return nil; }
                    avcodec_send_frame(_enc, NULL); _encoderFlushed = YES;
                }
                continue;
            }
            if (r < 0) { if (why) *why = [NSString stringWithFormat:@"AAC encode: %s", av_err2str(r)]; return nil; }
            p = [SFAVPacket taking:_pkt];
        }
        AVPacket *q = p.packet;
        if (av_rescale(q->pts, AV_TIME_BASE, kRate) >= endUs) { _pending = p; return out; }
        q->pts += offset; q->dts = q->pts;
        [out addObject:p];
    }
}
@end
