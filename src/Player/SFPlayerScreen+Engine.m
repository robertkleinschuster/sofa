// SFPlayerScreen - engine events: status, buffering, end and interruption, recovery of failed streams, teardown.
#import "SFPlayerScreen+Private.h"
#import "SFStats.h"
#import "SFMPVEngine.h"
#import "SFApp.h"
#import <IOKit/pwr_mgt/IOPMLib.h>

@implementation SFPlayerScreen (Engine)

#pragma mark SFEngineDelegate

// Error text for the TV: the cause in German instead of the system message ("unknown error")
static NSString *SFFriendlyPlaybackError(NSError *e) {
    NSError *u = e.userInfo[NSUnderlyingErrorKey];
    for (NSError *x in @[e ?: [NSNull null], u ?: [NSNull null]]) {
        if (![x isKindOfClass:[NSError class]]) continue;
        if ([x.domain isEqualToString:NSURLErrorDomain]) switch (x.code) {
            case NSURLErrorNotConnectedToInternet: case NSURLErrorNetworkConnectionLost:
                return @"Keine Internetverbindung.";
            case NSURLErrorTimedOut: case NSURLErrorCannotConnectToHost: case NSURLErrorCannotFindHost:
            case NSURLErrorDNSLookupFailed:
                return @"Der Server des Anbieters antwortet nicht.";
            default: break;
        }
        if ([x.domain isEqualToString:NSOSStatusErrorDomain] && (x.code == -12660 || x.code == -12938))   // HTTP 403 / 404
            return @"Der Anbieter liefert dieses Video gerade nicht aus.";
    }
    return @"Das Video ließ sich nicht laden – bitte später noch einmal versuchen.";
}

// Where to continue after a failure: aborted midway -> there, otherwise at the start point
- (NSTimeInterval)failurePosition {
    return MAX(_openResume, _engine.currentTime > 5 ? _engine.currentTime : 0);
}

// Fallback step: reopen the same (or another) URL after a short delay, at the failure position.
// Dropped if closed meanwhile or another video is playing.
- (void)reopen:(NSURL *)url forceMPV:(BOOL)forceMPV after:(double)delay resetTries:(BOOL)reset {
    SFItem *it = _item; NSTimeInterval pos = [self failurePosition];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_closing || it != self->_item) return;
        if (reset) self->_openTries = 0;
        if (pos > 0) self.startPosition = pos; else self.startFromBeginning = YES;
        [self playURL:url forceMPV:forceMPV];
    });
}

// The opened stream comes from an app session (e.g. YouTube SABR via the sidecar)?
- (BOOL)sessionSource {
    Class<SFApp> app = [SFAppRegistry appForItem:_item];
    return [app respondsToSelector:@selector(playbackIsSession:)] && [app playbackIsSession:SFMPVSourceFor(_openURL)];
}

// A session stream broke: the app recovers its side (fresh session, or its fallback path on the
// second failure), the player restarts the item at the same position.
- (void)sessionFailed:(NSString *)why {
    Class<SFApp> app = [SFAppRegistry appForItem:_item];
    if ([app respondsToSelector:@selector(playbackSessionFailed:item:retried:reason:)])
        [app playbackSessionFailed:SFMPVSourceFor(_openURL) item:_item retried:_sabrRetried reason:why];
    _sabrRetried = YES;
    self.startPaused = self.startPaused || _holdPaused;
    NSTimeInterval pos = [self failurePosition];
    if (pos > 0) self.startPosition = pos; else self.startFromBeginning = YES;
    [self teardownPlayer];
    [self startItem];
}

