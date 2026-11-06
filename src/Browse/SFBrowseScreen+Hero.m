// SFBrowseScreen - hero and backdrop: the large info area and picture of the focused item.
#import "SFBrowseScreen+Private.h"

@implementation SFBrowseScreen (Hero)

#pragma mark Hero / Backdrop

- (void)updateBackdropFor:(SFItem *)it {
    if (self.overlay) return;   // the video itself is the backdrop
    NSString *src = it.backdrop ?: _page.backdrop;
    if ([src isEqualToString:_backdrop.source] && _backdropBox.opacity > 0) return;
    if (!src.length) { SFAnimate(0.4, ^{ self->_backdropBox.opacity = 0; }); return; }
    _backdrop.fallbackSource = it.backdrop && it.image.length ? it.image : nil;   // big image missing -> the tile image
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

- (void)updateHeroFor:(SFItem *)it {
    NSUInteger seq = ++_heroSeq;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (seq != self->_heroSeq) return;
        CGFloat w = self.size.width * (self.overlay ? 0.6 : 0.5);
        SFNoAnimate(^{
            self->_heroTitle.text = it.heroTitle ?: it.title ?: self->_page.title;
            CGFloat h1 = [self->_heroTitle sizeToFitWidth:w];
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
            self->_heroMeta.text = [meta componentsJoinedByString:@"  ·  "];
            CGFloat h2 = [self->_heroMeta sizeToFitWidth:w];
            NSString *plot = [plotText stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            self->_heroPlot.text = plot;
            // fit the plot lines to the space available down to the shelves
            CGFloat y = self.overlay ? U(120) : U(190);   // overlay: no logo row above
            CGFloat avail = self->_contentTop - U(40) - (y + h1 + h2 + U(26));
            // first line incl. descender/shadow padding, each further line only its line height
            self->_heroPlot.maxLines = 1;
            CGFloat lh = [self->_heroPlot sizeToFitWidth:w];
            self->_heroPlot.maxLines = 2;
            CGFloat step = MAX(1, [self->_heroPlot sizeToFitWidth:w] - lh);
            NSInteger fit = avail < lh ? 0 : 1 + (NSInteger)floor((avail - lh) / step);
            NSInteger lines = MAX(0, MIN(self.heroPlotLines > 0 ? self.heroPlotLines : 3, fit));
            self->_heroPlot.hidden = lines == 0;
            self->_heroPlot.maxLines = MAX(1, lines);
            [self->_heroPlot sizeToFitWidth:w];
            self->_heroTitle.position = CGPointMake(U(96), y);
            self->_heroMeta.position = CGPointMake(U(96), y + h1 + U(10));
            self->_heroPlot.position = CGPointMake(U(96), y + h1 + h2 + U(26));
        });
        CATransition *tr = [CATransition animation];
        tr.type = kCATransitionFade; tr.duration = 0.25;
        [self->_hero addAnimation:tr forKey:@"fade"];
        // the big picture of the focused item (every app's backdrop is the TV-sized version of the
        // same picture), else its tile picture; the tile picture also stands in when the big one
        // fails to load (YouTube: old videos have no maxres version)
        SFItem *b = nil;
        if (it.backdrop.length || it.image.length) { b = [SFItem new]; b.backdrop = it.backdrop ?: it.image; b.image = it.image; }
        [self updateBackdropFor:b];
    });
}
@end
