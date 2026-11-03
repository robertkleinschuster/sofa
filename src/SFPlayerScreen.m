#import "SFPlayerScreen.h"
#import "SFLayers.h"
#import "SFStore.h"
#import "SFAVEngine.h"
#import "SFMPVEngine.h"
#import "SFYTResolver.h"
#import "SFYouTube.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "SFLibrary.h"
#import "SFCurl.h"
#import "SFPower.h"

NSString *const SFPlayerStateNotification = @"SFPlayerStateNotification";

@interface SFPlayerScreen () <SFEngineDelegate>
@end

@implementation SFPlayerScreen {
    SFItem *_item;
    NSArray *_queue;
    id _powerObs;
    BOOL _explicitQueue;   // Handy-Playlist: nächster = nächster Queue-Eintrag
    NSUInteger _index;
    id<SFEngine> _engine;        // AVFoundation oder mpv (SFEngine.h)
    CALayer *_videoHost;         // trägt die Video-Ebene der aktiven Engine
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
    NSTimeInterval _seekBase;       // letztes Sprungziel, bis der Player dort angekommen ist (-1 = keins)
    NSDate *_seekBaseAt;
    NSTimer *_seekTimer;
    NSTimeInterval _lastSaved;
    BOOL _ended, _failed, _closing;
    NSURL *_openURL; NSDate *_openAt; NSInteger _openTries; NSTimeInterval _openResume;
    BOOL _holdPaused;   // „pausiert starten“ gilt über Wiederholungsversuche/Ausweich-Streams hinweg, bis der User Play drückt   // Retry bei sporadischem HLS-Öffnungsfehler
    NSTimer *_nextTimer;
    NSInteger _nextCountdown;
    NSURL *_mpvFailedURL;        // mpv scheiterte an dieser URL -> AVFoundation versuchen
    BOOL _reresolved;            // YouTube: Streams abgelehnt -> einmal frisch auflösen
    SFItem *_upNext;             // YouTube „Als Nächstes“ (Empfehlung), im Hintergrund geholt
    BOOL _upNextAsked;
    __weak SFItem *_lastStartedItem;
}

- (instancetype)initWithItem:(SFItem *)item queue:(NSArray *)queue index:(NSUInteger)index {
    if ((self = [super initWithTheme:[SFTheme themeNamed:item.source ?: @"home"]])) {
        _item = item;
        _queue = queue;
        _index = index;
        _seekBase = -1;
    }
    return self;
}

- (void)dealloc { [self teardown]; }

#pragma mark Layout

// Einblendungen über der Zeitleiste (U(150) v. u.) statt darauf
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
    if (!_engine && !_closing) [self startItem];
}

- (void)willDisappear {
    [self saveProgress];
    [self teardown];
    [[NSNotificationCenter defaultCenter] postNotificationName:SFPlayerStateNotification object:self userInfo:@{@"closed": @YES}];
}

- (void)startItem {
    _ended = NO; _failed = NO;
    if (_item != _lastStartedItem) { _reresolved = NO; _mpvFailedURL = nil; _lastStartedItem = _item; _upNext = nil; _upNextAsked = NO; }
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
        self->_holdPaused = self.startPaused;   // neuer Inhalt: nur pausiert, wenn ausdrücklich verlangt
        [self playURL:url];
    }];
}

- (void)playURL:(NSURL *)url { [self playURL:url forceMPV:NO]; }

// Engine-Wahl (User-Vorgabe): H.264 bis 1080p über AVFoundation (Hardware); mpv nur, wenn es
// Besseres gibt (DASH-VP9/AV1 mit mehr Auflösung/fps), das Format AVFoundation fremd ist (WebM/MKV)
// oder AVFoundation am Stream scheitert (forceMPV).
- (BOOL)prefersMPV:(NSDictionary *)src url:(NSURL *)url {
    if (!SFMPVAvailable() || [url isEqual:_mpvFailedURL]) return NO;
    if (SFDevMode && [[NSProcessInfo processInfo].environment[@"SOFA_FORCE_MPV"] length]) return YES;   // Dev-Test
    NSString *ext = url.path.pathExtension.lowercaseString;
    if ([@[@"webm", @"mkv", @"ogv"] containsObject:ext]) return YES;
    if (!src[@"video"]) return NO;
    double dh = [src[@"height"] doubleValue], df = [src[@"fps"] doubleValue];
    double hh = [src[@"hlsHeight"] doubleValue], hf = [src[@"hlsFps"] doubleValue];
    return dh > hh || (dh == hh && df > hf + 1);
}

