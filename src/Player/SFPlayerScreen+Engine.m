// SFPlayerScreen - engine events: status, buffering, end and interruption, recovery of failed streams, teardown.
#import "SFPlayerScreen+Private.h"
#import "SFStats.h"
#import "SFPrebuffer.h"
#import "SFMPVEngine.h"
#import "SFMediaProxy.h"
#import "SFApp.h"
#import <IOKit/pwr_mgt/IOPMLib.h>

@implementation SFPlayerScreen (Engine)

#pragma mark SFEngineDelegate

// Error text for the TV: Sofa's own messages (stall watchdog, ...) as they are; mpv's technical
// ones ("mpv: loading failed") as a sentence a viewer understands
static NSString *SFFriendlyPlaybackError(NSError *e) {
    NSString *m = e.localizedDescription;
    return m.length && ![m hasPrefix:@"mpv:"] ? m : nil;   // nil: failWith:'s general sentence
}

// Where to continue after a failure: aborted midway -> there, otherwise at the start point
- (NSTimeInterval)failurePosition {
    return MAX(_openResume, _engine.currentTime > 5 ? _engine.currentTime : 0);
}

// The opened stream comes from an app session (e.g. YouTube SABR via its engine)?
- (BOOL)sessionSource {
    Class<SFApp> app = [SFAppRegistry appForItem:_item];
    return [app respondsToSelector:@selector(playbackIsSession:)] && [app playbackIsSession:SFMPVSourceFor(_openURL)];
}

// A stream broke after its playback began (any source), or a session stream failed at all: reopen
// the item at the same position - as long as each reopen played at least a minute; a stream that
// breaks again right away ends in a message instead of a loop of reopens. A session stream's app
// recovers its side first (fresh session); the chosen audio/subtitle tracks carry over.
static const NSTimeInterval kReopenMinPlay = 60;
- (void)streamFailed:(NSString *)why {
    NSTimeInterval pos = [self failurePosition];
    if (_reopenedAt >= 0 && pos < _reopenedAt + kReopenMinPlay) {
        SFLog(@"player: failed - the stream broke again right after reopening (%@)", why);
        SFCount(@"player.reopen-failed");
        [self failWith:@"Der Stream ist wiederholt abgebrochen."];
        return;
    }
    SFLog(@"player: stream failed (%@) - reopening at %.0f s", why, pos);
    if ([self sessionSource]) {
        Class<SFApp> app = [SFAppRegistry appForItem:_item];
        if ([app respondsToSelector:@selector(playbackSessionFailed:item:reason:)])
            [app playbackSessionFailed:SFMPVSourceFor(_openURL) item:_item reason:why];
    }
    _reopenedAt = MAX(0, pos);
    _carryTracks = [self chosenTracks];
    self.startPaused = self.startPaused || _holdPaused;
    if (pos > 0) self.startPosition = pos; else self.startFromBeginning = YES;
    [self teardownPlayer];
    [self startItem];
}

- (void)devBreakStream { if (_engine && !_failed && !_closing) [self streamFailed:@"dev: broken on request"]; }

- (void)engineStatusChanged {
    if (_engine.status == SFEngineFailed) {
        if (SFDevMode) {   // make the cause traceable (domain/code/underlying error)
            NSError *e = _engine.error, *u = e.userInfo[NSUnderlyingErrorKey];
            SFLog(@"player: error %@ %ld %@ | underlying %@ %ld | %@", e.domain, (long)e.code, e.localizedFailureReason ?: @"",
                  u.domain, (long)u.code, e.userInfo[NSLocalizedRecoverySuggestionErrorKey] ?: @"");
        }
        // a session stream (app service) failed, any stream after its playback began (stall
        // watchdog), or the open of a reopen: streamFailed: reopens - or ends a repeat in a message
        if ([self sessionSource] || _engine.started || _reopenedAt >= 0) { [self streamFailed:_engine.error.localizedDescription]; return; }
        SFLog(@"player: failed (%@) %@", _engine.engineName, _engine.error);
        SFCount(@"player.failed");
        [self failWith:SFFriendlyPlaybackError(_engine.error)];
    } else if (_engine.status == SFEngineReady) {
        [self showMessage:@""];   // e.g. "connection interrupted" after a successful fallback
        if (_carryTracks) { [self restoreTracks:_carryTracks]; _carryTracks = nil; }   // a reopen: the tracks chosen before
        else if (!_subsApplied) { _subsApplied = YES; [self applyPreferredSubtitles]; }
        if (self.startPaused || _holdPaused) { [_engine pause]; self.startPaused = NO; }   // pause during loading / after an update
        [self postState];
        if (_item.duration <= 0 && _engine.duration > 0) _item.duration = _engine.duration;
        [self updatePauseState];
    }
}
- (void)engineRateChanged { [self updatePauseState]; }
- (void)engineBufferingChanged {
    [self showSpinner:[self awaitingPicture]];
    [self postState];
}
// The position is in the last 30 s of a known length: an error there is as good as the end
- (BOOL)nearEnd {
    double d = [self duration];
    return d > 0 && _engine.currentTime >= d - 30;
}
// An "end" well before the end of the video lost its source (a session failed, evicted or gone; a
// server that closed the connection): reopen instead of "finished". Unknown length (live, ...): only a
// session source knows it was cut.
- (BOOL)endedEarly { return [self duration] > 0 ? ![self nearEnd] : [self sessionSource]; }
- (void)engineDidEnd {
    // live from an app session: the end of the playlist is either the end of the broadcast or a
    // lost playlist - only the app's service knows
    NSDictionary *src = SFMPVSourceFor(_openURL);
    Class<SFApp> app = [SFAppRegistry appForItem:_item];
    NSURL *opened = _openURL; SFItem *it = _item;
    if ([app respondsToSelector:@selector(playbackLiveEnded:done:)] && [app playbackLiveEnded:src done:^(BOOL ended) {
            if (self->_closing || it != self->_item || ![opened isEqual:self->_openURL]) return;
            if (ended) { SFLog(@"player: live broadcast ended"); [self didEnd:nil]; }
            else [self streamFailed:@"live playlist ended"];
        }]) return;
    if ([self endedEarly]) { [self streamFailed:@"stream ended early"]; return; }
    [self didEnd:nil];
}
- (void)engineInterrupted { if ([self nearEnd]) [self didEnd:nil]; else [self streamFailed:@"stream interrupted"]; }
- (void)engineTick { [self tick]; }

- (void)teardownPlayer {
    _engine.delegate = nil;   // no late callbacks from the old engine
    [_engine shutdown];
    [[SFMediaProxy shared] releaseURL:_servedURL];
    _servedURL=nil;
    _engine = nil;
}

- (void)teardown {
    [[SFPrebuffer shared] leave:self];
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
