#import "SFAVEngine.h"
#import "SFCurl.h"
#import "SFModel.h"
#import <AVFoundation/AVFoundation.h>

static void *kStatusCtx = &kStatusCtx;
static void *kKeepUpCtx = &kKeepUpCtx;
static void *kRateCtx = &kRateCtx;

// Dev mode: AVPlayerLayer renders black in renderInContext:, so dev screenshots and the dev stream
// get the picture from an AVPlayerItemVideoOutput attached to the item (dev only - production
// playback never carries the extra output). SFRenderLayerTree asks the layer via devCopyFrameOfSize:.
@interface SFAVPlayerLayer : AVPlayerLayer
@property (nonatomic, strong) AVPlayerItemVideoOutput *devOutput;
@end

@implementation SFAVPlayerLayer {
    CGImageRef _lastFrame;   // copyPixelBuffer only hands out NEW frames; paused video keeps the last one
}
- (void)setDevOutput:(AVPlayerItemVideoOutput *)o {
    _devOutput = o;
    if (_lastFrame) { CGImageRelease(_lastFrame); _lastFrame = NULL; }
}
static CGImageRef imageFromPixelBuffer(CVPixelBufferRef pb) {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 8,
                                           CVPixelBufferGetBytesPerRow(pb), cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef img = c ? CGBitmapContextCreateImage(c) : NULL;   // copies the pixels
    if (c) CGContextRelease(c);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return img;
}
- (CGImageRef)devCopyFrameOfSize:(CGSize)size {
    if (!SFDevMode || !_devOutput || size.width < 2 || size.height < 2) return NULL;
    CMTime t = [_devOutput itemTimeForHostTime:CACurrentMediaTime()];
    if ([_devOutput hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_devOutput copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            CGImageRef img = imageFromPixelBuffer(pb);
            CVPixelBufferRelease(pb);
            if (img) { if (_lastFrame) CGImageRelease(_lastFrame); _lastFrame = img; }
        }
    }
    if (!_lastFrame) return NULL;
    // aspect fit on black like videoGravity ResizeAspect
    size_t w = (size_t)size.width, h = (size_t)size.height;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!c) return NULL;
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(0, 0, w, h));
    double iw = CGImageGetWidth(_lastFrame), ih = CGImageGetHeight(_lastFrame), k = MIN(w / iw, h / ih);
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake((w - iw * k) / 2, (h - ih * k) / 2, iw * k, ih * k), _lastFrame);
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return out;
}
@end

// 10.9 bug: releasing an AVPlayerLayer (AVSubtitleLayer dealloc) can crash ->
// one single, never released layer for all playbacks.
static SFAVPlayerLayer *sharedLayer(void) {
    static SFAVPlayerLayer *shared;
    if (!shared) {
        shared = [SFAVPlayerLayer layer];
        shared.videoGravity = AVLayerVideoGravityResizeAspect;
        shared.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    }
    return shared;
}

@implementation SFAVEngine {
    AVPlayer *_player;
    AVPlayerItem *_pitem;
    id _timeObserver, _endObs, _failObs;
    BOOL _startPaused;
    BOOL _hls;
}
@synthesize delegate = _delegate;

- (NSString *)engineName { return @"AVFoundation"; }
- (CALayer *)videoLayer { return sharedLayer(); }

- (void)openURL:(NSURL *)url audioURL:(NSURL *)audioURL start:(NSTimeInterval)start exact:(BOOL)exact paused:(BOOL)paused {
    [self close];
    _hls = [url.path.pathExtension.lowercaseString hasPrefix:@"m3u"];   // before the proxy rewrites the URL
    url = [[SFStreamProxy shared] playableURLFor:url];   // TLS bridge for ORF & co.
    _startPaused = paused;
    _pitem = [AVPlayerItem playerItemWithAsset:[AVURLAsset URLAssetWithURL:url options:nil]];
    [_pitem addObserver:self forKeyPath:@"status" options:0 context:kStatusCtx];
    [_pitem addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:0 context:kKeepUpCtx];
    __weak SFAVEngine *ws = self;
    // end notifications can arrive off-main -> main queue
    _endObs = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:_pitem
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [ws.delegate engineDidEnd]; }];
    _failObs = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:_pitem
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { SFLog(@"av: failed to end %@", n.userInfo); [ws.delegate engineInterrupted]; }];
    _player = [AVPlayer playerWithPlayerItem:_pitem];
    _player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    _player.muted = _muted;
    [_player addObserver:self forKeyPath:@"rate" options:0 context:kRateCtx];
    SFNoAnimate(^{ sharedLayer().player = self->_player; });
    if (start > 0) {
        if (exact) [_player seekToTime:CMTimeMakeWithSeconds(start, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
        else [_player seekToTime:CMTimeMakeWithSeconds(start, 600)];
    }
    if (!paused) [_player play];
    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(1, 2) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        [ws.delegate engineTick];
    }];
}