- (void)engineStatusChanged {
    if (_engine.status == SFEngineFailed) {
        BOOL viaMPV = [_engine isKindOfClass:[SFMPVEngine class]];
        if (SFDevMode) {   // make the cause traceable (domain/code/underlying error)
            NSError *e = _engine.error, *u = e.userInfo[NSUnderlyingErrorKey];
            SFLog(@"player: error %@ %ld %@ | underlying %@ %ld | %@", e.domain, (long)e.code, e.localizedFailureReason ?: @"",
                  u.domain, (long)u.code, e.userInfo[NSLocalizedRecoverySuggestionErrorKey] ?: @"");
        }
        // a session stream (app service) failed: the app's recovery first (see sessionFailed:)
        if ([self sessionSource]) { [self sessionFailed:_engine.error.localizedDescription]; return; }
        // googlevideo HLS sporadically fails immediately on 10.9 (-12643/-12939), the same
        // URL works on the next attempt (docs/youtube.md §6) -> reopen up to 3x.
        if (!viaMPV && _openURL && !_openURL.isFileURL && _openTries < 3 && -[_openAt timeIntervalSinceNow] < 3) {
            SFLog(@"player: open failed (%ld), retry %ld", (long)_engine.error.code, (long)_openTries);
            SFCount(@"player.av-open-retry");
            [self reopen:_openURL forceMPV:NO after:0.1 resetTries:NO];
            return;
        }
        // YouTube occasionally rejects the DASH streams right away (HTTP 403), the HLS stream of the same
        // resolution plays: first mpv with HLS, instead of AVFoundation retries (docs/youtube.md §6)
        if (viaMPV && _openedDash && _openURL && ![_openURL isEqual:_dashFailedURL]) {
            SFLog(@"player: DASH rejected -> mpv with HLS");
            SFCount(@"player.dash-to-hls");
            _dashFailedURL = _openURL;
            [self reopen:_openURL forceMPV:YES after:0.1 resetTries:YES];
            return;
        }
        if (viaMPV && _openURL && ![_openURL isEqual:_mpvFailedURL]) {   // mpv fails -> AVFoundation
            SFLog(@"player: mpv fails -> AVFoundation");
            SFCount(@"player.mpv-to-av");
            _mpvFailedURL = _openURL;
            [self reopen:_openURL forceMPV:NO after:0.2 resetTries:YES];
            return;
        }
        NSURL *alt = viaMPV ? nil : SFNextAlternateURL(_openURL);
        // formats AVFoundation can't do (HLS v7, fMP4, ...): mpv takes over before worse fallback streams
        BOOL tryMPV = !viaMPV && SFMPVAvailable() && _openURL && ![_openURL isEqual:_mpvFailedURL];
        if (tryMPV || alt) {
            NSURL *next = tryMPV ? _openURL : alt;
            SFLog(@"player: %@", tryMPV ? @"AVFoundation fails -> mpv" : @"switching to alternate stream");
            SFCount(tryMPV ? @"player.av-to-mpv" : @"player.alternate-stream");
            [self reopen:next forceMPV:tryMPV after:0.2 resetTries:YES];
            return;
        }
        // all streams rejected (e.g. YouTube 403/-1102): resolve afresh once if the app says it helps
        Class<SFApp> app = [SFAppRegistry appForItem:_item];
        if (!_reresolved && [app respondsToSelector:@selector(playbackPrepareReResolve:)] && [app playbackPrepareReResolve:_item]) {
            _reresolved = YES;
            SFLog(@"player: all streams rejected -> resolving afresh");
            SFCount(@"player.re-resolve");
            _mpvFailedURL = nil;
            self.startPaused = self.startPaused || _holdPaused;   // "start paused" survives the re-resolve
            NSTimeInterval pos = [self failurePosition];
            if (pos > 0) self.startPosition = pos; else self.startFromBeginning = YES;
            [self teardownPlayer];
            [self startItem];
            return;
        }
        [self showSpinner:NO];
        _failed = YES;
        SFLog(@"player: failed (%@) %@", _engine.engineName, _engine.error);
        SFCount(@"player.failed");
        [self showMessage:[NSString stringWithFormat:@"Wiedergabe fehlgeschlagen\n%@\n\nOK – zurück", SFFriendlyPlaybackError(_engine.error)]];
        [self postState];
    } else if (_engine.status == SFEngineReady) {
        [self showMessage:@""];   // e.g. "connection interrupted" after a successful fallback
        if (!_subsApplied) { _subsApplied = YES; [self applyPreferredSubtitles]; }
        if (self.startPaused || _holdPaused) { [_engine pause]; self.startPaused = NO; }   // pause during loading / after an update
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
// A session stream that ends or breaks well before the end of the video lost its local source
// (session failed, evicted or gone): fallback instead of "finished" or a dead "connection interrupted"
- (BOOL)sessionCutShort {
    if (![self sessionSource]) return NO;
    double d = [self duration], c = _engine.currentTime;
    return !(d > 0) || c < d - 30;
}
- (void)engineDidEnd {
    // live from an app session: the end of the playlist is either the end of the broadcast or a
    // lost playlist - only the app's service knows
    NSDictionary *src = SFMPVSourceFor(_openURL);
    Class<SFApp> app = [SFAppRegistry appForItem:_item];
    NSURL *opened = _openURL; SFItem *it = _item;
    if ([app respondsToSelector:@selector(playbackLiveEnded:done:)] && [app playbackLiveEnded:src done:^(BOOL ended) {
            if (self->_closing || it != self->_item || ![opened isEqual:self->_openURL]) return;
            if (ended) { SFLog(@"player: live broadcast ended"); [self didEnd:nil]; }
            else [self sessionFailed:@"live playlist ended"];
        }]) return;
    if ([self sessionCutShort]) { [self sessionFailed:@"stream ended early"]; return; }
    [self didEnd:nil];
}
- (void)engineInterrupted { if ([self sessionCutShort]) { [self sessionFailed:@"stream interrupted"]; return; } [self failedToEnd:nil]; }
- (void)engineTick { [self tick]; }

- (void)teardownPlayer {
    _engine.delegate = nil;   // no late callbacks from the old engine
    [_engine shutdown];
    _engine = nil;
}

- (void)teardown {
    if (_powerObs) { [[NSNotificationCenter defaultCenter] removeObserver:_powerObs]; _powerObs = nil; }
    if (_sabrObs) { [[NSNotificationCenter defaultCenter] removeObserver:_sabrObs]; _sabrObs = nil; }
    _closing = YES;
    [_osdTimer invalidate]; [_seekTimer invalidate]; [_nextTimer invalidate];
    [self teardownPlayer];
    [self setAssertion:NO];
}

- (void)setAssertion:(BOOL)on {
    if (on && !_hasAssertion && !SFDevMode) {
        // playback: keep display AND system awake (like caffeinate -d -i used to)
        _hasAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep, kIOPMAssertionLevelOn,
                                                    CFSTR("Sofa playback"), &_assertion) == kIOReturnSuccess;
        if (IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep, kIOPMAssertionLevelOn,
                                        CFSTR("Sofa playback"), &_sysAssertion) != kIOReturnSuccess) _sysAssertion = 0;
    } else if (!on && _hasAssertion) {
        IOPMAssertionRelease(_assertion);
        if (_sysAssertion) { IOPMAssertionRelease(_sysAssertion); _sysAssertion = 0; }
        _hasAssertion = NO;
    }
}
@end