- (void)playURL:(NSURL *)url forceMPV:(BOOL)forceMPV {
    [self teardownPlayer];
    _openURL = url; _openAt = [NSDate date]; _openTries++;
    if (self.startPaused) _holdPaused = YES;
    NSDictionary *src = SFMPVSourceFor(url);
    BOOL useMPV = SFMPVAvailable() && (forceMPV || [self prefersMPV:src url:url]);
    NSURL *open = url, *audio = nil;
    if (useMPV && src[@"video"]) {
        open = [NSURL URLWithString:src[@"video"]];
        if (src[@"audio"]) audio = [NSURL URLWithString:src[@"audio"]];
    }
    _engine = useMPV ? (id<SFEngine>)[SFMPVEngine new] : (id<SFEngine>)[SFAVEngine new];
    _engine.delegate = self;
    _engine.muted = SFDevMode;   // Dev-Modus: niemanden stören
    SFNoAnimate(^{
        for (CALayer *l in [self->_videoHost.sublayers copy]) [l removeFromSuperlayer];
        CALayer *v = self->_engine.videoLayer;
        if (v) { [v removeFromSuperlayer]; v.frame = self->_videoHost.bounds; [self->_videoHost addSublayer:v]; }
    });
    SFLog(@"player: play %@ via %@%@", open.isFileURL ? open.path.lastPathComponent : open.host, _engine.engineName,
          useMPV && src[@"video"] ? [NSString stringWithFormat:@" (%@p%@ %@)", src[@"height"], src[@"fps"], src[@"vcodec"]] : @"");
    __weak SFPlayerScreen *wself = self;
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
    if (!exact && resume > 15 && !live) [self.navigator toast:[NSString stringWithFormat:@"Fortgesetzt bei %@", SFFormatDuration(_openResume)]];   // = tatsächlicher Startpunkt (3 s Vorlauf)
    if (paused) { self.startPaused = NO; [self showOSD:YES autoHide:NO]; }
    else [self setAssertion:YES];
}

#pragma mark SFEngineDelegate

