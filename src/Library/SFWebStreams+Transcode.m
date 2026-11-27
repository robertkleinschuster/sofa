// SFWebStreams - a stream through the segmenter (SFWebTranscode, docs/pwa.md §8): what the browser can't
// play as it is - a stored YouTube video's VP9/AV1 + Opus, two separate tracks, a local MKV - is cut into
// HLS segments, every track copied where the browser decodes it, else encoded. Encoders in order: the
// GPU's (VideoToolbox), x264; when neither works the caller falls back (YouTube: the online H.264 session).
// A source re-encoded for fewer bytes (`reencode`) falls back to playing as it is.
#import "SFWebStreams+Private.h"
#import "SFSegmentTrack.h"
#import "SFLoopbackClient.h"
#import "SFHLSPlaylist.h"

static const NSTimeInterval kMasterTimeout = 60;   // the media proxy fetches the playlist from the source

@implementation SFWebStreams (Transcode)

- (void)reencodeHLS:(SFWebStream *)s formats:(NSSet *)formats done:(void (^)(BOOL))done {
    SFBackground(^{
        // the variant up to the re-encode's height (ORF: 720p instead of 1080p - 2.65x instead of 2.06x real
        // time here, a third fewer bytes from the source, measured 2026-11-27); the media proxy reduces its
        // master to it (a stored item has only its downloaded variant)
        int maxHeight = [SFWebTranscode maxHeightFor:@"av01"];
        NSURLComponents *c = [NSURLComponents componentsWithURL:s.upstream resolvingAgainstBaseURL:NO];
        NSString *q = [NSString stringWithFormat:@"height=%d", maxHeight];
        c.percentEncodedQuery = c.percentEncodedQuery.length ? [c.percentEncodedQuery stringByAppendingFormat:@"&%@", q] : q;
        SFLoopbackResponse *r = [SFLoopbackClient get:c.URL ?: s.upstream range:nil timeout:kMasterTimeout];
        NSString *text = r.status == 200 && r.body ? [[NSString alloc] initWithData:r.body encoding:NSUTF8StringEncoding] : nil;
        long long bandwidth = 0;
        // a master: its variant + audio rendition; a media playlist: itself (audio inside)
        NSArray *tracks = ![text hasPrefix:@"#EXTM3U"] ? nil
                        : [text rangeOfString:@"#EXT-X-STREAM-INF"].location != NSNotFound ? SFHLSChooseVariant(text, s.upstream.absoluteString, maxHeight, &bandwidth)
                        : @[s.upstream.absoluteString];
        SFMain(^{
            if (!tracks.count) { SFLog(@"web: %@ as HLS (its playlist answered %ld)", s.item.identifier, (long)r.status); done(NO); return; }
            [self segment:s video:tracks[0] audio:tracks.count > 1 ? tracks[1] : nil keyframes:nil formats:formats reencode:@"av01"
                     done:^(BOOL segmented, BOOL asIs, NSString *why) {
                if (!segmented && !asIs) SFLog(@"web: %@ as HLS (%@)", s.item.identifier, why);
                done(segmented);
            }];
        });
    });
}

- (void)segment:(SFWebStream *)s video:(NSString *)video audio:(NSString *)audio keyframes:(NSArray *)keyframes
        formats:(NSSet *)formats reencode:(NSString *)reencode done:(void (^)(BOOL, BOOL, NSString *))done {
    SFBackground(^{
        BOOL asIs = NO;
        NSString *why = nil;
        SFSegmentPlan *plan = [SFWebTranscode planVideo:video audio:audio formats:formats keyframes:keyframes reencode:reencode asIs:&asIs error:&why];
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
                // the encoder broke on its first frames (it is struck off): planned again - the next
                // encoder of its codec, or (re-encoded for fewer bytes) the source as it is
                NSString *codec = [plan.encoder isEqualToString:@"libsvtav1"] ? @"av01" : @"avc1";
                if (plan.videoMode == SFSegmentModeEncode && ![[SFSegmentVideo encodersFor:codec] containsObject:plan.encoder]) {
                    [self segment:s video:video audio:audio keyframes:keyframes formats:formats reencode:reencode done:done];
                    return;
                }
                done(NO, NO, failure);
            }];
        });
    });
}
@end
