// SFPlayerScreen - engine events: status, buffering, end and interruption, recovery of failed streams, teardown.
#import "SFPlayerScreen+Private.h"
#import "SFStats.h"
#import "SFMPVEngine.h"
#import "SFApp.h"
#import <IOKit/pwr_mgt/IOPMLib.h>

@implementation SFPlayerScreen (Engine)

#pragma mark SFEngineDelegate

// Error text for the TV: Sofa's own messages (stall watchdog, ...) as they are; mpv's technical
// ones ("mpv: loading failed") as a sentence a viewer understands
static NSString *SFFriendlyPlaybackError(NSError *e) {
    NSString *m = e.localizedDescription;
    if (m.length && ![m hasPrefix:@"mpv:"]) return m;
    return @"Das Video ließ sich nicht laden – bitte später noch einmal versuchen.";
}

// Where to continue after a failure: aborted midway -> there, otherwise at the start point
- (NSTimeInterval)failurePosition {
    return MAX(_openResume, _engine.currentTime > 5 ? _engine.currentTime : 0);
}

// The opened stream comes from an app session (e.g. YouTube SABR via the sidecar)?
- (BOOL)sessionSource {
    Class<SFApp> app = [SFAppRegistry appForItem:_item];
    return [app respondsToSelector:@selector(playbackIsSession:)] && [app playbackIsSession:SFMPVSourceFor(_openURL)];
}

// A session stream broke: the app recovers its side (fresh session), the player reopens the item at
// the same position - as long as each reopen played at least a minute; a stream that breaks again
// right away ends in a message instead of a loop of reopens.
static const NSTimeInterval kSessionReopenMinPlay = 60;
- (void)sessionFailed:(NSString *)why {
    NSTimeInterval pos = [self failurePosition];
    if (_sessionReopenedAt >= 0 && pos < _sessionReopenedAt + kSessionReopenMinPlay) {
        [self showSpinner:NO];
        _failed = YES;
        SFLog(@"player: session stream failed again right after reopening (%@)", why);
        SFCount(@"player.session-failed");
        [self showMessage:@"Wiedergabe fehlgeschlagen\nDer Stream ist wiederholt abgebrochen.\n\nOK – zurück"];
        [self postState];
        return;
    }
    Class<SFApp> app = [SFAppRegistry appForItem:_item];
    if ([app respondsToSelector:@selector(playbackSessionFailed:item:reason:)])
        [app playbackSessionFailed:SFMPVSourceFor(_openURL) item:_item reason:why];
    _sessionReopenedAt = MAX(0, pos);
    self.startPaused = self.startPaused || _holdPaused;
    if (pos > 0) self.startPosition = pos; else self.startFromBeginning = YES;
    [self teardownPlayer];
    [self startItem];
}

- (void)engineStatusChanged {
    if (_engine.status == SFEngineFailed) {
        if (SFDevMode) {   // make the cause traceable (domain/code/underlying error)
            NSError *e = _engine.error, *u = e.userInfo[NSUnderlyingErrorKey];
            SFLog(@"player: error %@ %ld %@ | underlying %@ %ld | %@", e.domain, (long)e.code, e.localizedFailureReason ?: @"",
                  u.domain, (long)u.code, e.userInfo[NSLocalizedRecoverySuggestionErrorKey] ?: @"");
        }
        // a session stream (app service) failed: the app's recovery first (see sessionFailed:)
        if ([self sessionSource]) { [self sessionFailed:_engine.error.localizedDescription]; return; }
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
