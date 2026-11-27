// SFWebTranscode - the plan: what is copied, what is encoded and how, where the segments start.
// Caps follow from what this Mac encodes in real time with room to spare (measured 2026-11-26 on the
// i5-2500S, VP9 1080p60 source, docs/pwa.md §8): VideoToolbox 1080p30 2.3x real time (1080p60 only
// 1.17x - too tight), x264 veryfast/zerolatency 1080p30 4.7x. So: at most 1080 lines and at most the
// pixel rate of 1080p30 - a faster source keeps its size and loses every second frame (720p60 stays 60).
// AV1 (SVT-AV1, measured 2026-11-27 on 20 s of a 50 fps broadcast): 720p50 2.65x real time, 1080p50
// only 1.48x with every core busy - so at most 720 lines; its rate is a ceiling (constant quality below).
#import "SFWebTranscode.h"
#import "SFSegmentTrack.h"
#import "SFCore.h"

static const double kSegment = 4;                          // s of an encoded segment; copied ones: from keyframe to keyframe, at least this
static const double kMaxPixelRate = 1920.0 * 1080 * 30 * 1.05;
static const int kMaxHeight = 1080;
static const int kMaxHeightAV1 = 720;
static const NSTimeInterval kProbeTimeout = 20;

@implementation SFWebTranscode (Plan)

+ (SFSegmentPlan *)planVideo:(NSString *)video audio:(NSString *)audio formats:(NSSet *)formats
                   keyframes:(NSArray *)keyframes reencode:(NSString *)reencode asIs:(BOOL *)asIs error:(NSString **)why {
    *asIs = NO;
    SFAVProbe *p = [SFAVProbe probeVideo:video audio:audio timeout:kProbeTimeout error:why];
    if (!p) return nil;
    if (!(p.duration > 0)) { if (why) *why = @"no duration"; return nil; }
    SFSegmentPlan *plan = [SFSegmentPlan new];
    BOOL copyVideo = p.videoTag && [formats containsObject:p.videoTag];
    // re-encoded where the browser plays the source as it is: into `reencode` (fewer bytes), when the
    // source isn't that already and Sofa has an encoder for it - else copied as before
    BOOL into = copyVideo && reencode && ![p.videoTag isEqualToString:reencode] && [formats containsObject:reencode]
             && [self capPlan:plan probe:p codec:reencode];
    if (into) copyVideo = NO;
    BOOL copyAudio = p.audioTag && p.audioCopyable && [formats containsObject:p.audioTag];
    BOOL noAudio = p.audioCodec == AV_CODEC_ID_NONE;
    if (p.mp4File && copyVideo && (noAudio || copyAudio)) { *asIs = YES; return nil; }
    // an HLS presentation the browser decodes: its own HLS player reads it (an ADTS audio track isn't
    // copyable into MP4, but the browser plays it)
    if (p.hls && copyVideo && (noAudio || [formats containsObject:p.audioTag ?: @""])) { *asIs = YES; return nil; }
    plan.videoURL = video; plan.audioURL = audio; plan.duration = p.duration; plan.originUs = p.originUs;
    NSArray *keys = keyframes.count > 1 ? keyframes : p.keyframes;
    if (into) {
        plan.videoMode = SFSegmentModeEncode;
    } else if (copyVideo && keys.count > 1) {
        plan.videoMode = SFSegmentModeCopy;
        NSMutableArray *starts = [NSMutableArray arrayWithObject:@0];
        for (NSNumber *k in keys)
            if (k.doubleValue - [starts.lastObject doubleValue] >= kSegment - 0.01 && k.doubleValue < p.duration - 0.5) [starts addObject:k];
        plan.starts = starts;
    } else if ([formats containsObject:@"avc1"] && [self capPlan:plan probe:p codec:@"avc1"]) {
        plan.videoMode = SFSegmentModeEncode;
    } else {
        if (why) *why = [NSString stringWithFormat:@"%@ - the browser decodes neither it nor H.264 (or no H.264 encoder here)", p.summary];
        return nil;
    }
    if (noAudio) plan.audioMode = SFSegmentModeNone;
    else if (copyAudio) plan.audioMode = SFSegmentModeCopy;
    else if ([formats containsObject:@"mp4a"]) plan.audioMode = SFSegmentModeEncode;
    else { if (why) *why = [NSString stringWithFormat:@"%@ - the browser decodes neither its audio nor AAC", p.summary]; return nil; }
    plan.inputs = [SFAVInputPool new];
    [p keepInputsIn:plan.inputs video:video audio:audio];   // the first job goes on with them
    SFLog(@"transcode: %@ -> %@ (%lu segments)", p.summary, [self describe:plan], (unsigned long)plan.starts.count);
    return plan;
}

// Encoder, size, rate, bit rate and segments of a video encoded into `codec` (avc1 | av01); NO without
// an encoder for it
+ (BOOL)capPlan:(SFSegmentPlan *)plan probe:(SFAVProbe *)p codec:(NSString *)codec {
    BOOL av1 = [codec isEqualToString:@"av01"];
    int h = MIN(p.height, av1 ? kMaxHeightAV1 : kMaxHeight) & ~1;
    int w = p.height > 0 ? (int)lround((double)p.width * h / p.height) & ~1 : p.width & ~1;
    double fps = p.fps > 0 ? p.fps : 30;
    while ((double)w * h * fps > kMaxPixelRate && fps > 31) fps /= 2;   // 60 -> 30, 50 -> 25: every second frame
    plan.width = MAX(w, 2); plan.height = MAX(h, 2); plan.fps = fps;
    plan.encoder = [SFSegmentVideo encodersFor:codec width:plan.width height:plan.height].firstObject;
    if (!plan.encoder) return NO;
    // H.264 ~0.1 bit per pixel: 1080p30 6 Mbit/s, 720p30 2.8 Mbit/s (VMAF 94.9 at 5.5 Mbit/s 1080p30 with
    // VideoToolbox here; x264 gets the same as its ceiling). AV1: a ceiling of ~0.05 (720p50 2.3 Mbit/s)
    // above its constant quality (~1.1 Mbit/s on a 720p50 broadcast) - only busy pictures reach it
    plan.bitrate = av1 ? (long long)MIN(4e6, MAX(1e6, 0.05 * w * h * fps)) : (long long)MIN(8e6, MAX(1.5e6, 0.1 * w * h * fps));
    int perSegment = MAX(1, (int)llround(kSegment * fps));
    plan.segment = perSegment / fps;
    NSMutableArray *starts = [NSMutableArray new];
    for (NSUInteger k = 0; k * plan.segment < p.duration - 0.05 || k == 0; k++) [starts addObject:@(k * perSegment / fps)];
    plan.starts = starts;
    return YES;
}

+ (NSString *)describe:(SFSegmentPlan *)plan {
    NSString *v = plan.videoMode == SFSegmentModeCopy ? @"video copied"
                : [NSString stringWithFormat:@"%@ %dx%d %.4g fps %.1f Mbit/s", plan.encoder, plan.width, plan.height, plan.fps, plan.bitrate / 1e6];
    NSString *a = plan.audioMode == SFSegmentModeCopy ? @"audio copied" : plan.audioMode == SFSegmentModeEncode ? @"AAC" : @"no audio";
    return [NSString stringWithFormat:@"%@ + %@", v, a];
}
@end
