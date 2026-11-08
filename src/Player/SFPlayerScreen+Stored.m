// SFPlayerScreen - what of the video is on disk, as a shade on the timeline (docs/media-store.md 5c):
// exact ranges - the media proxy's (HLS: its segments' durations), an app's for its sessions (YouTube:
// the tracks' Cues/sidx) - never a guess from byte counts.
// Asked off the main thread while the bar shows, every few seconds (playback keeps filling it).
#import "SFPlayerScreen+Private.h"
#import "SFMediaProxy.h"

static const NSTimeInterval kStoredRefresh = 3;

@implementation SFPlayerScreen (Stored)

- (void)setupStoredShade {
    _barStored = [CALayer layer];
    _barStored.anchorPoint = CGPointZero;
    _barStored.frame = _barBg.bounds;
    [_barBg addSublayer:_barStored];
}

- (void)refreshStoredRanges {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!_servedURL || _item.kind == SFItemLive || now - _storedAsked < kStoredRefresh) return;
    _storedAsked = now;
    NSURL *asked = _servedURL;
    __weak SFPlayerScreen *ws = self;
    void (^got)(NSArray *) = ^(NSArray *ranges) {
        SFPlayerScreen *s = ws;
        if (!s || ![s->_servedURL isEqual:asked] || s->_storedRanges == ranges || [s->_storedRanges isEqual:ranges]) return;
        s->_storedRanges = ranges;
        [s layoutStoredShade];
    };
    // an app's session stream (YouTube) knows its own; a source's file or playlist: the media proxy
    NSDictionary *src = SFMPVSourceFor(_openURL);
    Class<SFApp> app = [SFAppRegistry appForItem:_item];
    if ([app respondsToSelector:@selector(playbackIsSession:)] && [app playbackIsSession:src]) {
        if ([app respondsToSelector:@selector(storedRangesOf:done:)]) [app storedRangesOf:src done:got];
        return;
    }
    [[SFMediaProxy shared] storedRangesFor:asked done:got];
}

- (void)layoutStoredShade {
    NSTimeInterval d = [self duration];
    CGFloat w = _barBg.bounds.size.width, h = _barBg.bounds.size.height;
    CGColorRef c = [NSColor colorWithDeviceWhite:1 alpha:0.3].CGColor;
    NSMutableArray *layers = [NSMutableArray new];
    for (NSArray *r in d > 0 ? _storedRanges : nil) {
        CGFloat x0 = w * MIN(1, [r[0] doubleValue] / d), x1 = w * MIN(1, [r[1] doubleValue] / d);
        if (x1 - x0 < 1) continue;
        CALayer *l = [CALayer layer];
        l.anchorPoint = CGPointZero;
        l.frame = CGRectMake(x0, 0, x1 - x0, h);
        l.backgroundColor = c;
        [layers addObject:l];
    }
    SFNoAnimate(^{ self->_barStored.sublayers = layers; });
    if (_storedRanges) SFLog(@"player: stored %lu range(s), %.0f of %.0f s", (unsigned long)_storedRanges.count, SFRangesSeconds(_storedRanges, d), d);
}

@end
