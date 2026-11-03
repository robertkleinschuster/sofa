#import "SFPlayerScreen.h"
#import "SFLayers.h"
#import "SFStore.h"
#import <AVFoundation/AVFoundation.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "SFLibrary.h"
#import "SFCurl.h"
#import "SFPower.h"

static void *kStatusCtx = &kStatusCtx;
static void *kKeepUpCtx = &kKeepUpCtx;
static void *kRateCtx = &kRateCtx;
NSString *const SFPlayerStateNotification = @"SFPlayerStateNotification";

@implementation SFPlayerScreen {
    SFItem *_item;
    NSArray *_queue;
    id _powerObs;
    BOOL _explicitQueue;   // Handy-Playlist: nächster = nächster Queue-Eintrag
    NSUInteger _index;
    AVPlayer *_player;
    AVPlayerItem *_pitem;
    AVPlayerLayer *_playerLayer;
    id _timeObserver;
    IOPMAssertionID _assertion, _sysAssertion;
    BOOL _hasAssertion;

    CALayer *_osd;               // gesamte Einblendung
    CAGradientLayer *_topShade, *_bottomShade;
    SFLabel *_title, *_channel;
    CALayer *_barBg, *_barFill, *_barBuffer, *_barKnob;
    SFLabel *_elapsed, *_remaining, *_endsAt;
    CALayer *_pauseIcon;
    CALayer *_spinner;
    SFLabel *_message;
    CALayer *_nextCard;
    SFLabel *_nextLabel;

    NSTimer *_osdTimer;
    BOOL _osdVisible;
    NSTimeInterval _pendingSeek;    // kumulierter Sprung (s), 0 = keiner
    NSTimer *_seekTimer;
    NSTimeInterval _lastSaved;
    BOOL _ended, _failed, _closing;
    NSURL *_openURL; NSDate *_openAt; NSInteger _openTries; NSTimeInterval _openResume;   // Retry bei sporadischem HLS-Öffnungsfehler
    NSTimer *_nextTimer;
    NSInteger _nextCountdown;
    id _endObs, _failObs;
}

- (instancetype)initWithItem:(SFItem *)item queue:(NSArray *)queue index:(NSUInteger)index {
    if ((self = [super initWithTheme:[SFTheme themeNamed:item.source ?: @"home"]])) {
        _item = item;
        _queue = queue;
        _index = index;
    }
    return self;
}

- (void)dealloc { [self teardown]; }

#pragma mark Layout

