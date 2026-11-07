#import "SFPlayerScreen.h"
#import "SFSettings.h"
#import "SFLayers.h"
#import "SFStore.h"
#import "SFMPVEngine.h"
#import "SFApp.h"
#import "SFPower.h"

NSString *const SFPlayerStateNotification = @"SFPlayerStateNotification";

#import "SFPlayerScreen+Private.h"

@implementation SFPlayerScreen

- (instancetype)initWithItem:(SFItem *)item queue:(NSArray *)queue index:(NSUInteger)index {
    if ((self = [super initWithTheme:[SFTheme themeNamed:item.source ?: @"home"]])) {
        _item = item;
        _queue = queue;
        _index = index;
        _seekBase = -1;
        _esFocus = -1;
    }
    return self;
}

- (void)dealloc { [self teardown]; }

#pragma mark Layout

// overlays above the timeline (U(150) from the bottom) instead of on it
- (CGFloat)toastCenterFromBottom { return U(250); }

- (void)layoutForSize:(CGSize)size {
    CALayer *L = self.layer;
    SFTheme *t = self.theme;
    SFNoAnimate(^{
        L.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        if (!self->_videoHost) {
            self->_videoHost = [CALayer layer];
            self->_videoHost.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
            [L insertSublayer:self->_videoHost atIndex:0];
        }
        self->_videoHost.frame = L.bounds;
        self->_engine.videoLayer.frame = self->_videoHost.bounds;

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
        // top right as in the lists: "[OK] halten: Info" (makes the gesture visible). The info panel
        // always has something (description, channel, audio/subtitles, up next), so always shown.
        self->_trackHint = [SFLabel labelWithFont:[t medium:26] color:[NSColor colorWithDeviceWhite:1 alpha:0.85]];
        self->_trackHint.text = @"halten: Info";
        self->_trackHint.alignment = NSRightTextAlignment;
        [self->_trackHint sizeToFitWidth:U(420)];
        self->_trackHint.position = CGPointMake(x + w - U(420), U(72));
        CGFloat hw = [self->_trackHint.text sizeWithAttributes:@{NSFontAttributeName: [t medium:26]}].width;
        self->_trackKey = [CALayer layer];
        self->_trackKey.borderColor = [NSColor colorWithDeviceWhite:1 alpha:0.85].CGColor;
        self->_trackKey.borderWidth = U(2); self->_trackKey.cornerRadius = U(8);
        self->_trackKey.frame = CGRectMake(x + w - hw - U(12) - U(52), U(70), U(52), U(34));
        SFLabel *ok = [SFLabel labelWithFont:[t bold:20] color:[NSColor colorWithDeviceWhite:1 alpha:0.85]];
        ok.text = @"OK"; ok.alignment = NSCenterTextAlignment;
        [ok sizeToFitWidth:U(52)];
        ok.position = CGPointMake(0, (U(34) - ok.bounds.size.height) / 2);
        [self->_trackKey addSublayer:ok];
        [self->_osd addSublayer:self->_trackKey];
        [self->_osd addSublayer:self->_trackHint];
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
        NSColor *acc = t.seekBarColor;
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

        // pause icon
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
    [self esLayout];
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

// The spinner's rule: until this open's first frame is up, and while running playback waits for data
- (BOOL)awaitingPicture {
    if (_failed) return NO;
    return !_engine.started || (_engine.playing && !_engine.likelyToKeepUp);
}

- (void)showSpinner:(BOOL)on {
    if (on != (_spinner != nil)) SFLog(@"player: spinner %@", on ? @"on" : @"off");
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
    if (!_engine && !_closing) [self startItem];
    else if (_engine && !_engine.playing && !_ended && !_failed) [self showOSD:YES autoHide:NO];   // back from the info panel, paused: show where we are
    // Ended without a successor while an overlay (info panel) was open: the player stayed so the
    // panel was not pulled away; back on the video now -> leave as an ending video does
    else if (_ended && !_nextTimer && ![self nextItem]) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (self.navigator.top == self && self->_ended && !self->_nextTimer) [self.navigator pop]; });
    }
}

// Leave the player even when an overlay (menu, info panel) is on top of it
- (void)close {
    SFNavigator *nav = self.navigator;
    [nav popAbove:self];
    if (nav.top == self) [nav pop];
}

- (void)willDisappear {
    [self saveProgress];
    [self teardown];
    [[NSNotificationCenter defaultCenter] postNotificationName:SFPlayerStateNotification object:self userInfo:@{@"closed": @YES}];
}

