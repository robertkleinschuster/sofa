// SFSegmentTrack - one track of the browser segmenter (SFSegmentJob, docs/pwa.md §8): from a start
// position on, the packets up to each segment boundary in the output's time base, ready for the
// fragmented-MP4 muxer. Three kinds: copied as they are (SFSegmentCopy), video encoded (SFSegmentVideo:
// H.264 by VideoToolbox - the GPU's encoder - or x264; AV1 by SVT-AV1), audio encoded to AAC (SFSegmentAudio).
// A track runs on its job's thread; only -cancel may come from another one.
#import "SFAVInput.h"

// Every output timestamp is the source's plus this (µs): MP4 fragments carry no negative decode
// times, and the first packets of a source may have them (B-frames, Opus pre-skip). A constant shift
// of the whole presentation: players map it to the playlist's timeline.
static const int64_t SFSegmentOffsetUs = 10000000;

// An AVPacket owned by an object (freed with it)
@interface SFAVPacket : NSObject
@property (nonatomic, readonly) AVPacket *packet;
+ (instancetype)taking:(AVPacket *)packet;   // takes the reference (`packet` is left blank)
@end

@protocol SFSegmentTrack <NSObject>
// Opens the source (the first time) and goes to `us` (µs of the source): the first packet is the one at it
- (BOOL)startAt:(int64_t)us error:(NSString **)why;
@property (nonatomic, readonly) const AVCodecParameters *parameters;   // the output's (after startAt:)
@property (nonatomic, readonly) AVRational timeBase;                   // of the packets handed out
// The packets from where the last call ended up to `endUs` (µs of the source; INT64_MAX: to the end),
// in decode order, durations set. *eof: the source has nothing after them. nil + *why on an error.
- (NSArray *)packetsUntil:(int64_t)endUs eof:(BOOL *)eof error:(NSString **)why;
- (void)cancel;
@end

@interface SFSegmentCopy : NSObject <SFSegmentTrack>
// A video track starts its segments at keyframes (the boundaries are keyframe times); audio by time
- (instancetype)initWithURL:(NSString *)url type:(enum AVMediaType)type timeout:(NSTimeInterval)seconds;
@end

@interface SFSegmentVideo : NSObject <SFSegmentTrack>
// `encoder`'s codec (H.264: h264_videotoolbox | libx264, AV1: libsvtav1) of at most `height` lines at
// `fps` (frames of a faster source are left out evenly) and about `bitrate` bits/s (AV1: its ceiling),
// a keyframe opening every multiple of `segmentUs`.
- (instancetype)initWithURL:(NSString *)url encoder:(NSString *)encoder width:(int)width height:(int)height fps:(double)fps
                    bitrate:(long long)bitrate segment:(int64_t)segmentUs timeout:(NSTimeInterval)seconds;
// The encoders of `codec` (avc1 | av01, SFAVBrowserCodec names) this machine opens, best first (tried
// once: VideoToolbox only with the hardware)
+ (NSArray *)encodersFor:(NSString *)codec;
// ... those that take a picture of that size (this Mac's VideoToolbox encoder: at least 640 on the
// longer side - smaller sessions are refused, -8973, measured 2026-11-26)
+ (NSArray *)encodersFor:(NSString *)codec width:(int)width height:(int)height;
+ (void)encoderFailed:(NSString *)encoder;   // it broke during a job: not offered again until relaunch
@end

@interface SFSegmentAudio : NSObject <SFSegmentTrack>
// AAC-LC stereo 48 kHz
- (instancetype)initWithURL:(NSString *)url timeout:(NSTimeInterval)seconds;
@end
