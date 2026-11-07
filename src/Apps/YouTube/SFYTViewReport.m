#import "SFYTViewReport.h"
#import "SFYTEngine.h"
#import "SFPlayerScreen.h"
#import "SFScreen.h"
#import "SFJSON.h"

// while playing, the position again this often: the engine extrapolates in between, this keeps it
// exact (mpv's clock vs the page's)
static const NSTimeInterval kResync = 10;

@implementation SFYTViewReport {
    __weak SFPlayerScreen *_player;
    NSString *_sid;          // the engine session of the running view
    NSString *_lastState;
    NSTimeInterval _lastPos, _lastSentAt;
    NSTimer *_resync;
}

+ (SFYTViewReport *)shared {
    static SFYTViewReport *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SFYTViewReport new]; });
    return s;
}

+ (void)start {
    SFYTViewReport *r = [self shared];
    [[NSNotificationCenter defaultCenter] removeObserver:r name:SFPlayerStateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:r selector:@selector(playerChanged:) name:SFPlayerStateNotification object:nil];
}

// A VOD streamed by an engine session: its sid; anything else (local file, live, other app): nil.
static NSString *SessionOf(SFPlayerScreen *p) {
    NSDictionary *src = p.playbackSource;
    if (![src[@"sabr"] boolValue] || [src[@"hls"] boolValue]) return nil;
    NSString *sid = str(src[@"sid"]);
    return sid.length ? sid : nil;
}

static NSString *StateName(SFPlaybackState s) {
    switch (s) {
        case SFPlaybackPlaying: return @"playing";
        case SFPlaybackPaused: return @"paused";
        case SFPlaybackBuffering: return @"buffering";
        case SFPlaybackEnded: return @"ended";
        default: return nil;
    }
}

- (void)playerChanged:(NSNotification *)n {
    SFPlayerScreen *p = n.object;
    if (![p isKindOfClass:[SFPlayerScreen class]]) return;
    if ([n.userInfo[@"closed"] boolValue]) { if (p == _player) [self endView]; return; }
    NSString *sid = SessionOf(p);
    if (p != _player || ![sid isEqualToString:_sid ?: @""]) {
        [self endView];   // another video / a reopened session: the earlier view is over
        if (!sid) return;
        _player = p; _sid = sid;
    }
    [self send:NO];
}

- (void)send:(BOOL)resync {
    SFPlayerScreen *p = _player;
    if (!p || !_sid) return;
    NSString *state = StateName(p.playbackState);
    if (!state) return;
    NSTimeInterval pos = p.currentTime, now = [NSDate timeIntervalSinceReferenceDate];
    // the same state at the expected position is no news (state notifications come in bursts)
    BOOL same = [state isEqualToString:_lastState] && fabs(pos - (_lastPos + ([state isEqualToString:@"playing"] ? now - _lastSentAt : 0))) < 1;
    if (same && !resync) return;
    _lastState = state; _lastPos = pos; _lastSentAt = now;
    NSMutableDictionary *st = [@{@"state": state, @"position": @(MAX(0, pos))} mutableCopy];
    NSTimeInterval key = p.navigator.lastInput;
    if (key > 0) st[@"lactMs"] = @((long long)MAX(0, (now - key) * 1000));
    [[SFYTEngine shared] report:_sid state:st];
    BOOL playing = [state isEqualToString:@"playing"];
    if (playing && !_resync) _resync = [NSTimer scheduledTimerWithTimeInterval:kResync target:self selector:@selector(resyncTick) userInfo:nil repeats:YES];
    if (!playing) { [_resync invalidate]; _resync = nil; }
}

- (void)resyncTick { [self send:YES]; }

- (void)endView {
    [_resync invalidate]; _resync = nil;
    if (_sid) [[SFYTEngine shared] report:_sid state:@{@"state": @"closed"}];
    _sid = nil; _player = nil; _lastState = nil;
}

@end
