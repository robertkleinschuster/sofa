// SFBrowseScreen - hero and backdrop: the large info area and picture of the focused item.
#import "SFBrowseScreen+Private.h"

@implementation SFBrowseScreen (Hero)

#pragma mark Hero / Backdrop

// The backdrop follows the focus in two steps (user 2026-11-07): leaving a tile fades its picture
// out at once; once the focus rests on the next one, that one's picture fades in. They never
// overlap, and fast navigation does not flicker through pictures. Every fade starts where the
// picture is on screen (SFFadeOpacity): moving on mid fade-in, or back mid fade-out, turns the fade
// around instead of jumping; a picture that arrives after the focus left stays hidden (SFImageLayer).
static const NSTimeInterval kBackdropOut = 0.25;

- (void)leaveBackdropFor:(SFItem *)next {
    if (self.overlay) return;
    NSString *src = (next.backdrop ?: next.image) ?: _page.backdrop;
    if ([src isEqualToString:_backdrop.source] || _backdrop.opacity == 0) return;
    SFFadeOpacity(_backdrop, 0, kBackdropOut);
}

- (void)updateBackdropFor:(SFItem *)it {
    if (self.overlay) return;   // the video itself is the backdrop
    NSString *src = it.backdrop ?: _page.backdrop;
    if ([src isEqualToString:_backdrop.source] && _backdropBox.opacity > 0) {
        if (_backdrop.opacity < 1) SFFadeOpacity(_backdrop, 1, 0.3);   // back on the tile it left (also mid fade-out)
        return;
    }
    if (!src.length) { SFAnimate(0.4, ^{ self->_backdropBox.opacity = 0; }); return; }
    _backdrop.fallbackSource = it.backdrop && it.image.length ? it.image : nil;   // big image missing -> the tile image
    SFFadeOpacity(_backdrop, 1, 0);   // empty until the new picture fades in (an old fade-out ends here)
    _backdrop.source = src;
    CGFloat op = self.showsHero ? 0.75 : 0.4;   // more restrained on grid pages
    if (self.theme.light) op *= 0.6;
    SFAnimate(0.5, ^{ self->_backdropBox.opacity = op; });
}

- (void)buildHero:(CGSize)size {
    SFTheme *t = self.theme;
    _hero = [CALayer layer];
    _hero.frame = CGRectMake(0, 0, size.width, U(560));
    _hero.zPosition = 20;
    _heroTitle = [SFLabel labelWithFont:[t bold:58] color:t.text];
    _heroTitle.maxLines = 2;
    _heroMeta = [SFLabel labelWithFont:[t medium:26] color:t.textDim];
    _heroPlot = [SFLabel labelWithFont:[t regular:27] color:t.textDim];
    _heroPlot.maxLines = 3;
    _heroPlot.lineSpacing = U(4);
    for (SFLabel *l in @[_heroTitle, _heroMeta, _heroPlot]) { l.shadow = !t.light; [_hero addSublayer:l]; }
    [self.layer addSublayer:_hero];
}

static const NSTimeInterval kBackdropRest = 0.25;   // after the hero's 0.12 s: 0.37 s after the key

