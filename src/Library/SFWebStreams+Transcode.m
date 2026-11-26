// SFWebStreams - a stream through the segmenter (SFWebTranscode, docs/pwa.md §8): what the browser can't
// play as it is - a stored YouTube video's VP9/AV1 + Opus, two separate tracks, a local MKV - is cut into
// HLS segments, every track copied where the browser decodes it, else encoded. Encoders in order: the
// GPU's (VideoToolbox), x264; when neither works the caller falls back (YouTube: the online H.264 session).
#import "SFWebStreams+Private.h"
#import "SFSegmentTrack.h"

@implementation SFWebStreams (Transcode)

- (void)segment:(SFWebStream *)s video:(NSString *)video audio:(NSString *)audio keyframes:(NSArray *)keyframes
        formats:(NSSet *)formats done:(void (^)(BOOL, BOOL, NSString *))done {
    SFBackground(^{
        BOOL asIs = NO;
        NSString *why = nil;
        SFSegmentPlan *plan = [SFWebTranscode planVideo:video audio:audio formats:formats keyframes:keyframes asIs:&asIs error:&why];
        SFMain(^{
            if (!plan) { done(NO, asIs, why); return; }
            NSString *refused = nil;
            SFWebTranscode *t = [SFWebTranscode sessionWithPlan:plan stream:s.identifier device:s.device error:&refused];
            if (!t) { done(NO, NO, refused); return; }
            [t prepareAt:[self startOf:s] done:^(NSString *failure) {
                if (!failure) {
                    s.kind = SFWebStreamSegmented;
                    s.transcode = t;
                    done(YES, NO, nil);
                    return;
                }
                [t close];
                // the encoder broke on its first frames (it is struck off): the next one, if there is one
                if (plan.videoMode == SFSegmentModeEncode && ![[SFSegmentVideo availableEncoders] containsObject:plan.encoder]
                    && [SFSegmentVideo encodersForWidth:plan.width height:plan.height].count) {
                    [self segment:s video:video audio:audio keyframes:keyframes formats:formats done:done];
                    return;
                }
                done(NO, NO, failure);
            }];
        });
    });
}
@end
