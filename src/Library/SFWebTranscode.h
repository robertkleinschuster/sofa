// SFWebTranscode - a playback of Sofa im Browser cut into HLS segments on demand (docs/pwa.md §8): a
// source the browser can't play as it is (a stored YouTube video's VP9/AV1 + Opus for Safari, two
// separate WebM tracks for any browser, a local MKV) becomes fragmented-MP4 HLS - every track copied
// where the browser decodes its codec, else encoded (H.264: VideoToolbox, then x264; AAC). Nothing is
// made ahead of need: a job starts at the segment asked for (a seek is a new job), runs a few
// segments ahead of the player and waits, stops when nobody asked for a while; segments are kept in
// memory within a bound and go with the session. One session encodes video at a time.
#import <Foundation/Foundation.h>
#import "SFLocalHTTP.h"
#import "SFSegmentJob.h"

extern NSString *const SFWebTranscodeBusyMessage;   // the viewer's message when another device's playback encodes

@interface SFWebTranscode : NSObject
// A session for a stream; nil + *why when another device's playback encodes right now (one at a time).
+ (instancetype)sessionWithPlan:(SFSegmentPlan *)plan stream:(NSString *)streamID device:(NSString *)device error:(NSString **)why;
// Its first job from the segment at `seconds`; done(nil) once the init is there (the encoder opened),
// done(why) when it failed. Main thread.
- (void)prepareAt:(double)seconds done:(void (^)(NSString *failure))done;
@property (nonatomic, readonly, copy) NSString *playlist;   // the HLS media playlist (init.mp4, s/<n>.m4s)
@property (nonatomic, readonly) double duration;            // s (the plan's)
@property (nonatomic, readonly, copy) NSString *mode;       // for the log and the answer: "copy+aac", "h264_videotoolbox+copy", ...
// The server's queue: GET init.mp4 / s/<n>.m4s
- (void)serveInit:(SFHTTPExchange *)x;
- (void)serveSegment:(NSUInteger)n to:(SFHTTPExchange *)x;
- (void)close;    // the stream ended: the job stops, the segments go
- (void)dropSegments;   // the stream waits paused: its made segments go (made again when asked for)
+ (NSUInteger)activeJobsForTesting;
@end

@interface SFWebTranscode (Plan)   // SFWebTranscode+Plan.m
// How `video` (+ `audio`, nil: in the video's input) becomes something a browser decoding `formats`
// (SFAVBrowserCodec names: avc1, vp09, av01, hvc1, mp4a, opus) plays. Blocking (a background queue):
// reads the source's headers. nil when it needs no segmenter (*asIs: one MP4 file of codecs the browser
// plays) or can't help (*why, for the log). `keyframes` (s): where the video's segments may start, when
// the caller knows them (a fragmented MP4's sidx); else the container's index.
+ (SFSegmentPlan *)planVideo:(NSString *)video audio:(NSString *)audio formats:(NSSet *)formats
                   keyframes:(NSArray *)keyframes asIs:(BOOL *)asIs error:(NSString **)why;
@end