- (void)startItem {
    _ended = NO; _failed = NO;
    [self esReset];
    if (_item != _lastStartedItem) { _sessionReopenedAt = -1; _subsApplied = NO; _lastStartedItem = _item; _upNext = nil; _upNextAsked = NO; }
    if (_queue.count && !_explicitQueue && self.remoteListID) _explicitQueue = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self postState]; });
    [self updateTitles];
    [self showMessage:@""];
    [self showSpinner:YES];
    [self showOSD:YES autoHide:YES];
    SFItem *it = _item;
    if (it.drm && it.kind != SFItemLive) {       // defense in depth: any path that still lands on DRM
        SFLog(@"player: %@ is DRM-protected - not playable here", it.identifier);
        _failed = YES;
        [self showSpinner:NO];
        [self showMessage:[SFDRMNotice stringByAppendingString:@"\n\nOK – zurück"]];
        if ([self nextItem]) { _ended = YES; [self playNext]; }   // queue/autoplay: just move on
        return;
    }
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
        self->_holdPaused = self.startPaused;   // new item: paused only if explicitly requested
        [self playURL:url];
    }];
}

// One engine since 2026-11-06: mpv (libmpv) plays everything - AVFoundation, the fallback until
// then, rescued no playback in its last days (4 of 4 fallbacks failed the same way) and can't do
// VP9/AV1/Opus or DASH (user decision 2026-11-04 "AVFoundation entfernen", docs/codecs-research.md).
- (void)playURL:(NSURL *)url {
    [self teardownPlayer];
    _openURL = url;
    if (self.startPaused) _holdPaused = YES;
    NSDictionary *src = SFMPVSourceFor(url);
    NSURL *open = url, *audio = nil;
    _openedDash = src[@"video"] != nil;   // separate video/audio tracks (YouTube SABR)
    if (_openedDash) {
        open = [NSURL URLWithString:src[@"video"]];
        if (src[@"audio"]) audio = [NSURL URLWithString:src[@"audio"]];
    }
    _engine = [SFMPVEngine new];
    _engine.delegate = self;
    _engine.muted = SFDevMode;   // dev mode: don't disturb anyone
    SFNoAnimate(^{
        for (CALayer *l in [self->_videoHost.sublayers copy]) [l removeFromSuperlayer];
        CALayer *v = self->_engine.videoLayer;
        if (v) { [v removeFromSuperlayer]; v.frame = self->_videoHost.bounds; [self->_videoHost addSublayer:v]; }
    });
    SFLog(@"player: play %@ via %@%@", open.isFileURL ? open.path.lastPathComponent : open.host, _engine.engineName,
          _openedDash ? [NSString stringWithFormat:@" (%@p%@ %@, audio %@)", src[@"height"], src[@"fps"], src[@"vcodec"], src[@"alang"] ?: @"?"] : @"");
    __weak SFPlayerScreen *wself = self;
    // the service behind the app's session streams died: its local URLs are gone - reopen right
    // away instead of waiting for mpv's reconnects and the stall watchdog
    Class<SFApp> app = [SFAppRegistry appForItem:_item];
    NSString *lost = [app respondsToSelector:@selector(playbackSessionLostNotification)] ? [app playbackSessionLostNotification] : nil;
    if (_sabrObs) { [[NSNotificationCenter defaultCenter] removeObserver:_sabrObs]; _sabrObs = nil; }
    if (lost) _sabrObs = [[NSNotificationCenter defaultCenter] addObserverForName:lost object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            SFPlayerScreen *s = wself;
            // not after the end (up-next card, end screen): the finished video must not restart
            if (s && s->_engine && !s->_closing && !s->_failed && !s->_ended && [s sessionSource]) [s sessionFailed:@"service exited"];
        }];
    if (!_powerObs) _powerObs = [[NSNotificationCenter defaultCenter] addObserverForName:SFPowerWillTurnOffNotification object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [wself remotePause]; [wself saveProgress]; }];

    NSTimeInterval resume = self.startFromBeginning ? 0 : [[SFStore shared] positionFor:_item.identifier];
    BOOL exact = self.startPosition > 0;
    if (exact) resume = self.startPosition;
    self.startFromBeginning = NO;
    self.startPosition = 0;
    BOOL live = _item.kind == SFItemLive;
    _openResume = live ? 0 : (exact ? resume : (resume > 15 ? resume - 3 : 0));
    BOOL paused = self.startPaused || _holdPaused;
    [_engine openURL:open audioURL:audio start:_openResume exact:exact paused:paused];
    if (!exact && resume > 15 && !live) [self.navigator toast:[NSString stringWithFormat:@"Fortgesetzt bei %@", SFFormatDuration(_openResume)]];   // = actual start point (3 s lead-in)
    if (paused) { self.startPaused = NO; [self showOSD:YES autoHide:NO]; }
    else [self setAssertion:YES];
}

- (id)engineForDiagnostics { return _engine; }

#pragma mark Progress

- (NSTimeInterval)current { return _engine.currentTime; }

