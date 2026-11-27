// SFSegmentJob - one run of the browser segmenter (docs/pwa.md §8): from a segment on, the source's
// tracks (SFSegmentTrack: copied or encoded) as fragmented MP4 - the init segment (ftyp + moov, the
// same for every run of a plan) and one fragment (moof + mdat) per HLS segment, each starting where the
// plan says, with the source's timestamps (+ SFSegmentOffsetUs). A job runs on a thread of its own
// at low priority (the TV's player and UI come first) and makes one segment after the other as long
// as its session lets it (onSegment); a seek elsewhere is a new job.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SFSegmentMode) { SFSegmentModeNone, SFSegmentModeCopy, SFSegmentModeEncode };

// What a session decided for a source (SFWebTranscode): pure data, shared by its jobs
@interface SFSegmentPlan : NSObject
@property (nonatomic, copy) NSString *videoURL, *audioURL;   // audioURL nil: the audio is in the video's input
@property (nonatomic) SFSegmentMode videoMode, audioMode;    // audio SFSegmentModeNone: no audio track
@property (nonatomic, copy) NSString *encoder;               // h264_videotoolbox | libx264 | libsvtav1 (video encoded)
@property (nonatomic) int width, height;                     // encoded video
@property (nonatomic) double fps;                            // encoded video
@property (nonatomic) long long bitrate;                     // encoded video, bits/s
@property (nonatomic) double segment;                        // encoded video: seconds per segment
@property (nonatomic, copy) NSArray *starts;                 // every segment's start (s, ascending, first 0)
@property (nonatomic) double duration;                       // s
- (NSUInteger)segmentAt:(double)seconds;                     // the segment playing at that time
@end

@interface SFSegmentJob : NSObject
- (instancetype)initWithPlan:(SFSegmentPlan *)plan from:(NSUInteger)first;
@property (nonatomic, readonly) NSUInteger first;
@property (atomic, readonly) NSUInteger next;          // the segment in the making (count: done)
// Called on the job's thread. onSegment returns whether to go on (it may wait first - pacing);
// onEnd: nil at the source's end or when cancelled, else why it failed.
@property (nonatomic, copy) void (^onInit)(NSData *init);
@property (nonatomic, copy) BOOL (^onSegment)(NSUInteger n, NSData *data);
@property (nonatomic, copy) void (^onEnd)(NSString *failure);
- (void)start;
- (void)cancel;   // any thread: reads give up, no further segment
@property (atomic, readonly) BOOL cancelled;
@property (atomic, readonly) BOOL finished;   // made the last segment (the source's end)
@end