- (void)layoutForSize:(CGSize)size {
    CALayer *L = self.layer;
    SFTheme *t = self.theme;
    SFNoAnimate(^{
        L.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        if (!self->_playerLayer) {
            // 10.9-Bug: Freigabe einer AVPlayerLayer (AVSubtitleLayer dealloc) kann
            // crashen -> eine einzige, nie freigegebene Ebene für alle Player-Screens.
            static AVPlayerLayer *shared;
            if (!shared) {
                shared = [AVPlayerLayer layer];
                shared.videoGravity = AVLayerVideoGravityResizeAspect;
                shared.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
            }
            [shared removeFromSuperlayer];
            shared.player = nil;
            self->_playerLayer = shared;
            [L insertSublayer:shared atIndex:0];
        }
        self->_playerLayer.frame = L.bounds;

        [self->_osd removeFromSuperlayer];
        self->_osd = [CALayer layer];
        self->_osd.frame = L.bounds;
        self->_osd.opacity = 0;
        [L addSublayer:self->_osd];

        self->_topShade = [CAGradientLayer layer];
        self->_topShade.frame = CGRectMake(0, 0, size.width, U(300));
        self->_topShade.colors = @[(id)[NSColor colorWithDeviceWhite:0 alpha:0.8].CGColor, (id)[NSColor colorWithDeviceWhite:0 alpha:0].CGColor];
        [self->_osd addSublayer:self->_topShade];
        self->_bottomShade = [CAGradientLayer layer];
        self->_bottomShade.frame = CGRectMake(0, size.height - U(360), size.width, U(360));
        self->_bottomShade.colors = @[(id)[NSColor colorWithDeviceWhite:0 alpha:0].CGColor, (id)[NSColor colorWithDeviceWhite:0 alpha:0.85].CGColor];
        [self->_osd addSublayer:self->_bottomShade];

        CGFloat x = U(110), w = size.width - 2 * x;
        self->_channel = [SFLabel labelWithFont:[t medium:28] color:[NSColor colorWithDeviceWhite:1 alpha:0.75]];
        self->_channel.position = CGPointMake(x, U(70));
        [self->_osd addSublayer:self->_channel];
        self->_title = [SFLabel labelWithFont:[t bold:50] color:[NSColor whiteColor]];
        self->_title.maxLines = 2;
        [self->_osd addSublayer:self->_title];

        CGFloat by = size.height - U(150);
        self->_barBg = [CALayer layer];
        self->_barBg.frame = CGRectMake(x, by, w, U(8));
        self->_barBg.cornerRadius = U(4);
        self->_barBg.backgroundColor = [NSColor colorWithDeviceWhite:1 alpha:0.25].CGColor;
        self->_barBg.masksToBounds = YES;
        self->_barBuffer = [CALayer layer];
        self->_barBuffer.anchorPoint = CGPointZero;
        self->_barBuffer.backgroundColor = [NSColor colorWithDeviceWhite:1 alpha:0.25].CGColor;
        [self->_barBg addSublayer:self->_barBuffer];
        self->_barFill = [CALayer layer];
        self->_barFill.anchorPoint = CGPointZero;
        NSColor *acc = [t.identifier isEqualToString:@"home"] || [t.identifier isEqualToString:@"ard"] ? [NSColor whiteColor] : t.accent;
        self->_barFill.backgroundColor = acc.CGColor;
        [self->_barBg addSublayer:self->_barFill];
        [self->_osd addSublayer:self->_barBg];
        self->_barKnob = [CALayer layer];
        self->_barKnob.bounds = CGRectMake(0, 0, U(22), U(22));
        self->_barKnob.cornerRadius = U(11);
        self->_barKnob.backgroundColor = acc.CGColor;
        self->_barKnob.shadowOpacity = 0.5; self->_barKnob.shadowRadius = U(4);
        [self->_osd addSublayer:self->_barKnob];

        self->_elapsed = [SFLabel labelWithFont:[t medium:28] color:[NSColor whiteColor]];
        [self->_elapsed sizeToFitWidth:U(300)];
        self->_elapsed.position = CGPointMake(x, by + U(26));
        self->_remaining = [SFLabel labelWithFont:[t medium:28] color:[NSColor whiteColor]];
        self->_remaining.alignment = NSRightTextAlignment;
        [self->_remaining sizeToFitWidth:U(300)];
        self->_remaining.position = CGPointMake(x + w - U(300), by + U(26));
        self->_endsAt = [SFLabel labelWithFont:[t regular:26] color:[NSColor colorWithDeviceWhite:1 alpha:0.7]];
        self->_endsAt.alignment = NSCenterTextAlignment;
        [self->_endsAt sizeToFitWidth:U(500)];
        self->_endsAt.position = CGPointMake((size.width - U(500)) / 2, by + U(26));
        for (CALayer *l in @[self->_elapsed, self->_remaining, self->_endsAt]) [self->_osd addSublayer:l];

        // Pause-Symbol
        [self->_pauseIcon removeFromSuperlayer];
        [self->_message removeFromSuperlayer];
        self->_pauseIcon = [CALayer layer];
        self->_pauseIcon.bounds = CGRectMake(0, 0, U(140), U(140));
        self->_pauseIcon.cornerRadius = U(70);
        self->_pauseIcon.backgroundColor = [NSColor colorWithDeviceWhite:0 alpha:0.55].CGColor;
        self->_pauseIcon.position = CGPointMake(size.width / 2, size.height / 2);
        for (int i = 0; i < 2; i++) {
            CALayer *b = [CALayer layer];
            b.backgroundColor = CGColorGetConstantColor(kCGColorWhite);
            b.cornerRadius = U(4);
            b.frame = CGRectMake(U(46) + i * U(30), U(40), U(18), U(60));
            [self->_pauseIcon addSublayer:b];
        }
        self->_pauseIcon.opacity = 0;
        [L addSublayer:self->_pauseIcon];

        self->_message = [SFLabel labelWithFont:[t medium:34] color:[NSColor whiteColor]];
        self->_message.alignment = NSCenterTextAlignment;
        self->_message.maxLines = 4;
        [L addSublayer:self->_message];
    });
    [self updateTitles];
}

