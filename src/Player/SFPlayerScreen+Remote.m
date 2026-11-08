// SFPlayerScreen - remote control (phone pairing / Lounge): play, pause, seek and the queue the phone sends.
#import "SFPlayerScreen+Private.h"

@implementation SFPlayerScreen (Remote)

- (BOOL)hasNext { return [self nextItem] != nil; }
- (BOOL)hasPrevious { return _explicitQueue && _index > 0; }
- (void)remotePlay { self.startPaused = NO; _holdPaused = NO; if (_engine && !_engine.playing) [self togglePause]; }
- (void)remotePause {
    // pause during loading/retry: remember it so the player starts paused
    if (!_engine || _engine.status != SFEngineReady) { self.startPaused = YES; [_engine pause]; [self postState]; return; }
    if (_engine.playing) [self togglePause];
}
- (void)remoteSeekTo:(NSTimeInterval)t {
    if (!_engine || _item.kind == SFItemLive) return;
    _pendingSeek = 0;
    _seekBase = MAX(0, t); _seekBaseAt = [NSDate date];
    [self leaveEnd];
    [_engine seekTo:t exact:YES];
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
- (void)adoptQueue:(NSArray *)items index:(NSUInteger)i {
    if (!items.count) return;
    _queue = [items copy];
    _explicitQueue = YES;
    _index = MIN(i, items.count - 1);
}

- (void)replaceQueue:(NSArray *)items index:(NSUInteger)i at:(NSTimeInterval)t {
    _queue = [items copy];
    _explicitQueue = YES;
    [self playQueueIndex:i at:t];
}
@end
