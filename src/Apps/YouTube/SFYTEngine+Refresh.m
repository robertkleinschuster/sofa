// Periodic refresh of the idle YouTube document; session and in-flight-call checks live in the page.
#import "SFYTEngine+Private.h"
#import "SFModel.h"
#import "SFPlayerScreen.h"

static const NSTimeInterval kLaunchTimeout = 90;   // same readiness deadline as a browser start

@implementation SFYTEngine (Refresh)

// Queue new callers before asking the page to reload. The page checks again atomically: a player
// could have opened a session since health(), or an open/page request may still be in flight.
- (void)refreshIdlePage {
    if (_state != SFYTEngineReady || _viewer) return;
    NSUInteger run = _run, page = _page;
    [self setState:SFYTEngineStarting];
    _refreshPending = YES;
    [self request:@"refresh" args:@[] timeout:5 done:^(id v, NSError *e) { SFMain(^{
        if (run != self->_run || page != self->_page || self->_state != SFYTEngineStarting) return;
        if (e || ![v boolValue]) {
            self->_refreshPending = NO;
            [self setState:SFYTEngineReady];
            [self tellWaiting:YES];
        } else SFLog(@"yt-engine: refreshing idle youtube.com page after 6 hours");
    }); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLaunchTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (run == self->_run && page == self->_page && self->_state == SFYTEngineStarting)
            [self runFailed:@"refreshed page not ready in time"];
    });
}

- (void)refreshPlayerChanged:(NSNotification *)n {
    if ([n.userInfo[@"closed"] boolValue]) { if (_viewer == n.object) _viewer = nil; }
    else _viewer = n.object;
}

@end