- (void)updateTitles {
    CGFloat w = self.size.width - U(220);
    SFNoAnimate(^{
        self->_channel.text = self->_item.channel ?: @"";
        [self->_channel sizeToFitWidth:w];
        self->_title.text = self->_item.title ?: @"";
        [self->_title sizeToFitWidth:w];
        self->_title.position = CGPointMake(U(110), U(70) + (self->_channel.text.length ? U(42) : 0));
    });
}

- (void)showMessage:(NSString *)msg {
    SFNoAnimate(^{
        self->_message.text = msg;
        CGFloat h = [self->_message sizeToFitWidth:U(1300)];
        self->_message.position = CGPointMake((self.size.width - U(1300)) / 2, (self.size.height - h) / 2);
    });
}

- (void)showSpinner:(BOOL)on {
    if (on && !_spinner) {
        _spinner = [CALayer layer];
        CAShapeLayer *arc = [CAShapeLayer layer];
        CGFloat r = U(40);
        arc.frame = CGRectMake(0, 0, 2 * r, 2 * r);
        CGPathRef ep = CGPathCreateWithEllipseInRect(CGRectInset(arc.bounds, U(4), U(4)), NULL);
        arc.path = ep;
        CGPathRelease(ep);
        arc.fillColor = nil;
        arc.strokeColor = CGColorGetConstantColor(kCGColorWhite);
        arc.lineWidth = U(6); arc.lineCap = kCALineCapRound; arc.strokeEnd = 0.7;
        _spinner.bounds = arc.frame;
        [_spinner addSublayer:arc];
        _spinner.position = CGPointMake(self.size.width / 2, self.size.height / 2);
        CABasicAnimation *rot = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rot.fromValue = @0; rot.toValue = @(2 * M_PI); rot.duration = 0.9; rot.repeatCount = HUGE_VALF;
        [_spinner addAnimation:rot forKey:@"spin"];
        SFNoAnimate(^{ [self.layer addSublayer:self->_spinner]; });
    } else if (!on && _spinner) {
        [_spinner removeFromSuperlayer]; _spinner = nil;
    }
}

#pragma mark Lifecycle

- (void)didAppear {
    if (!_player && !_closing) [self startItem];
}

- (void)willDisappear {
    [self saveProgress];
    [self teardown];
    [[NSNotificationCenter defaultCenter] postNotificationName:SFPlayerStateNotification object:self userInfo:@{@"closed": @YES}];
}

- (void)startItem {
    _ended = NO; _failed = NO;
    if (_queue.count && !_explicitQueue && self.remoteListID) _explicitQueue = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self postState]; });
    [self updateTitles];
    [self showMessage:@""];
    [self showSpinner:YES];
    [self showOSD:YES autoHide:YES];
    SFItem *it = _item;
    SFLog(@"player: resolve %@ (%@)", it.title, it.identifier);
    [it resolveURL:^(NSURL *url, NSError *err) {
        if (self->_closing || it != self->_item) return;
        if (!url) {
            [self showSpinner:NO];
            self->_failed = YES;
            [self showMessage:[NSString stringWithFormat:@"Wiedergabe nicht möglich\n%@", err.localizedDescription ?: @""]];
            SFLog(@"player: resolve failed %@", err);
            return;
        }
        self->_openTries = 0;
        [self playURL:url];
    }];
}

