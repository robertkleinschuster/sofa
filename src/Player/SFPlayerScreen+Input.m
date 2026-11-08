// SFPlayerScreen - remote keys: seeking (collected, committed after a pause), volume, info panel, back.
#import "SFPlayerScreen+Private.h"

@implementation SFPlayerScreen (Input)

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
    [self leaveEnd];
    [_engine seekTo:target exact:YES];
    [self showOSD:YES autoHide:YES];
}

#pragma mark Input

- (BOOL)handleKey:(SFKey)key {
    if (_nextTimer) {
        if (key == SFKeySelect || key == SFKeyPlayPause) { [self playNext]; return YES; }
        if (key == SFKeyMenu) { [_nextTimer invalidate]; _nextTimer = nil; [self.navigator pop]; return YES; }
    }
    if ([self esHandleKey:key]) return YES;   // end screen tiles (only DOWN enters them)
    switch (key) {
        case SFKeyPlayPause: [self togglePause]; return YES;
        case SFKeySelect:
            if (_failed) { [self.navigator pop]; return YES; }
            if (!_osdVisible) [self showOSD:YES autoHide:YES];
            else [self togglePause];
            return YES;
        case SFKeySelectHold:   // info panel: description, channel, follow, audio/subtitles, up next
            [self showInfo];
            return YES;
        case SFKeyLeft: [self seekBy:-10]; return YES;
        case SFKeyRight: [self seekBy:30]; return YES;
        case SFKeyPrev: [self seekBy:-120]; return YES;
        case SFKeyNext: [self seekBy:120]; return YES;
        // up/down (+/- on the remote ring) = system volume, holding repeats
        case SFKeyUp: case SFKeyUpHold: _lastVolumeAt = [NSDate date]; [self.navigator volumeStep:+1]; return YES;
        case SFKeyDown: case SFKeyDownHold: _lastVolumeAt = [NSDate date]; [self.navigator volumeStep:-1]; return YES;
        case SFKeyMenu:
            if (_pendingSeek != 0) { _pendingSeek = 0; [_seekTimer invalidate]; [self updateBar]; return YES; }
            [self saveProgress];
            _closing = YES;
            return NO;   // navigator: back
        default: return NO;
    }
}
@end
