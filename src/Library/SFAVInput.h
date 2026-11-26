// SFAVInput - one track of a media source read with libavformat (the FFmpeg libraries libmpv uses,
// bundled in Contents/Frameworks), for the browser segmenter (SFSegmentJob, docs/pwa.md §8): a file
// or a local route (Sofa's media proxy, the YouTube engine's stored sessions - http://127.0.0.1),
// only the packets of the chosen stream, every blocking read bounded by a deadline and cancellable
// from another thread. Also what a source is (SFAVProbe): codecs as the browser names them, size,
// frame rate, duration and the keyframes its index names - read from the container, never guessed.
#import <Foundation/Foundation.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>

// RFC 6381 sample entry of a codec as browsers name it in MediaSource.isTypeSupported - avc1, hvc1,
// vp09, av01, mp4a (AAC), opus; nil for codecs a browser plays in no MP4 (the segmenter encodes those)
NSString *SFAVBrowserCodec(enum AVCodecID codec);

@interface SFAVInput : NSObject
// Opens `url` (a path or an http://127.0.0.1 route) and picks the best stream of `type`; nil + *why
// when it can't. Seconds: the bound of every single blocking step (open, a read, a seek).
+ (instancetype)open:(NSString *)url type:(enum AVMediaType)type timeout:(NSTimeInterval)seconds error:(NSString **)why;
@property (nonatomic, readonly) AVFormatContext *format;
@property (nonatomic, readonly) AVStream *stream;
// The next packet of the stream (the caller unrefs it): 0, AVERROR_EOF or another error
- (int)read:(AVPacket *)packet;
// To the last keyframe at or before `us` (microseconds of the source's timeline); NO on an error
- (BOOL)seek:(int64_t)us;
- (int64_t)microseconds:(int64_t)ts;      // a timestamp of the stream in microseconds (AV_NOPTS_VALUE stays)
- (void)cancel;                           // any thread: the current and every later read fails
@property (nonatomic, readonly) BOOL cancelled;
@end

// What a source is: its video and audio tracks (`audioURL` nil: the audio is in the video's input)
@interface SFAVProbe : NSObject
+ (instancetype)probeVideo:(NSString *)videoURL audio:(NSString *)audioURL timeout:(NSTimeInterval)seconds error:(NSString **)why;
@property (nonatomic, readonly) enum AVCodecID videoCodec, audioCodec;   // AV_CODEC_ID_NONE: no such track
@property (nonatomic, readonly, copy) NSString *videoTag, *audioTag;     // SFAVBrowserCodec (nil: none / not in MP4)
@property (nonatomic, readonly) BOOL audioCopyable;   // its packets go into MP4 as they are (AAC with its config, Opus)
@property (nonatomic, readonly) int width, height, bitDepth;
@property (nonatomic, readonly) double fps, duration;                    // frames per second, seconds
@property (nonatomic, readonly) BOOL mp4File;                            // one MP4 file (video + audio) a browser reads as is
// Keyframe times (s, ascending) from the container's index (WebM cues, an MP4's sync samples); nil
// when it names none beyond the first (a fragmented MP4 - its sidx is read by SFWebHLS)
@property (nonatomic, readonly, copy) NSArray *keyframes;
@property (nonatomic, readonly, copy) NSString *summary;                 // for the log: "vp9 1920x1080 60 fps + opus"
@end