- (void)playURL:(NSURL *)url {
    [self teardownPlayer];
    _openURL = url; _openAt = [NSDate date]; _openTries++;
    url = [[SFStreamProxy shared] playableURLFor:url];   // TLS-Brücke für ORF & Co.
    SFLog(@"player: play %@", url.isFileURL ? url.path : url.host);
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    _pitem = [AVPlayerItem playerItemWithAsset:asset];
    [_pitem addObserver:self forKeyPath:@"status" options:0 context:kStatusCtx];
    [_pitem addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:0 context:kKeepUpCtx];
    // Ende-Notifications können off-main kommen -> auf die Main-Queue
    __weak SFPlayerScreen *wself = self;
    _endObs = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:_pitem
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [wself didEnd:n]; }];
    if (!_powerObs) _powerObs = [[NSNotificationCenter defaultCenter] addObserverForName:SFPowerWillTurnOffNotification object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [wself remotePause]; [wself saveProgress]; }];
    _failObs = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:_pitem
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [wself failedToEnd:n]; }];
    _player = [AVPlayer playerWithPlayerItem:_pitem];
    _player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    _player.muted = SFDevMode;   // Dev-Modus: niemanden stören
    [_player addObserver:self forKeyPath:@"rate" options:0 context:kRateCtx];
    SFNoAnimate(^{ self->_playerLayer.player = self->_player; });

    NSTimeInterval resume = self.startFromBeginning ? 0 : [[SFStore shared] positionFor:_item.identifier];
    BOOL exact = self.startPosition > 0;
    if (exact) resume = self.startPosition;
    self.startFromBeginning = NO;
    self.startPosition = 0;
    _openResume = (_item.kind == SFItemLive) ? 0 : (exact ? resume : (resume > 15 ? resume - 3 : 0));
    if (exact && _item.kind != SFItemLive) {
        [_player seekToTime:CMTimeMakeWithSeconds(resume, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    } else if (resume > 15 && _item.kind != SFItemLive) {
        [_player seekToTime:CMTimeMakeWithSeconds(resume - 3, 600)];
        [self.navigator toast:[NSString stringWithFormat:@"Fortgesetzt bei %@", SFFormatDuration(resume)]];
    }
    if (self.startPaused) { self.startPaused = NO; [self showOSD:YES autoHide:NO]; }
    else [_player play];
    __weak SFPlayerScreen *ws = self;
    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(1, 2) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        [ws tick];
    }];
    if (_player.rate > 0) [self setAssertion:YES];
}

- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj change:(NSDictionary *)ch context:(void *)ctx {
    if (ctx == kStatusCtx) {
        SFMain(^{
            if (self->_pitem.status == AVPlayerItemStatusFailed) {
                // googlevideo-HLS scheitert auf 10.9 sporadisch sofort (-12643/-12939), derselbe
                // URL klappt beim nächsten Versuch (docs/youtube.md §6) -> bis zu 3x neu öffnen.
                if (self->_openURL && !self->_openURL.isFileURL && self->_openTries < 3 && -[self->_openAt timeIntervalSinceNow] < 3) {
                    SFLog(@"player: open failed (%ld), retry %ld", (long)[self->_pitem.error code], (long)self->_openTries);
                    NSURL *u = self->_openURL; SFItem *it = self->_item;
                    NSTimeInterval pos = self->_openResume;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (self->_closing || it != self->_item) return;
                        if (pos > 0) self.startPosition = pos; else self.startFromBeginning = YES;
                        [self playURL:u];
                    });
                    return;
                }
                NSURL *alt = SFNextAlternateURL(self->_openURL);
                if (alt) {
                    SFLog(@"player: switching to alternate stream");
                    SFItem *it = self->_item; NSTimeInterval pos = self->_openResume;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (self->_closing || it != self->_item) return;
                        self->_openTries = 0;
                        if (pos > 0) self.startPosition = pos; else self.startFromBeginning = YES;
                        [self playURL:alt];
                    });
                    return;
                }
                [self showSpinner:NO];
                self->_failed = YES;
                SFLog(@"player: failed %@", self->_pitem.error);
                [self showMessage:[NSString stringWithFormat:@"Wiedergabe fehlgeschlagen\n%@", self->_pitem.error.localizedDescription ?: @""]];
            } else if (self->_pitem.status == AVPlayerItemStatusReadyToPlay) {
                if (self.startPaused) { [self->_player pause]; self.startPaused = NO; }   // Pause während des Ladens
                [self postState];
                if (self->_item.duration <= 0) {
                    double d = CMTimeGetSeconds(self->_pitem.duration);
                    if (d > 0 && !isnan(d) && !isinf(d)) self->_item.duration = d;
                }
            }
        });
    } else if (ctx == kKeepUpCtx) {
        SFMain(^{ [self showSpinner:!self->_pitem.playbackLikelyToKeepUp && self->_player.rate > 0 && !self->_failed]; [self postState]; });
    } else if (ctx == kRateCtx) {
        SFMain(^{ [self updatePauseState]; });
    } else {
        [super observeValueForKeyPath:kp ofObject:obj change:ch context:ctx];
    }
}

