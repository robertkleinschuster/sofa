#import "SFAVEngine.h"
#import "SFCurl.h"
#import "SFModel.h"
#import <AVFoundation/AVFoundation.h>

static void *kStatusCtx = &kStatusCtx;
static void *kKeepUpCtx = &kKeepUpCtx;
static void *kRateCtx = &kRateCtx;

// 10.9-Bug: Freigabe einer AVPlayerLayer (AVSubtitleLayer dealloc) kann crashen ->
// eine einzige, nie freigegebene Ebene für alle Wiedergaben.
static AVPlayerLayer *sharedLayer(void) {
    static AVPlayerLayer *shared;
    if (!shared) {
        shared = [AVPlayerLayer layer];
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
}
@synthesize delegate = _delegate;

- (NSString *)engineName { return @"AVFoundation"; }
- (CALayer *)videoLayer { return sharedLayer(); }

- (void)openURL:(NSURL *)url audioURL:(NSURL *)audioURL start:(NSTimeInterval)start exact:(BOOL)exact paused:(BOOL)paused {
    [self close];
    url = [[SFStreamProxy shared] playableURLFor:url];   // TLS-Brücke für ORF & Co.
    _startPaused = paused;
    _pitem = [AVPlayerItem playerItemWithAsset:[AVURLAsset URLAssetWithURL:url options:nil]];
    [_pitem addObserver:self forKeyPath:@"status" options:0 context:kStatusCtx];
    [_pitem addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:0 context:kKeepUpCtx];
    __weak SFAVEngine *ws = self;
    // Ende-Notifications können off-main kommen -> Main-Queue
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

- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj change:(NSDictionary *)ch context:(void *)ctx {
    if (ctx == kStatusCtx) {
        SFMain(^{
            if (self->_pitem.status == AVPlayerItemStatusReadyToPlay && self->_startPaused) { [self->_player pause]; self->_startPaused = NO; }
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
- (void)setMuted:(BOOL)m { _muted = m; _player.muted = m; }
@synthesize muted = _muted;

- (void)play { _startPaused = NO; [_player play]; }
- (void)pause {
    if (_pitem.status != AVPlayerItemStatusReadyToPlay) _startPaused = YES;   // Pause während des Ladens merken
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
    // Reihenfolge: Ebene vom Player lösen, DANN Player freigeben.
    if (_player) [_player pause];
    SFNoAnimate(^{ if (sharedLayer().player == self->_player) sharedLayer().player = nil; });
    if (_player) {
        [_player removeObserver:self forKeyPath:@"rate" context:kRateCtx];
        [_player replaceCurrentItemWithPlayerItem:nil];
        _player = nil;
    }
}

- (void)shutdown { [self close]; }
- (void)dealloc { [self close]; }
@end
