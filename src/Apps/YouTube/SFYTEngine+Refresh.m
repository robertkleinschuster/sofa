// Replacing the YouTube document: periodically while idle, and at once when stream protection refuses
// its token. Session and in-flight-call checks of the idle refresh live in the page.
#import "SFYTEngine+Private.h"
#import "SFModel.h"
#import "SFPlayerScreen.h"
#import "SFStats.h"

static const NSTimeInterval kLaunchTimeout = 90;   // same readiness deadline as a browser start
// An open player blocks the age refresh only while it plays or was paused for less than this. A
// player left paused (screen off, 2026-11-22) blocked it for 22 h; the document reached two days
// and stream protection refused it. A longer pause loses nothing: the player reopens on play.
static const NSTimeInterval kViewerPauseYields = 30 * 60;
// A stale document is replaced at most this often: each new document is a new BotGuard attestation
// (as kUnresponsiveRestartGap). Should a fresh one be refused too, it is not a reload loop.
static const NSTimeInterval kStaleRefreshGap = 15 * 60;

@implementation SFYTEngine (Refresh)

- (BOOL)viewerBlocksRefresh {
    SFPlayerScreen *v = _viewer;
    if (!v) return NO;
    if (![v isPaused] || !_viewerPausedAt) return YES;
    return -[_viewerPausedAt timeIntervalSinceNow] < SFDevSeconds(@"SOFA_ENGINE_VIEWER_PAUSE_YIELDS", kViewerPauseYields);
}

- (void)refreshIdlePage {
    if (_state != SFYTEngineReady || [self viewerBlocksRefresh]) return;
    [self replacePage:NO why:@"refreshing idle youtube.com page after 6 hours"];
}

// Stream protection refused the document's token (SPS 3). Every refusal so far (2026-11-20,
// 2026-11-23: 11 minutes of stalls at 60 s) came from a document open for days, and renewing the
// minter in it never helped, while a fresh document was accepted at once: replace it now - also
// under a playing viewer, whose stream is already doomed; the player reopens at its position.
- (void)tokenRejected:(NSString *)videoId {
    if (_state != SFYTEngineReady) return;   // a replacement is already under way
    NSTimeInterval gap = SFDevSeconds(@"SOFA_ENGINE_STALE_REFRESH_GAP", kStaleRefreshGap);
    if (_staleRefreshAt && -[_staleRefreshAt timeIntervalSinceNow] < gap) {
        SFLog(@"yt-engine: token for %@ refused again within %.0f s of a fresh document - not replacing it again",
              videoId ?: @"?", gap);
        SFCount(@"yt-engine.token-refused-fresh");
        return;
    }
    _staleRefreshAt = [NSDate date];
    SFCount(@"yt-engine.stale-refresh");
    [self replacePage:YES why:[NSString stringWithFormat:@"stream protection refused the token for %@ - replacing the youtube.com page",
                                                         videoId ?: @"?"]];
}

// Queue new callers before asking the page to reload. Unforced, the page checks again atomically: a
// player could have opened a session since health(), or an open/page request may still be in flight.
// Forced, the reload goes ahead: its sessions and calls end through the normal reload path.
- (void)replacePage:(BOOL)force why:(NSString *)why {
    NSUInteger run = _run, page = _page;
    [self setState:SFYTEngineStarting];
    _refreshPending = YES;
    [self request:@"refresh" args:@[@(force)] timeout:5 done:^(id v, NSError *e) { SFMain(^{
        if (run != self->_run || page != self->_page || self->_state != SFYTEngineStarting) return;
        if (e || ![v boolValue]) {
            if (force) SFLog(@"yt-engine: the page refused to reload (%@)", e.localizedDescription ?: @"busy");
            self->_refreshPending = NO;
            [self setState:SFYTEngineReady];
            [self tellWaiting:YES];
        } else SFLog(@"yt-engine: %@", why);
    }); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLaunchTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (run == self->_run && page == self->_page && self->_state == SFYTEngineStarting)
            [self runFailed:@"refreshed page not ready in time"];
    });
}

- (void)refreshPlayerChanged:(NSNotification *)n {
    SFPlayerScreen *p = n.object;
    if ([n.userInfo[@"closed"] boolValue]) { if (_viewer == p) { _viewer = nil; _viewerPausedAt = nil; } return; }
    if (_viewer != p) _viewerPausedAt = nil;
    _viewer = p;
    if (![p isPaused]) _viewerPausedAt = nil;
    else if (!_viewerPausedAt) _viewerPausedAt = [NSDate date];
}

@end