- (void)teardownPlayer {
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
    SFNoAnimate(^{ if (self->_playerLayer.player == self->_player) self->_playerLayer.player = nil; });
    if (_player) {
        [_player removeObserver:self forKeyPath:@"rate" context:kRateCtx];
        [_player replaceCurrentItemWithPlayerItem:nil];
        _player = nil;
    }
}

- (void)teardown {
    if (_powerObs) { [[NSNotificationCenter defaultCenter] removeObserver:_powerObs]; _powerObs = nil; }
    _closing = YES;
    [_osdTimer invalidate]; [_seekTimer invalidate]; [_nextTimer invalidate];
    [self teardownPlayer];
    [self setAssertion:NO];
}

- (void)setAssertion:(BOOL)on {
    if (on && !_hasAssertion && !SFDevMode) {
        // Wiedergabe: Display UND System wach (wie früher caffeinate -d -i)
        _hasAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep, kIOPMAssertionLevelOn,
                                                    CFSTR("Sofa Wiedergabe"), &_assertion) == kIOReturnSuccess;
        if (IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep, kIOPMAssertionLevelOn,
                                        CFSTR("Sofa Wiedergabe"), &_sysAssertion) != kIOReturnSuccess) _sysAssertion = 0;
    } else if (!on && _hasAssertion) {
        IOPMAssertionRelease(_assertion);
        if (_sysAssertion) { IOPMAssertionRelease(_sysAssertion); _sysAssertion = 0; }
        _hasAssertion = NO;
    }
}

#pragma mark Progress

- (NSTimeInterval)current { return _player ? CMTimeGetSeconds(_player.currentTime) : 0; }
- (SFItem *)item { return _item; }
- (NSTimeInterval)currentTime { double c = [self current]; return isnan(c) ? 0 : c; }
- (BOOL)isPaused { return _player && _player.rate == 0; }
- (NSTimeInterval)duration {
    double d = _pitem ? CMTimeGetSeconds(_pitem.duration) : 0;
    if (d > 0 && !isnan(d) && !isinf(d)) return d;
    return _item.duration;
}

- (void)saveProgress {
    if (!_player || _item.kind == SFItemLive || _failed) return;
    NSTimeInterval c = [self current], d = [self duration];
    if (_ended) c = d;
    if (c > 0 && d > 0) [[SFStore shared] savePosition:c duration:d forItem:_item];
}

- (void)tick {
    NSTimeInterval c = [self current];
    if (fabs(c - _lastSaved) > 15) { _lastSaved = c; [self saveProgress]; }
    if (_osdVisible) [self updateBar];
    if (_spinner && _pitem.playbackLikelyToKeepUp) [self showSpinner:NO];
}