- (void)engineStatusChanged {
    if (_engine.status == SFEngineFailed) {
        BOOL viaMPV = [_engine isKindOfClass:[SFMPVEngine class]];
        if (SFDevMode) {   // Ursache nachvollziehbar machen (Domain/Code/zugrundeliegender Fehler)
            NSError *e = _engine.error, *u = e.userInfo[NSUnderlyingErrorKey];
            SFLog(@"player: error %@ %ld %@ | underlying %@ %ld | %@", e.domain, (long)e.code, e.localizedFailureReason ?: @"",
                  u.domain, (long)u.code, e.userInfo[NSLocalizedRecoverySuggestionErrorKey] ?: @"");
        }
        // googlevideo-HLS scheitert auf 10.9 sporadisch sofort (-12643/-12939), derselbe
        // URL klappt beim nächsten Versuch (docs/youtube.md §6) -> bis zu 3x neu öffnen.
        if (!viaMPV && _openURL && !_openURL.isFileURL && _openTries < 3 && -[_openAt timeIntervalSinceNow] < 3) {
            SFLog(@"player: open failed (%ld), retry %ld", (long)_engine.error.code, (long)_openTries);
            NSURL *u = _openURL; SFItem *it = _item; NSTimeInterval pos = MAX(_openResume, _engine.currentTime > 5 ? _engine.currentTime : 0);   // Abbruch mitten im Video: dort weiter
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self->_closing || it != self->_item) return;
                if (pos > 0) self.startPosition = pos; else self.startFromBeginning = YES;
                [self playURL:u];
            });
            return;
        }
        if (viaMPV && _openURL && ![_openURL isEqual:_mpvFailedURL]) {   // mpv scheitert -> AVFoundation
            SFLog(@"player: mpv scheitert -> AVFoundation");
            _mpvFailedURL = _openURL;
            NSURL *u = _openURL; SFItem *it = _item; NSTimeInterval pos = MAX(_openResume, _engine.currentTime > 5 ? _engine.currentTime : 0);   // Abbruch mitten im Video: dort weiter
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self->_closing || it != self->_item) return;
                self->_openTries = 0;
                if (pos > 0) self.startPosition = pos; else self.startFromBeginning = YES;
                [self playURL:u forceMPV:NO];
            });
            return;
        }
        NSURL *alt = viaMPV ? nil : SFNextAlternateURL(_openURL);
        // Formate, die AVFoundation nicht kann (HLS v7, fMP4, …): mpv übernimmt vor schlechteren Ausweich-Streams
        BOOL tryMPV = !viaMPV && SFMPVAvailable() && _openURL && ![_openURL isEqual:_mpvFailedURL];
        if (tryMPV || alt) {
            NSURL *next = tryMPV ? _openURL : alt;
            SFLog(@"player: %@", tryMPV ? @"AVFoundation scheitert -> mpv" : @"switching to alternate stream");
            SFItem *it = _item; NSTimeInterval pos = MAX(_openResume, _engine.currentTime > 5 ? _engine.currentTime : 0);   // Abbruch mitten im Video: dort weiter
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self->_closing || it != self->_item) return;
                self->_openTries = 0;
                if (pos > 0) self.startPosition = pos; else self.startFromBeginning = YES;
                [self playURL:next forceMPV:tryMPV];
            });
            return;
        }
        // YouTube-URLs werden sporadisch komplett abgelehnt (403/-1102): einmal frisch auflösen
        NSString *ref = _item.resolverRef ?: _item.identifier;
        if (!_reresolved && [ref hasPrefix:@"yt:"]) {
            _reresolved = YES;
            SFLog(@"player: alle Streams abgelehnt -> frisch auflösen");
            [[SFYTResolver shared] forget:[ref substringFromIndex:3]];
            _mpvFailedURL = nil;
            self.startPaused = self.startPaused || _holdPaused;   // „pausiert starten“ übersteht das Neu-Auflösen
            NSTimeInterval pos = MAX(_openResume, _engine.currentTime > 5 ? _engine.currentTime : 0);   // Abbruch mitten im Video: dort weiter
            if (pos > 0) self.startPosition = pos; else self.startFromBeginning = YES;
            [self teardownPlayer];
            [self startItem];
            return;
        }
        [self showSpinner:NO];
        _failed = YES;
        SFLog(@"player: failed (%@) %@", _engine.engineName, _engine.error);
        [self showMessage:[NSString stringWithFormat:@"Wiedergabe fehlgeschlagen\n%@", _engine.error.localizedDescription ?: @""]];
        [self postState];
    } else if (_engine.status == SFEngineReady) {
        [self showMessage:@""];   // z. B. „Verbindung unterbrochen“ nach erfolgreichem Ausweichen
        if (self.startPaused || _holdPaused) { [_engine pause]; self.startPaused = NO; }   // Pause während des Ladens / nach Update
        [self postState];
        if (_item.duration <= 0 && _engine.duration > 0) _item.duration = _engine.duration;
        [self updatePauseState];
    }
}
- (void)engineRateChanged { [self updatePauseState]; }
- (void)engineBufferingChanged {
    [self showSpinner:!_engine.likelyToKeepUp && _engine.playing && !_failed];
    [self postState];
}
- (void)engineDidEnd { [self didEnd:nil]; }
- (void)engineInterrupted { [self failedToEnd:nil]; }
- (void)engineTick { [self tick]; }