// Origin for jumps: while a jump is still in progress the player briefly reports the old
// position - then compute from the last target (otherwise fast forward/back jumps back and forth)
- (NSTimeInterval)seekOrigin {
    NSTimeInterval c = [self current];
    if (_seekBase >= 0 && _seekBaseAt && -[_seekBaseAt timeIntervalSinceNow] < 4 && fabs(c - _seekBase) > 1.5) return _seekBase;
    _seekBase = -1;
    return c;
}
- (SFItem *)item { return _item; }
- (NSTimeInterval)currentTime { double c = [self current]; return isnan(c) ? 0 : c; }
- (BOOL)isPaused { return _engine && !_engine.playing; }
- (NSTimeInterval)duration {
    double d = _engine.duration;
    return d > 0 ? d : _item.duration;
}

- (void)saveProgress {
    if (!_engine || _item.kind == SFItemLive || _failed) return;
    NSTimeInterval c = [self current], d = [self duration];
    if (_ended) c = d;
    if (c > 0 && d > 0) [[SFStore shared] savePosition:c duration:d forItem:_item];
}

- (void)tick {
    NSTimeInterval c = [self current];
    // autoplay: from the halfway point fetch the app's "up next" recommendation (once per video)
    NSTimeInterval dur = [self duration];
    BOOL playlistGoesOn = _item.playlistID.length && _index + 1 < _queue.count && [[_queue[_index + 1] playlistID] isEqualToString:_item.playlistID];
    Class<SFApp> app = [SFAppRegistry appForItem:_item];
    if (!_upNextAsked && !_explicitQueue && !playlistGoesOn && [app respondsToSelector:@selector(upNextForItem:done:)] && dur > 0 && c > dur * 0.5) {
        _upNextAsked = YES;
        SFItem *forItem = _item;
        [app upNextForItem:_item done:^(SFItem *next) { if (forItem == self->_item) self->_upNext = next; }];
    }
    if (fabs(c - _lastSaved) > 15) { _lastSaved = c; [self saveProgress]; }
    if (_osdVisible) [self updateBar];
    [self esUpdate];
    if (_spinner && ![self awaitingPicture]) [self showSpinner:NO];
}

- (void)updateBar {
    NSTimeInterval d = [self duration];
    BOOL live = _item.kind == SFItemLive || !(d > 0);
    NSTimeInterval c = [self seekOrigin];
    NSTimeInterval shown = _pendingSeek != 0 ? MAX(0, MIN(d, c + _pendingSeek)) : c;
    CGFloat w = _barBg.bounds.size.width;
    double frac = live ? 1 : shown / d;
    double buf = live ? 0 : _engine.bufferedUntil / d;
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
            self->_endsAt.text = [NSString stringWithFormat:@"Endet um %@", SFFormatClock([NSDate dateWithTimeIntervalSinceNow:d - shown])];
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
    if (on && autoHide && _engine.playing)
        _osdTimer = [NSTimer scheduledTimerWithTimeInterval:4 target:self selector:@selector(autoHide) userInfo:nil repeats:NO];
}
- (void)autoHide { if (_engine.playing && _pendingSeek == 0) [self showOSD:NO autoHide:NO]; }

- (void)postState {
    [[NSNotificationCenter defaultCenter] postNotificationName:SFPlayerStateNotification object:self];
}

- (SFPlaybackState)playbackState {
    if (_closing || !_item) return SFPlaybackIdle;
    if (_ended) return SFPlaybackEnded;
    if (_failed) return SFPlaybackIdle;
    if (!_engine || _engine.status != SFEngineReady || !_engine.started || _pendingSeek != 0) return SFPlaybackBuffering;
    if (_engine.playing) return _engine.likelyToKeepUp ? SFPlaybackPlaying : SFPlaybackBuffering;
    return SFPlaybackPaused;
}

- (NSArray *)queue { return _queue; }
- (NSUInteger)queueIndex { return _index; }

- (void)updatePauseState {
    [self postState];
    BOOL paused = _engine && !_engine.playing && !_ended && !_failed && _engine.status == SFEngineReady;
    BOOL tiles = [self esEngaged];   // choosing among end screen tiles: no OSD/pause icon over them
    SFAnimate(0.2, ^{ self->_pauseIcon.opacity = paused && !tiles ? 1 : 0; });
    if (paused) { if (!tiles) [self showOSD:YES autoHide:NO]; [self setAssertion:NO]; }
    else if (_engine.playing) {
        [self setAssertion:YES];
        if (_osdVisible && !_osdTimer && _pendingSeek == 0)
            _osdTimer = [NSTimer scheduledTimerWithTimeInterval:4 target:self selector:@selector(autoHide) userInfo:nil repeats:NO];
    }
}

- (void)togglePause {
    self.startPaused = NO; _holdPaused = NO;
    if (!_engine) return;
    if (_engine.playing) { [_engine pause]; [self saveProgress]; }
    else {
        if (_ended) { [_engine seekTo:0 exact:NO]; _ended = NO; }
        [_engine play];
        [self showOSD:YES autoHide:YES];
    }
}
@end
