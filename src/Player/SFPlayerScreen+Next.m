// SFPlayerScreen - end of a video and what comes next: queue, next episode, recommendation, the "up next" card.
#import "SFPlayerScreen+Private.h"
#import "SFPlayerInfoScreen.h"

@implementation SFPlayerScreen (Next)

#pragma mark End / Next

// Next episode = the next newer episode of the same local show (episodes are sorted
// newest first). Mixed rows (new episodes, continue watching) thus never jump
// into a different show.
// Index of the next playable queue entry after _index (DRM entries are skipped: they can never
// play on this Mac, so autoplay must not run into an error screen), NSNotFound if none.
- (NSUInteger)nextQueueIndex {
    for (NSUInteger k = _index + 1; k < _queue.count; k++) if (![_queue[k] drm]) return k;
    return NSNotFound;
}

- (SFItem *)nextItem {
    NSUInteger q = [self nextQueueIndex];
    if (_explicitQueue) return q != NSNotFound ? _queue[q] : nil;
    // Started from a playlist: next video of the playlist (before recommendations)
    if (_item.playlistID.length && q != NSNotFound && [[_queue[q] playlistID] isEqualToString:_item.playlistID]) return _queue[q];
    SFItem *up = _upNext.drm ? nil : _upNext;
    if (!_item.localPath || !_item.channel) return up;        // streamed YouTube: recommendation
    SFShow *show = [[SFLibrary shared] showNamed:_item.channel source:_item.source];
    NSUInteger i = NSNotFound;
    for (NSUInteger k = 0; k < show.episodes.count; k++)
        if ([[show.episodes[k] localPath] isEqualToString:_item.localPath]) { i = k; break; }
    if (i == NSNotFound || i == 0) return up;                 // last downloaded episode: recommendation
    return show.episodes[i - 1];
}

- (void)didEnd:(NSNotification *)n {
    _ended = YES;
    [self updatePauseState];   // at the end no pause icon over the "up next" card
    [self postState];
    [self saveProgress];
    [self setAssertion:NO];
    // choosing among the end screen tiles: don't pull the video away under them; the end flow
    // runs when they leave the tiles (SFPlayerScreen+Endscreen.m)
    if ([self esEngaged]) { _esEndDeferred = YES; SFLog(@"player: ended while in the end screen - waiting"); return; }
    [self esUpdate];   // the "up next" card takes over from the tiles
    [self finishEnd];
}

// The app's "up next" recommendation decides what follows: autoplay without a phone queue and
// without a playlist that goes on
- (BOOL)wantsUpNext {
    BOOL playlistGoesOn = _item.playlistID.length && _index + 1 < _queue.count && [[_queue[_index + 1] playlistID] isEqualToString:_item.playlistID];
    return !_explicitQueue && !playlistGoesOn && [[SFAppRegistry appForItem:_item] respondsToSelector:@selector(upNextForItem:done:)];
}

// Fetch it once per video (from half time, or at the end if no tick got there: a jump to the end)
- (void)askUpNext {
    if (_upNextAsked || ![self wantsUpNext]) return;
    _upNextAsked = YES; _upNextPending = YES;
    SFItem *forItem = _item;
    [[SFAppRegistry appForItem:_item] upNextForItem:_item done:^(SFItem *next) {
        if (forItem != self->_item) return;
        self->_upNext = next; self->_upNextPending = NO;
        if (self->_endWaitsForUpNext) { self->_endWaitsForUpNext = NO; [self finishEnd]; }
    }];
}

- (void)forgetUpNext { _upNext = nil; _upNextAsked = NO; _upNextPending = NO; _endWaitsForUpNext = NO; }

// How long the end waits for a recommendation still on its way, before it leaves without one
static const NSTimeInterval kUpNextWait = 4;

- (void)finishEnd {
    _esEndDeferred = NO;
    SFItem *next = [self nextItem];
    if (!next && [self wantsUpNext] && !_endWaitsForUpNext) {
        [self askUpNext];
        if (_upNextPending) {
            _endWaitsForUpNext = YES;
            SFLog(@"player: end waits for the recommendation");
            SFItem *it = _item;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kUpNextWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!self->_endWaitsForUpNext || it != self->_item || !self->_ended || self->_closing) return;
                self->_endWaitsForUpNext = NO; self->_upNextPending = NO;   // a late answer no longer starts anything
                SFLog(@"player: no recommendation after %.0f s", kUpNextWait);
                [self finishEnd];
            });
            return;
        }
    }
    if (_endWaitsForUpNext) return;   // still waiting (a second end signal, e.g. leaving the end screen)
    SFLog(@"player: end -> %@", next ? [@"up next: " stringByAppendingString:next.title ?: @"?"] : @"leaving");
    if (!next) {
        if (self.navigator.top == self) [self.navigator pop];   // else: an overlay is open, see didAppear
        return;
    }
    [self showNextCard:next];
}

// "Als Nächstes" / "Nächste Folge": card like YouTube's - thumbnail on the left, countdown on the right,
// title, channel and remote hint; above the progress bar so time and bar stay visible.
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
        CGFloat h2 = sub.text.length ? [sub sizeToFitWidth:w] : 0; sub.position = CGPointMake(x, y); y += h2;
        // the hint sits at the bottom; the card grows when the text above would reach it (a two-line
        // title plus channel used to overlap the hint)
        CGFloat hh = [hint sizeToFitWidth:w], cardH = MAX(ch, y + U(14) + hh + pad);
        hint.position = CGPointMake(x, cardH - pad - hh);
        self->_nextCard.frame = CGRectMake(self.size.width - U(110) - cw, self.size.height - U(190) - cardH, cw, cardH);
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

// Play another item in this player (info panel: recommendation, other episode) - like autoplay
- (void)playItem:(SFItem *)item {
    if (!item || _closing) return;
    [_nextTimer invalidate]; _nextTimer = nil; _nextCard.hidden = YES;
    [self saveProgress];
    [self teardownPlayer];
    _ended = NO;
    NSUInteger q = [_queue indexOfObjectIdenticalTo:item];
    if (q != NSNotFound) _index = q;
    _item = item;
    _lastSaved = 0;
    [self forgetUpNext];
    [self startItem];
}

- (BOOL)hasExplicitQueue { return _explicitQueue; }

- (void)showInfo {
    [self showOSD:NO autoHide:NO];
    [self.navigator push:[[SFPlayerInfoScreen alloc] initWithPlayer:self]];
}

- (void)playNext {
    [_nextTimer invalidate]; _nextTimer = nil;
    _nextCard.hidden = YES;
    SFItem *next = [self nextItem];
    if (!next) return;
    [self saveProgress];
    [self teardownPlayer];      // release the old player before _item changes
    _ended = NO;
    NSUInteger q = [_queue indexOfObjectIdenticalTo:next];
    if (q != NSNotFound) _index = q;            // may jump over skipped DRM entries
    else if (!_explicitQueue) _index++;
    _item = next;
    _lastSaved = 0;
    [self forgetUpNext];
    [self startItem];
}
@end