- (void)teardownPlayer {
    _engine.delegate = nil;   // keine späten Rückrufe der alten Engine
    [_engine shutdown];
    _engine = nil;
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

- (NSTimeInterval)current { return _engine.currentTime; }

// Ausgangspunkt für Sprünge: während ein Sprung noch läuft, meldet der Player kurz die alte
// Position – dann vom letzten Ziel aus rechnen (sonst springt schnelles Vor/Zurück hin und her)
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
    // YouTube-Autoplay: ab der Hälfte die Empfehlung „Als Nächstes“ holen (einmal je Video)
    NSTimeInterval dur = [self duration];
    BOOL playlistGoesOn = _item.playlistID.length && _index + 1 < _queue.count && [[_queue[_index + 1] playlistID] isEqualToString:_item.playlistID];
    if (!_upNextAsked && !_explicitQueue && !playlistGoesOn && [_item.source isEqualToString:@"youtube"] && _item.externalID.length == 11 && dur > 0 && c > dur * 0.5) {
        _upNextAsked = YES;
        SFItem *forItem = _item;
        [SFYouTube upNextFor:_item.externalID done:^(SFItem *next) { if (forItem == self->_item) self->_upNext = next; }];
    }
    if (fabs(c - _lastSaved) > 15) { _lastSaved = c; [self saveProgress]; }
    if (_osdVisible) [self updateBar];
    if (_spinner && _engine.status == SFEngineReady && _engine.likelyToKeepUp) [self showSpinner:NO];
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
    if (!_engine || _engine.status != SFEngineReady || _pendingSeek != 0) return SFPlaybackBuffering;
    if (_engine.playing) return _engine.likelyToKeepUp ? SFPlaybackPlaying : SFPlaybackBuffering;
    return SFPlaybackPaused;
}