- (void)updateHeroFor:(SFItem *)it {
    NSUInteger seq = ++_heroSeq;
    [self leaveBackdropFor:it];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (seq != self->_heroSeq) return;
        CGFloat w = self.size.width * (self.overlay ? 0.6 : 0.5);
        NSString *title = it.heroTitle ?: it.title ?: self->_page.title;
        NSMutableArray *meta = [NSMutableArray new];
        if (it.channel.length && ![it.channel isEqualToString:it.title]) [meta addObject:it.channel];
        // a live stream's date is when its page was set up - meaningless; its subtitle (what is on now) says more
        if (it.date && it.kind != SFItemLive) [meta addObject:SFFormatDateShort(it.date)];
        if (it.duration > 0) [meta addObject:SFFormatDuration(it.duration)];
        if (!meta.count && it.subtitle.length) [meta addObject:it.subtitle];
        if (it.heroMeta.length) { [meta removeAllObjects]; [meta addObject:it.heroMeta]; }
        // live channel with a programme: what runs now, its time, what comes next, its description
        SFBroadcast *now = it.kind == SFItemLive ? [it broadcastAt:[NSDate date]] : nil;
        NSString *plotText = it.plot;
        if (now) {
            SFBroadcast *next = [it broadcastAfter:now];
            [meta removeAllObjects];
            [meta addObject:now.title];
            [meta addObject:[NSString stringWithFormat:@"%@ – %@", SFFormatClock(now.start), SFFormatClock(now.end)]];
            if (next) [meta addObject:[@"Danach: " stringByAppendingString:next.title]];
            plotText = now.plot.length ? now.plot : now.subtitle.length ? now.subtitle : it.plot;
        }
        NSString *metaText = [meta componentsJoinedByString:@"  ·  "];
        NSString *plot = [plotText stringByReplacingOccurrencesOfString:@"\n" withString:@" "] ?: @"";
        SFLabel *tl = self->_heroTitle, *ml = self->_heroMeta, *pl = self->_heroPlot;
        SFLabelLook *titleLook = [tl lookForText:title maxLines:tl.maxLines width:w];
        SFLabelLook *metaLook = [ml lookForText:metaText maxLines:ml.maxLines width:w];
        CGFloat h1 = titleLook.size.height, h2 = metaLook.size.height;
        // fit the plot lines to the space available down to the shelves
        CGFloat y = self.overlay ? U(120) : U(190);   // overlay: no logo row above
        CGFloat avail = self->_contentTop - U(40) - (y + h1 + h2 + U(26));
        // first line incl. descender/shadow padding, each further line only its line height
        CGFloat lh = [pl heightForText:plot maxLines:1 width:w];
        CGFloat step = MAX(1, [pl heightForText:plot maxLines:2 width:w] - lh);
        NSInteger fit = avail < lh ? 0 : 1 + (NSInteger)floor((avail - lh) / step);
        NSInteger lines = MAX(0, MIN(self.heroPlotLines > 0 ? self.heroPlotLines : 3, fit));
        SFLabelLook *plotLook = [pl lookForText:plot maxLines:MAX(1, lines) width:w];
        NSString *before = [NSString stringWithFormat:@"%@|%@|%@", tl.text, ml.text, pl.text];
        NSString *after = [NSString stringWithFormat:@"%@|%@|%@", title, metaText, plot];
        // Drawn off the main thread; text, sizes and pictures change together once drawn. A slow
        // draw (colour emoji at hero size) must not leave the last item's text up meanwhile: past
        // 0.1 s the old text fades out and the new one fades in when it is ready.
        __block BOOL applied = NO, faded = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (applied || seq != self->_heroSeq || [before isEqualToString:after]) return;
            faded = YES;
            SFFadeOpacity(self->_hero, 0, 0.15);
        });
        [SFLabelLook render:@[titleLook, metaLook, plotLook] done:^{
            applied = YES;
            if (seq != self->_heroSeq) { if (faded) SFFadeOpacity(self->_hero, 1, 0.2); return; }   // a newer step shows its own
            SFNoAnimate(^{
                [tl applyLook:titleLook];
                [ml applyLook:metaLook];
                [pl applyLook:plotLook];
                pl.hidden = lines == 0;
                tl.position = CGPointMake(U(96), y);
                ml.position = CGPointMake(U(96), y + h1 + U(10));
                pl.position = CGPointMake(U(96), y + h1 + h2 + U(26));
            });
            // fades only when it says something new: a page rebuilt with more data keeps its hero still
            if (faded) SFFadeOpacity(self->_hero, 1, 0.2);
            else if (![before isEqualToString:after]) {
                CATransition *tr = [CATransition animation];
                tr.type = kCATransitionFade; tr.duration = 0.25;
                [self->_hero addAnimation:tr forKey:@"fade"];
            }
        }];
        // the big picture of the focused item (every app's backdrop is the TV-sized version of the
        // same picture), else its tile picture; the tile picture also stands in when the big one
        // fails to load (YouTube: old videos have no maxres version)
        SFItem *b = nil;
        if (it.backdrop.length || it.image.length) { b = [SFItem new]; b.backdrop = it.backdrop ?: it.image; b.image = it.image; }
        // load it meanwhile (decoded into the shared cache): at rest it fades in at once, not after a download
        if (b.backdrop.length && !self.overlay) {
            CGFloat px = MAX(self->_backdrop.bounds.size.width, self->_backdrop.bounds.size.height) * self->_backdrop.contentsScale;
            [[SFImageCache shared] imageForSource:b.backdrop maxPixel:px < 1 ? 512 : px blurred:self->_backdrop.blurred completion:^(CGImageRef img) {}];
        }
        // the next picture comes once the focus rests, after the scroll animation (0.34 s): fast
        // navigation starts no load and no fade per step
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBackdropRest * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (seq == self->_heroSeq) [self updateBackdropFor:b];
        });
    });
}
@end