// Dev only: the frame source for SFAVPlayerLayer, for files and progressive streams. HLS never
// delivers pixel buffers to an AVPlayerItemVideoOutput on 10.9 (tested: before/after ready, with and
// without the layer, IOSurface buffers) - so HLS items get no output and stay exactly like production.
- (void)attachDevOutput {
    if (!SFDevMode || !_pitem || _pitem.outputs.count || sharedLayer().player != _player) return;
    if (_hls) return;
    AVPlayerItemVideoOutput *o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) }];
    [_pitem addOutput:o];
    sharedLayer().devOutput = o;
}

- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj change:(NSDictionary *)ch context:(void *)ctx {
    if (ctx == kStatusCtx) {
        SFMain(^{
            if (self->_pitem.status == AVPlayerItemStatusReadyToPlay && self->_startPaused) { [self->_player pause]; self->_startPaused = NO; }
            if (self->_pitem.status == AVPlayerItemStatusReadyToPlay) [self attachDevOutput];
            [self.delegate engineStatusChanged];
        });
    } else if (ctx == kKeepUpCtx) {
        SFMain(^{ [self.delegate engineBufferingChanged]; });
    } else if (ctx == kRateCtx) {
        SFMain(^{ [self.delegate engineRateChanged]; });
    } else {
        [super observeValueForKeyPath:kp ofObject:obj change:ch context:ctx];
    }
}

- (SFEngineStatus)status {
    if (!_pitem) return SFEngineLoading;
    switch (_pitem.status) {
        case AVPlayerItemStatusReadyToPlay: return SFEngineReady;
        case AVPlayerItemStatusFailed: return SFEngineFailed;
        default: return SFEngineLoading;
    }
}
- (NSError *)error { return _pitem.error; }
- (BOOL)playing { return _player && _player.rate > 0; }
- (BOOL)likelyToKeepUp { return _pitem.playbackLikelyToKeepUp || _pitem.playbackBufferFull; }
- (NSTimeInterval)currentTime { double c = _player ? CMTimeGetSeconds(_player.currentTime) : 0; return isnan(c) ? 0 : c; }
- (NSTimeInterval)duration {
    double d = _pitem ? CMTimeGetSeconds(_pitem.duration) : 0;
    return (d > 0 && !isnan(d) && !isinf(d)) ? d : 0;
}
- (NSTimeInterval)bufferedUntil {
    double c = self.currentTime, buf = 0;
    for (NSValue *v in _pitem.loadedTimeRanges) {
        CMTimeRange r = v.CMTimeRangeValue;
        if (CMTimeGetSeconds(r.start) <= c + 1) buf = MAX(buf, CMTimeGetSeconds(CMTimeRangeGetEnd(r)));
    }
    return buf;
}
- (CGSize)videoSize { return _pitem ? _pitem.presentationSize : CGSizeZero; }
- (void)setMuted:(BOOL)m { _muted = m; _player.muted = m; }
@synthesize muted = _muted;

- (void)play { _startPaused = NO; [_player play]; }
- (void)pause {
    if (_pitem.status != AVPlayerItemStatusReadyToPlay) _startPaused = YES;   // remember a pause during loading
    [_player pause];
}
- (void)seekTo:(NSTimeInterval)t exact:(BOOL)exact {
    if (exact) [_player seekToTime:CMTimeMakeWithSeconds(MAX(0, t), 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    else [_player seekToTime:CMTimeMakeWithSeconds(MAX(0, t), 600)];
}

- (void)close {
    if (_timeObserver) { [_player removeTimeObserver:_timeObserver]; _timeObserver = nil; }
    if (_pitem) {
        [_pitem removeObserver:self forKeyPath:@"status" context:kStatusCtx];
        [_pitem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:kKeepUpCtx];
        if (_endObs) [[NSNotificationCenter defaultCenter] removeObserver:_endObs];
        if (_failObs) [[NSNotificationCenter defaultCenter] removeObserver:_failObs];
        _endObs = _failObs = nil;
        _pitem = nil;
    }
    // Order: detach the layer from the player, THEN release the player.
    if (_player) [_player pause];
    SFNoAnimate(^{ if (sharedLayer().player == self->_player) { sharedLayer().player = nil; sharedLayer().devOutput = nil; } });
    if (_player) {
        [_player removeObserver:self forKeyPath:@"rate" context:kRateCtx];
        [_player replaceCurrentItemWithPlayerItem:nil];
        _player = nil;
    }
}

- (void)shutdown { [self close]; }
- (void)dealloc { [self close]; }
@end