- (NSArray *)queue { return _queue; }
- (NSUInteger)queueIndex { return _index; }
- (BOOL)hasNext { return [self nextItem] != nil; }
- (BOOL)hasPrevious { return _explicitQueue && _index > 0; }
- (void)remotePlay { self.startPaused = NO; _holdPaused = NO; if (_engine && !_engine.playing) [self togglePause]; }
- (void)remotePause {
    // Pause während des Ladens/Retry: merken, damit der Player pausiert startet
    if (!_engine || _engine.status != SFEngineReady) { self.startPaused = YES; [_engine pause]; [self postState]; return; }
    if (_engine.playing) [self togglePause];
}
- (void)remoteSeekTo:(NSTimeInterval)t {
    if (!_engine || _item.kind == SFItemLive) return;
    _pendingSeek = 0;
    _seekBase = MAX(0, t); _seekBaseAt = [NSDate date];
    [_engine seekTo:t exact:YES];
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
    BOOL paused = _engine && !_engine.playing && !_ended && !_failed && _engine.status == SFEngineReady;
    SFAnimate(0.2, ^{ self->_pauseIcon.opacity = paused ? 1 : 0; });
    if (paused) { [self showOSD:YES autoHide:NO]; [self setAssertion:NO]; }
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

#pragma mark Seek

- (void)seekBy:(NSTimeInterval)delta {
    if (!_engine || _item.kind == SFItemLive) return;
    _pendingSeek += delta;
    [self showOSD:YES autoHide:NO];
    [self updateBar];
    [_seekTimer invalidate];
    _seekTimer = [NSTimer scheduledTimerWithTimeInterval:0.7 target:self selector:@selector(commitSeek) userInfo:nil repeats:NO];
}

- (void)commitSeek {
    NSTimeInterval d = [self duration];
    NSTimeInterval target = MAX(0, MIN(d > 0 ? d - 2 : HUGE_VAL, [self seekOrigin] + _pendingSeek));
    _pendingSeek = 0;
    _seekBase = target; _seekBaseAt = [NSDate date];
    if (_nextTimer) { [_nextTimer invalidate]; _nextTimer = nil; _nextCard.hidden = YES; }
    [_engine seekTo:target exact:YES];
    _ended = NO;
    [self showOSD:YES autoHide:YES];
}

#pragma mark End / Next

// Nächste Folge = die nächstneuere Folge derselben lokalen Sendung (Episoden sind
// neueste-zuerst sortiert). Gemischte Reihen (Neue Folgen, Weiterschauen) springen
// so nie in eine fremde Sendung.
- (SFItem *)nextItem {
    if (_explicitQueue) return _index + 1 < _queue.count ? _queue[_index + 1] : nil;
    // Aus einer Playlist gestartet: nächstes Video der Playlist (vor Empfehlungen)
    if (_item.playlistID.length && _index + 1 < _queue.count && [[_queue[_index + 1] playlistID] isEqualToString:_item.playlistID]) return _queue[_index + 1];
    if (!_item.localPath || !_item.channel) return _upNext;   // gestreamtes YouTube: Empfehlung
    SFShow *show = [[SFLibrary shared] showNamed:_item.channel source:_item.source];
    NSUInteger i = NSNotFound;
    for (NSUInteger k = 0; k < show.episodes.count; k++)
        if ([[show.episodes[k] localPath] isEqualToString:_item.localPath]) { i = k; break; }
    if (i == NSNotFound || i == 0) return _upNext;           // letzte heruntergeladene Folge: Empfehlung
    return show.episodes[i - 1];
}

- (void)didEnd:(NSNotification *)n {
    _ended = YES;
    [self updatePauseState];   // am Ende kein Pause-Symbol über der „Als Nächstes“-Karte
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

// „Als Nächstes“ / „Nächste Folge“: Karte wie bei YouTube – Vorschaubild links, rechts Countdown,
// Titel, Kanal und Remote-Hinweis; über dem Fortschrittsbalken, damit Zeit und Balken frei bleiben.
- (void)showNextCard:(SFItem *)next {
    SFTheme *t = self.theme;
    [_nextCard removeFromSuperlayer];
    _nextCard = [CALayer layer];
    _nextCard.backgroundColor = [NSColor colorWithDeviceWhite:0.07 alpha:0.94].CGColor;
    _nextCard.cornerRadius = U(18);
    CGFloat pad = U(24), tw = U(320), th = U(180), cw = U(980), ch = th + 2 * pad;
    SFImageLayer *thumb = [SFImageLayer layer];
    thumb.frame = CGRectMake(pad, pad, tw, th);
    thumb.cornerRadius = U(10); thumb.masksToBounds = YES;
    thumb.contentsGravity = kCAGravityResizeAspectFill;
    thumb.placeholderColor = [NSColor colorWithDeviceWhite:0.15 alpha:1];
    thumb.source = next.image;
    [_nextCard addSublayer:thumb];
    CGFloat x = pad + tw + U(28), w = cw - x - pad;
    _nextLabel = [SFLabel labelWithFont:[t medium:24] color:t.accent];
    SFLabel *title = [SFLabel labelWithFont:[t bold:32] color:[NSColor whiteColor]];
    title.maxLines = 2; title.text = next.title;
    SFLabel *sub = [SFLabel labelWithFont:[t regular:24] color:[NSColor colorWithDeviceWhite:1 alpha:0.7]];
    sub.text = next.channel ?: @"";
    SFLabel *hint = [SFLabel labelWithFont:[t medium:22] color:[NSColor colorWithDeviceWhite:1 alpha:0.6]];
    hint.text = @"OK: jetzt abspielen   ·   MENU: beenden";
    for (SFLabel *l in @[_nextLabel, title, sub, hint]) [_nextCard addSublayer:l];
    BOOL rec = next == _upNext;
    _nextCountdown = 8;
    void (^upd)(void) = ^{
        NSString *what = rec ? @"Als Nächstes" : (next.playlistID.length ? @"Nächstes in der Playlist" : @"Nächste Folge");
        self->_nextLabel.text = [NSString stringWithFormat:@"%@ in %ld s", what, (long)self->_nextCountdown];
        CGFloat y = pad;
        y += [self->_nextLabel sizeToFitWidth:w] + U(6); self->_nextLabel.position = CGPointMake(x, pad);
        CGFloat h1 = [title sizeToFitWidth:w]; title.position = CGPointMake(x, y); y += h1 + U(6);
        CGFloat h2 = sub.text.length ? [sub sizeToFitWidth:w] : 0; sub.position = CGPointMake(x, y);
        CGFloat hh = [hint sizeToFitWidth:w]; hint.position = CGPointMake(x, ch - pad - hh);
        (void)h2;
        self->_nextCard.frame = CGRectMake(self.size.width - U(110) - cw, self.size.height - U(190) - ch, cw, ch);
    };
    SFNoAnimate(^{ upd(); [self.layer addSublayer:self->_nextCard]; });
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
    _upNext = nil; _upNextAsked = NO;
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
