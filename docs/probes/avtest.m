// AVFoundation 10.9 playability probe: single URL (progressive/HLS) or DASH composition (video+audio)
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
static void spin(double s){ [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]]; }
static double now(void){ return [NSDate timeIntervalSinceReferenceDate]; }
static BOOL loadAsset(AVURLAsset *a, NSString *label){
    __block BOOL done=NO; double t0=now();
    [a loadValuesAsynchronouslyForKeys:@[@"tracks",@"duration",@"playable"] completionHandler:^{ done=YES; }];
    while(!done && now()-t0<30) spin(0.1);
    NSError *e=nil; AVKeyValueStatus st=[a statusOfValueForKey:@"tracks" error:&e];
    printf("[%s] load %.2fs tracksStatus=%ld playable=%d duration=%.1f ntracks=%lu err=%s\n",[label UTF8String],now()-t0,(long)st,a.playable,CMTimeGetSeconds(a.duration),(unsigned long)a.tracks.count,e?[[e description] UTF8String]:"-");
    for(AVAssetTrack *t in a.tracks){ printf("   track %s size=%.0fx%.0f\n",[t.mediaType UTF8String],t.naturalSize.width,t.naturalSize.height); }
    return st==AVKeyValueStatusLoaded;
}
static void playItem(AVPlayerItem *item, NSString *label){
    AVPlayerItemVideoOutput *vo=[[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}]; [item addOutput:vo]; __block int frames=0; size_t lastW=0;
    AVPlayer *p=[AVPlayer playerWithPlayerItem:item]; p.muted=YES; double t0=now();
    while(item.status==AVPlayerItemStatusUnknown && now()-t0<30) spin(0.1);
    printf("[%s] item status=%ld after %.2fs err=%s\n",[label UTF8String],(long)item.status,now()-t0,item.error?[[item.error description] UTF8String]:"-");
    if(item.status!=AVPlayerItemStatusReadyToPlay){ for(AVPlayerItemErrorLogEvent *x in item.errorLog.events) printf("   FAILLOG: domain=%s code=%ld comment=%s uri=%.80s\n",[x.errorDomain UTF8String],(long)x.errorStatusCode,[x.errorComment UTF8String],[x.URI UTF8String]); for(AVPlayerItemAccessLogEvent *x in item.accessLog.events) printf("   FAILACC: uri=%.80s server=%s\n",[x.URI UTF8String],[x.serverAddress UTF8String]); return; }
    [p play]; double t1=now();
    while(now()-t1<8){ double te=now(); while(now()-te<1.0){ spin(0.02); CMTime it=[vo itemTimeForHostTime:CACurrentMediaTime()]; if([vo hasNewPixelBufferForItemTime:it]){ CVPixelBufferRef pb=[vo copyPixelBufferForItemTime:it itemTimeForDisplay:NULL]; if(pb){ frames++; lastW=CVPixelBufferGetWidth(pb); CVPixelBufferRelease(pb);} } }
        printf("   frames so far=%d lastW=%zu\n",frames,lastW);
        CMTimeRange r = item.loadedTimeRanges.count? [item.loadedTimeRanges[0] CMTimeRangeValue] : kCMTimeRangeZero;
        printf("   t=%.1fs cur=%.2f rate=%.1f size=%.0fx%.0f buffered=%.1f likelyKeepUp=%d\n",now()-t1,CMTimeGetSeconds(p.currentTime),p.rate,item.presentationSize.width,item.presentationSize.height,CMTimeGetSeconds(r.duration),item.playbackLikelyToKeepUp);
    }
    AVPlayerItemAccessLog *al=item.accessLog; AVPlayerItemAccessLogEvent *ev=al.events.lastObject;
    if(ev) printf("   accesslog: indicatedBitrate=%.0f observedBitrate=%.0f uri=%.60s\n",ev.indicatedBitrate,ev.observedBitrate,[ev.URI UTF8String]);
    AVPlayerItemErrorLog *el=item.errorLog; for(AVPlayerItemErrorLogEvent *x in el.events) printf("   errorlog: %ld %s\n",(long)x.errorStatusCode,[x.errorComment UTF8String]);
    // seek test
    __block BOOL sd=NO; double t2=now();
    [p seekToTime:CMTimeMakeWithSeconds(120,600) completionHandler:^(BOOL f){ sd=YES; }];
    while(!sd && now()-t2<20) spin(0.1);
    spin(2.0); printf("   seek->120: done=%d %.2fs cur=%.2f rate=%.1f\n",sd,now()-t2,CMTimeGetSeconds(p.currentTime),p.rate);
}
int main(int argc,const char**argv){ @autoreleasepool{
    NSString *mode=[NSString stringWithUTF8String:argv[1]];
    NSDictionary *opts= getenv("NOOPT") ? @{} : @{@"AVURLAssetHTTPHeaderFieldsKey":@{@"User-Agent":@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_9_5)"}};
    if([mode isEqualToString:@"single"]){
        NSURL *u=[NSURL URLWithString:[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[2]] encoding:NSUTF8StringEncoding error:nil]];
        AVURLAsset *a=[AVURLAsset URLAssetWithURL:u options:opts];
        loadAsset(a,@"asset");
        playItem([AVPlayerItem playerItemWithAsset:a],@"single");
    } else {
        NSURL *vu=[NSURL URLWithString:[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[2]] encoding:NSUTF8StringEncoding error:nil]];
        NSURL *au=[NSURL URLWithString:[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[3]] encoding:NSUTF8StringEncoding error:nil]];
        AVURLAsset *va=[AVURLAsset URLAssetWithURL:vu options:opts], *aa=[AVURLAsset URLAssetWithURL:au options:opts];
        if(!loadAsset(va,@"video")||!loadAsset(aa,@"audio")) return 1;
        AVMutableComposition *c=[AVMutableComposition composition]; NSError *e=nil;
        AVAssetTrack *vt=[va tracksWithMediaType:AVMediaTypeVideo].firstObject, *at=[aa tracksWithMediaType:AVMediaTypeAudio].firstObject;
        CMTime dur=CMTimeMinimum(va.duration,aa.duration); double t0=now();
        AVMutableCompositionTrack *cv=[c addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        BOOL ok1=[cv insertTimeRange:CMTimeRangeMake(kCMTimeZero,dur) ofTrack:vt atTime:kCMTimeZero error:&e];
        AVMutableCompositionTrack *ca=[c addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        BOOL ok2=[ca insertTimeRange:CMTimeRangeMake(kCMTimeZero,dur) ofTrack:at atTime:kCMTimeZero error:&e];
        { AVAssetImageGenerator *g=[AVAssetImageGenerator assetImageGeneratorWithAsset:c]; g.requestedTimeToleranceBefore=kCMTimeZero; g.requestedTimeToleranceAfter=CMTimeMakeWithSeconds(2,600); NSError *ge=nil; CMTime act; double tg=now(); CGImageRef im=[g copyCGImageAtTime:CMTimeMakeWithSeconds(60,600) actualTime:&act error:&ge]; printf("[comp] imagegen@60s %s %zux%zu in %.2fs err=%s\n", im?"OK":"FAIL", im?CGImageGetWidth(im):0, im?CGImageGetHeight(im):0, now()-tg, ge?[[ge description] UTF8String]:"-"); if(im) CGImageRelease(im);}
        printf("[comp] insert v=%d a=%d %.2fs err=%s playable=%d\n",ok1,ok2,now()-t0,e?[[e description] UTF8String]:"-",c.playable);
        playItem([AVPlayerItem playerItemWithAsset:c],@"comp");
    }
}
return 0; }