- (void)updateBar {
    NSTimeInterval d = [self duration];
    BOOL live = _item.kind == SFItemLive || !(d > 0);
    NSTimeInterval c = [self current];
    NSTimeInterval shown = _pendingSeek != 0 ? MAX(0, MIN(d, c + _pendingSeek)) : c;
    CGFloat w = _barBg.bounds.size.width;
    double frac = live ? 1 : shown / d;
    double buf = 0;
    if (!live) {
        for (NSValue *v in _pitem.loadedTimeRanges) {
            CMTimeRange r = v.CMTimeRangeValue;
            double end = CMTimeGetSeconds(CMTimeRangeGetEnd(r));
            if (CMTimeGetSeconds(r.start) <= c + 1) buf = MAX(buf, end / d);
        }
    }
    SFNoAnimate(^{
        self->_barFill.frame = CGRectMake(0, 0, w * frac, U(8));
        self->_barBuffer.frame = CGRectMake(0, 0, w * MIN(1, buf), U(8));
        self->_barKnob.position = CGPointMake(self->_barBg.frame.origin.x + w * frac, CGRectGetMidY(self->_barBg.frame));
        self->_barKnob.hidden = live;
        if (live) {
            self->_elapsed.text = @"LIVE";
            self->_remaining.text = @"";
            self->_endsAt.text = @"";
        } else {
            self->_elapsed.text = SFFormatDuration(shown) ?: @"0:00";
            if (shown < 1) self->_elapsed.text = @"0:00";
            self->_remaining.text = [@"−" stringByAppendingString:SFFormatDuration(MAX(1, d - shown))];
            static NSDateFormatter *df;
            if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm"; }
            self->_endsAt.text = [NSString stringWithFormat:@"Endet um %@", [df stringFromDate:[NSDate dateWithTimeIntervalSinceNow:d - shown]]];
        }
    });
}

#pragma mark OSD

- (void)showOSD:(BOOL)on autoHide:(BOOL)autoHide {
    [_osdTimer invalidate]; _osdTimer = nil;
    if (on) [self updateBar];
    if (on != _osdVisible) {
        _osdVisible = on;
        SFAnimate(on ? 0.2 : 0.5, ^{ self->_osd.opacity = on ? 1 : 0; });
    }
    if (on && autoHide && _player.rate > 0)
        _osdTimer = [NSTimer scheduledTimerWithTimeInterval:4 target:self selector:@selector(autoHide) userInfo:nil repeats:NO];
}
- (void)autoHide { if (_player.rate > 0 && _pendingSeek == 0) [self showOSD:NO autoHide:NO]; }

- (void)postState {
    [[NSNotificationCenter defaultCenter] postNotificationName:SFPlayerStateNotification object:self];
}

- (SFPlaybackState)playbackState {
    if (_closing || !_item) return SFPlaybackIdle;
    if (_ended) return SFPlaybackEnded;
    if (_failed) return SFPlaybackIdle;
    if (!_player || _pitem.status != AVPlayerItemStatusReadyToPlay || _pendingSeek != 0) return SFPlaybackBuffering;
    if (_player.rate > 0) return _pitem.playbackLikelyToKeepUp || _pitem.playbackBufferFull ? SFPlaybackPlaying : SFPlaybackBuffering;
    return SFPlaybackPaused;
}

