// SFYTEngine (Fill) - a download is the media store filled (docs/media-store.md): the video's
// tracks (video, main audio) range by range through the same reads a player makes - what the store
// holds already (a watched part) is skipped, the rest comes from the engine session and goes to disk
// on the way - then its subtitles. Paced at 3x the playback rate (as ffmpeg's -readrate 3 was for the
// MP4 downloads before): background loading never crowds out the TV's own streaming, and SABR is
// asked at a player's pace.
#import "SFModel.h"
#import "SFYTEngine+Private.h"
#import "SFJSON.h"
#import "SFDownloads.h"
#import "SFMediaStore.h"

static const NSUInteger kFillPiece = 1 << 20;
static const double kPaceFactor = 3;                  // x the playback byte rate
static const double kMinRate = 256 * 1024;            // bytes/s when the duration is unknown

@interface SFYTFill : NSObject
@property (nonatomic, copy) NSString *vid, *sid;
@property (nonatomic, copy) NSArray *keys, *subs;     // local track keys; subtitle keys
@property (nonatomic) long long all, present, fetched;
@property (nonatomic) double rate;
@property (nonatomic, strong) NSDate *t0;
@property (nonatomic, copy) NSDictionary *answer;
@property (atomic) BOOL cancelled;
@property (nonatomic, copy) void (^progress)(double);
@property (nonatomic, copy) void (^done)(NSDictionary *, NSError *);
@end
@implementation SFYTFill
@end

static SFMediaStore *Store(void) { return [SFDownloads shared].mediaStore; }
static NSString *LastPart(NSString *url) {
    NSString *p = [[url componentsSeparatedByString:@"/"] lastObject];
    return p.length ? [p stringByRemovingPercentEncoding] : nil;
}

@implementation SFYTEngine (Fill)

- (dispatch_block_t)fill:(NSString *)vid progress:(void (^)(double))progress done:(void (^)(NSDictionary *, NSError *))done {
    SFYTFill *f = [SFYTFill new];
    f.vid = vid; f.progress = progress; f.done = done;
    // the same choice as playback; the session lives while the fill reads
    [self open:vid background:YES stored:YES done:^(NSDictionary *r, NSError *e) {
        if (f.cancelled) return;
        if (!r) { done(nil, e); return; }
        if ([r[@"stored"] boolValue]) { progress(1); done(r, nil); return; }   // complete already
        if (r[@"hls"]) { done(nil, SFError(@"Livestreams lassen sich nicht herunterladen.")); return; }
        NSString *akey = LastPart(str(r[@"audio"]));
        NSDictionary *tracks = dict(r[@"tracks"]);
        if (!akey || !dict(tracks[@"video"]) || !dict(tracks[akey])) { done(nil, SFError(@"engine: no track identities")); return; }
        f.sid = str(r[@"sid"]); f.answer = r;
        f.keys = @[@"video", akey];
        NSMutableArray *subs = [NSMutableArray new];
        for (NSDictionary *s in [r[@"subs"] isKindOfClass:[NSArray class]] ? r[@"subs"] : @[]) {
            NSString *file = LastPart(str(s[@"url"]));
            if ([file hasSuffix:@".vtt"]) [subs addObject:[file substringToIndex:file.length - 4]];
        }
        f.subs = subs;
        for (NSString *k in f.keys) {
            NSDictionary *t = dict(tracks[k]);
            f.all += [num(t[@"total"]) longLongValue];
            f.present += [Store() extentsOf:str(t[@"id"]) ?: @""].bytes;
        }
        double dur = [r[@"duration"] doubleValue];
        f.rate = dur > 0 ? MAX(kMinRate, kPaceFactor * f.all / dur) : kMinRate;
        f.t0 = [NSDate date];
        SFLog(@"yt-engine: filling %@ - %.0f of %.0f MB on disk already", vid, f.present / 1048576.0, f.all / 1048576.0);
        dispatch_async(self.queue, ^{ [self fillStep:f]; });
    }];
    return ^{ f.cancelled = YES; };
}

// on the engine queue: the next missing piece of a track, or the subtitles, or the end
- (void)fillStep:(SFYTFill *)f {
    if (f.cancelled) { [self fillEnd:f error:nil]; return; }
    for (NSString *k in f.keys) {
        NSDictionary *t = [self trackInfo:k session:f.sid];
        NSString *tid = str(t[@"id"]);
        long long total = [num(t[@"total"]) longLongValue];
        NSArray *gap = [[Store() extentsOf:tid ?: @""] missingFrom:0 to:total].firstObject;
        if (!gap) continue;
        long long at = [gap[0] longLongValue], n = MIN((long long)kFillPiece, [gap[1] longLongValue] - at);
        [self read:f.sid track:k at:at max:(NSUInteger)n done:^(NSData *bytes, long long tot, NSString *mime, NSError *e) {
            if (e || !bytes.length) { [self fillEnd:f error:e ?: SFError(@"engine: empty read")]; return; }
            f.fetched += (long long)bytes.length;
            double p = MIN(0.99, (double)(f.present + f.fetched) / MAX(1, f.all));
            SFMain(^{ if (!f.cancelled) f.progress(p); });
            // the pace: fetched bytes at most `rate` per second since the start
            double wait = f.fetched / f.rate + [f.t0 timeIntervalSinceNow];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, wait) * NSEC_PER_SEC)), self.queue, ^{ [self fillStep:f]; });
        }];
        return;
    }
    [self fillSubs:f index:0];
}

- (void)fillSubs:(SFYTFill *)f index:(NSUInteger)i {
    if (f.cancelled) { [self fillEnd:f error:nil]; return; }
    if (i >= f.subs.count) { [self fillEnd:f error:nil]; return; }
    // a subtitle that fails is not worth failing the download: it is offered when it is there
    [self subtitles:f.subs[i] session:f.sid done:^(NSString *vtt, NSError *e) {
        dispatch_async(self.queue, ^{ [self fillSubs:f index:i + 1]; });
    }];
}

- (void)fillEnd:(SFYTFill *)f error:(NSError *)e {
    [Store() sync];   // the last piece on disk before completeness is judged
    BOOL complete = !e && !f.cancelled && [Store() itemIsComplete:[@"yt:" stringByAppendingString:f.vid]];
    SFMain(^{
        [self closeSession:f.sid];
        if (f.cancelled) return;
        if (complete) SFLog(@"yt-engine: filled %@ (%.0f MB fetched in %.0f s)", f.vid, f.fetched / 1048576.0, -[f.t0 timeIntervalSinceNow]);
        if (complete) { f.progress(1); f.done(f.answer, nil); }
        else f.done(nil, e ?: SFError(@"Unvollständig geladen – wird erneut versucht"));
    });
}
@end