- (NSArray *)queue { return _queue; }
- (NSUInteger)queueIndex { return _index; }
- (BOOL)hasNext { return [self nextItem] != nil; }
- (BOOL)hasPrevious { return _explicitQueue && _index > 0; }
- (void)remotePlay { self.startPaused = NO; if (_player && _player.rate == 0) [self togglePause]; }
- (void)remotePause {
    // Pause während des Ladens/Retry: merken, damit der Player pausiert startet
    if (!_player || _pitem.status != AVPlayerItemStatusReadyToPlay) { self.startPaused = YES; [_player pause]; [self postState]; return; }
    if (_player.rate > 0) [self togglePause];
}
- (void)remoteSeekTo:(NSTimeInterval)t {
    if (!_player || _item.kind == SFItemLive) return;
    _pendingSeek = 0;
    [_player seekToTime:CMTimeMakeWithSeconds(MAX(0, t), 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL f) {
        SFMain(^{ [self postState]; });
    }];
    _ended = NO;
    [self showOSD:YES autoHide:YES];
    [self postState];
}
- (void)remoteNext { if ([self nextItem]) [self playNext]; }
- (void)remotePrevious { if ([self hasPrevious]) [self playQueueIndex:_index - 1 at:0]; }
- (void)playQueueIndex:(NSUInteger)i at:(NSTimeInterval)t {
    if (i >= _queue.count) return;
    [_nextTimer invalidate]; _nextTimer = nil; _nextCard.hidden = YES;
    [self saveProgress];
    [self teardownPlayer];
    _ended = NO;
    _index = i;
    _item = _queue[i];
    _lastSaved = 0;
    if (t > 0) self.startPosition = t;
    [self startItem];
}
- (void)replaceQueue:(NSArray *)items index:(NSUInteger)i at:(NSTimeInterval)t {
    _queue = [items copy];
    _explicitQueue = YES;
    [self playQueueIndex:i at:t];
}

- (void)updatePauseState {
    [self postState];
    BOOL paused = _player && _player.rate == 0 && !_ended && !_failed && _pitem.status == AVPlayerItemStatusReadyToPlay;
    SFAnimate(0.2, ^{ self->_pauseIcon.opacity = paused ? 1 : 0; });
    if (paused) { [self showOSD:YES autoHide:NO]; [self setAssertion:NO]; }
    else if (_player.rate > 0) {
        [self setAssertion:YES];
        if (_osdVisible && !_osdTimer && _pendingSeek == 0)
            _osdTimer = [NSTimer scheduledTimerWithTimeInterval:4 target:self selector:@selector(autoHide) userInfo:nil repeats:NO];
    }
}

- (void)togglePause {
    self.startPaused = NO;
    if (!_player) return;
    if (_player.rate > 0) { [_player pause]; [self saveProgress]; }
    else {
        if (_ended) { [_player seekToTime:kCMTimeZero]; _ended = NO; }
        [_player play];
        [self showOSD:YES autoHide:YES];
    }
}

#pragma mark Seek

- (void)seekBy:(NSTimeInterval)delta {
    if (!_player || _item.kind == SFItemLive) return;
    _pendingSeek += delta;
    [self showOSD:YES autoHide:NO];
    [self updateBar];
    [_seekTimer invalidate];
    _seekTimer = [NSTimer scheduledTimerWithTimeInterval:0.7 target:self selector:@selector(commitSeek) userInfo:nil repeats:NO];
}

- (void)commitSeek {
    NSTimeInterval d = [self duration];
    NSTimeInterval target = MAX(0, MIN(d > 0 ? d - 2 : HUGE_VAL, [self current] + _pendingSeek));
    _pendingSeek = 0;
    if (_nextTimer) { [_nextTimer invalidate]; _nextTimer = nil; _nextCard.hidden = YES; }
    [_player seekToTime:CMTimeMakeWithSeconds(target, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    _ended = NO;
    [self showOSD:YES autoHide:YES];
}

#pragma mark End / Next

// Nächste Folge = die nächstneuere Folge derselben lokalen Sendung (Episoden sind
// neueste-zuerst sortiert). Gemischte Reihen (Neue Folgen, Weiterschauen) springen
// so nie in eine fremde Sendung.
- (SFItem *)nextItem {
    if (_explicitQueue) return _index + 1 < _queue.count ? _queue[_index + 1] : nil;
    if (!_item.localPath || !_item.channel) return nil;
    SFShow *show = [[SFLibrary shared] showNamed:_item.channel source:_item.source];
    NSUInteger i = NSNotFound;
    for (NSUInteger k = 0; k < show.episodes.count; k++)
        if ([[show.episodes[k] localPath] isEqualToString:_item.localPath]) { i = k; break; }
    if (i == NSNotFound || i == 0) return nil;
    return show.episodes[i - 1];
}

- (void)didEnd:(NSNotification *)n {
    _ended = YES;
    [self postState];
    [self saveProgress];
    [self setAssertion:NO];
    SFItem *next = [self nextItem];
    if (!next) { [self.navigator pop]; return; }
    [self showNextCard:next];
}

- (void)failedToEnd:(NSNotification *)n {
    SFLog(@"player: failed to end %@", n.userInfo);
    [self showMessage:@"Die Verbindung wurde unterbrochen."];
}

- (void)showNextCard:(SFItem *)next {
    SFTheme *t = self.theme;
    if (!_nextCard) {
        _nextCard = [CALayer layer];
        _nextCard.backgroundColor = [NSColor colorWithDeviceWhite:0.08 alpha:0.92].CGColor;
        _nextCard.cornerRadius = U(16);
        _nextLabel = [SFLabel labelWithFont:[t medium:30] color:[NSColor whiteColor]];
        _nextLabel.maxLines = 3;
        [_nextCard addSublayer:_nextLabel];
        [self.layer addSublayer:_nextCard];
    }
    _nextCountdown = 8;
    void (^upd)(void) = ^{
        self->_nextLabel.text = [NSString stringWithFormat:@"Nächste Folge in %ld s\n%@\nOK = jetzt  ·  Menu = beenden", (long)self->_nextCountdown, next.title];
        CGFloat h = [self->_nextLabel sizeToFitWidth:U(700)];
        self->_nextCard.frame = CGRectMake(self.size.width - U(860), self.size.height - h - U(160), U(760), h + U(60));
        self->_nextLabel.position = CGPointMake(U(30), U(30));
    };
    SFNoAnimate(upd);
    _nextCard.hidden = NO;
    [_nextTimer invalidate];
    _nextTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(nextTick:) userInfo:[upd copy] repeats:YES];
}

- (void)nextTick:(NSTimer *)t {
    _nextCountdown--;
    if (_nextCountdown <= 0) { [self playNext]; return; }
    SFNoAnimate(t.userInfo);
}

- (void)playNext {
    [_nextTimer invalidate]; _nextTimer = nil;
    _nextCard.hidden = YES;
    SFItem *next = [self nextItem];
    if (!next) return;
    [self saveProgress];
    [self teardownPlayer];      // alten Player lösen, bevor _item wechselt
    _ended = NO;
    _index++;
    if (_explicitQueue) _index = MIN(_index, _queue.count - 1);
    _item = next;
    _lastSaved = 0;
    [self startItem];
}

#pragma mark Input

- (BOOL)handleKey:(SFKey)key {
    if (_nextTimer) {
        if (key == SFKeySelect || key == SFKeyPlayPause) { [self playNext]; return YES; }
        if (key == SFKeyMenu) { [_nextTimer invalidate]; _nextTimer = nil; [self.navigator pop]; return YES; }
    }
    switch (key) {
        case SFKeyPlayPause: [self togglePause]; return YES;
        case SFKeySelect:
            if (_failed) { [self.navigator pop]; return YES; }
            if (!_osdVisible) [self showOSD:YES autoHide:YES];
            else [self togglePause];
            return YES;
        case SFKeyLeft: [self seekBy:-10]; return YES;
        case SFKeyRight: [self seekBy:30]; return YES;
        case SFKeyPrev: [self seekBy:-120]; return YES;
        case SFKeyNext: [self seekBy:120]; return YES;
        // Hoch/Runter (+/- am Remote-Ring) = Systemlautstärke, Halten wiederholt
        case SFKeyUp: case SFKeyUpHold: [self.navigator volumeStep:+1]; return YES;
        case SFKeyDown: case SFKeyDownHold: [self.navigator volumeStep:-1]; return YES;
        case SFKeyMenu:
            if (_pendingSeek != 0) { _pendingSeek = 0; [_seekTimer invalidate]; [self updateBar]; return YES; }
            [self saveProgress];
            _closing = YES;
            return NO;   // Navigator: zurück
        default: return NO;
    }
}
@end
