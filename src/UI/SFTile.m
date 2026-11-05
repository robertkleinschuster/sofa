#import "SFTile.h"
#import "SFDownloads.h"
#import "SFStore.h"
#import "SFLogo.h"

SFTileMetrics SFMetricsForStyle(SFTileStyle st) {
    switch (st) {
        case SFTileStyleCircle:   return (SFTileMetrics){200, 200, 64, 52};
        case SFTileStylePoster:   return (SFTileMetrics){240, 360, 64, 36};
        case SFTileStyleApp:      return (SFTileMetrics){320, 192, 0, 40};
        case SFTileStyleWide:     return (SFTileMetrics){560, 315, 0, 40};
        case SFTileStyleButton:   return (SFTileMetrics){340, 76, 0, 24};
        case SFTileStyleLandscape:
        default:                  return (SFTileMetrics){384, 216, 112, 36};
    }
}

CGFloat SFButtonTileWidth(SFItem *item, SFTheme *theme, CGFloat minWidth) {
    CGFloat tw = item.title.length ? ceil([item.title sizeWithAttributes:@{NSFontAttributeName: [theme bold:26]}].width) : 0;
    if (minWidth <= 0) minWidth = U(SFMetricsForStyle(SFTileStyleButton).width);
    return MIN(U(760), MAX(minWidth, tw + U(36) + U(48)));
}

@implementation SFTileLayer {
    SFTileStyle _style;
    SFTheme *_theme;
    SFImageLayer *_image;
    CALayer *_ring;
    CALayer *_progressBg, *_progress;
    CALayer *_dlChip; SFLabel *_dlLabel;   // download status bottom left
    CALayer *_durationPill;
    SFLabel *_duration;
    CALayer *_badgeBg;
    SFLabel *_badge;
    SFLabel *_title, *_subtitle;
    CAGradientLayer *_scrim;
    BOOL _imageRequested;
}

- (instancetype)initWithItem:(SFItem *)item style:(SFTileStyle)st theme:(SFTheme *)theme {
    return [self initWithItem:item style:st theme:theme width:0];
}

- (instancetype)initWithItem:(SFItem *)item style:(SFTileStyle)st theme:(SFTheme *)theme width:(CGFloat)width {
    if ((self = [super init])) {
        _item = item; _style = st; _theme = theme;
        SFTileMetrics m = SFMetricsForStyle(st);
        CGFloat w = width > 0 ? width : U(m.width), ih = U(m.imageHeight), th = U(m.textHeight);
        self.anchorPoint = CGPointMake(0.5, 0);    // scales from top centre
        self.bounds = CGRectMake(0, 0, w, ih + (th ? U(14) + th : 0));
        CGFloat corner = (st == SFTileStyleCircle || st == SFTileStyleButton) ? ih / 2 : U(theme.corner);

        // shadow carrier (without masksToBounds), the masked image inside it
        CALayer *holder = [CALayer layer];
        holder.frame = CGRectMake(0, 0, w, ih);
        holder.cornerRadius = corner;
        holder.shadowColor = CGColorGetConstantColor(kCGColorBlack);
        holder.shadowOpacity = 0;
        holder.shadowRadius = U(24);
        holder.shadowOffset = CGSizeMake(0, U(14));
        CGPathRef sp = CGPathCreateWithRoundedRect(holder.bounds, corner, corner, NULL);
        holder.shadowPath = sp;
        CGPathRelease(sp);
        holder.name = @"holder";
        [self addSublayer:holder];

        _image = [SFImageLayer layer];
        _image.frame = holder.bounds;
        _image.cornerRadius = corner;
        _image.placeholderColor = item.tint ?: theme.surface;
        if (st == SFTileStyleApp || st == SFTileStyleWide) {
            // text in the image (app tiles, sections)
            if (item.image.length && st == SFTileStyleWide) {
                _scrim = [CAGradientLayer layer];
                _scrim.frame = _image.bounds;
                _scrim.colors = @[(id)[NSColor colorWithDeviceWhite:0 alpha:0].CGColor,
                                  (id)[NSColor colorWithDeviceWhite:0 alpha:0.78].CGColor];
                _scrim.startPoint = CGPointMake(0.5, 0.35);
                _scrim.endPoint = CGPointMake(0.5, 1);
                [_image addSublayer:_scrim];
            }
        }
        if (item.imageFit) {   // logos: fitted, background matching the logo's brightness
            _image.contentsGravity = kCAGravityResizeAspect;
            _image.placeholderColor = theme.surface; _image.backgroundColor = theme.surface.CGColor;
            _image.adaptiveBackground = YES;
        }
        [holder addSublayer:_image];

        CGImageRef logoImg = (st == SFTileStyleApp && item.logo) ? SFLogoImage(item.logo, item.logoVariant) : NULL;
        if (logoImg) {
            CALayer *lg = [CALayer layer];
            lg.contents = (__bridge id)logoImg;
            lg.contentsGravity = kCAGravityResizeAspect;
            lg.frame = CGRectInset(CGRectMake(0, 0, w, ih), w * 0.14, ih * 0.27);
            [_image addSublayer:lg];
        } else if (st == SFTileStyleApp) {
            SFTheme *t = [SFTheme themeNamed:item.themeName ?: @"home"];
            SFLabel *wm = [SFLabel labelWithFont:[t wordmarkFont:item.title.length > 9 ? 40 : 54]
                                           color:item.tint ? [NSColor whiteColor] : t.text];
            if (t.light && !item.tint) wm.color = t.accent;
            wm.text = item.title;
            wm.alignment = NSCenterTextAlignment;
            wm.shadow = YES;
            CGFloat h = [wm sizeToFitWidth:w - U(24)];
            wm.position = CGPointMake(U(12), (ih - h) / 2);
            [_image addSublayer:wm];
            if (item.subtitle.length) {
                SFLabel *sub = [SFLabel labelWithFont:[t medium:20] color:[NSColor colorWithDeviceWhite:1 alpha:0.85]];
                sub.text = item.subtitle; sub.alignment = NSCenterTextAlignment;
                CGFloat sh = [sub sizeToFitWidth:w - U(24)];
                sub.position = CGPointMake(U(12), ih - sh - U(16));
                [_image addSublayer:sub];
            }
        } else if (st == SFTileStyleButton) {
            // action pill: title centred; active actions (tint) coloured, otherwise a neutral surface
            SFLabel *bt = [SFLabel labelWithFont:[theme bold:26] color:item.tint ? [NSColor whiteColor] : theme.text];
            bt.text = item.title; bt.alignment = NSCenterTextAlignment; bt.maxLines = 1;
            CGFloat h = [bt sizeToFitWidth:w - U(36)];
            bt.position = CGPointMake(U(18), (ih - h) / 2);
            [_image addSublayer:bt];
        } else if (st == SFTileStyleWide) {
            // with image: white + shadow over the image. Without image: theme colour on the tile surface
            // (white on light grey was hardly readable in the light ORF theme)
            BOOL plain = !item.image.length && !item.tint;   // coloured tiles (accent) keep white text
            SFLabel *wt = [SFLabel labelWithFont:[theme bold:34] color:plain ? theme.text : [NSColor whiteColor]];
            wt.text = item.title; wt.maxLines = 2; wt.shadow = !plain;
            CGFloat h = [wt sizeToFitWidth:w - U(48)];
            wt.position = CGPointMake(U(24), ih - h - U(20));
            [_image addSublayer:wt];
        }

        // badge (LIVE / NEU / LOKAL)
        if (item.badge.length) {
            _badge = [SFLabel labelWithFont:[theme bold:18] color:theme.accentText];
            _badge.text = item.badge;
            [_badge sizeToFitWidth:U(200)];
            NSSize ts = [item.badge sizeWithAttributes:@{NSFontAttributeName: [theme bold:18]}];
            _badge.bounds = CGRectMake(0, 0, ceil(ts.width) + 2, _badge.bounds.size.height);
            _badgeBg = [CALayer layer];
            _badgeBg.backgroundColor = ([item.badge isEqualToString:@"LIVE"] ? SFHex(0xe5162a) : theme.accent).CGColor;
            _badgeBg.cornerRadius = U(5);
            _badgeBg.frame = CGRectMake(U(12), U(12), _badge.bounds.size.width + U(16), _badge.bounds.size.height + U(6));
            _badge.position = CGPointMake(U(8), U(3));
            [_badgeBg addSublayer:_badge];
            [holder addSublayer:_badgeBg];
        }

        // duration bottom right
        if (item.duration > 0 && (st == SFTileStyleLandscape)) {
            _duration = [SFLabel labelWithFont:[theme medium:19] color:[NSColor whiteColor]];
            _duration.text = SFFormatDuration(item.duration);
            NSSize ts = [_duration.text sizeWithAttributes:@{NSFontAttributeName: _duration.font}];
            [_duration sizeToFitWidth:ceil(ts.width) + 2];
            _durationPill = [CALayer layer];
            _durationPill.backgroundColor = [NSColor colorWithDeviceWhite:0 alpha:0.78].CGColor;
            _durationPill.cornerRadius = U(5);
            CGFloat pw = _duration.bounds.size.width + U(14), ph = _duration.bounds.size.height + U(4);
            _durationPill.frame = CGRectMake(w - pw - U(10), ih - ph - U(12), pw, ph);
            _duration.position = CGPointMake(U(7), U(2));
            [_durationPill addSublayer:_duration];
            [holder addSublayer:_durationPill];
        }

        // download status (offline layer): chip bottom left, videos only
        if (st == SFTileStyleLandscape && item.kind == SFItemVideo) {
            _dlChip = [CALayer layer];
            _dlChip.backgroundColor = [NSColor colorWithDeviceWhite:0 alpha:0.78].CGColor;
            _dlChip.cornerRadius = U(5);
            _dlChip.hidden = YES;
            _dlLabel = [SFLabel labelWithFont:[theme medium:19] color:[NSColor whiteColor]];
            [_dlChip addSublayer:_dlLabel];
            [holder addSublayer:_dlChip];
        }

        // progress
        if (st == SFTileStyleLandscape || st == SFTileStylePoster) {
            _progressBg = [CALayer layer];
            _progressBg.backgroundColor = [NSColor colorWithDeviceWhite:1 alpha:0.35].CGColor;
            _progressBg.frame = CGRectMake(0, ih - U(6), w, U(6));
            _progress = [CALayer layer];
            _progress.backgroundColor = (theme.light ? theme.accent : ([theme.identifier isEqualToString:@"youtube"] ? theme.accent : theme.focus)).CGColor;
            _progress.anchorPoint = CGPointZero;
            _progress.frame = CGRectMake(0, 0, 0, U(6));
            [_progressBg addSublayer:_progress];
            _progressBg.hidden = YES;
            [_image addSublayer:_progressBg];
        }

        // focus frame
        _ring = [CALayer layer];
        CGFloat pad = U(5);
        _ring.frame = CGRectInset(holder.frame, -pad, -pad);
        _ring.cornerRadius = corner + pad;
        _ring.borderWidth = U(4);
        _ring.borderColor = theme.focus.CGColor;
        _ring.opacity = 0;
        [self addSublayer:_ring];

        // texts
        if (th > 0) {
            BOOL center = st == SFTileStyleCircle || st == SFTileStylePoster;
            _title = [SFLabel labelWithFont:[theme medium:center ? 23 : 25] color:theme.text];
            _title.text = item.title;
            _title.maxLines = 2;
            _title.alignment = center ? NSCenterTextAlignment : NSLeftTextAlignment;
            CGFloat tth = [_title sizeToFitWidth:w];
            _title.position = CGPointMake(0, ih + U(14));
            [self addSublayer:_title];
            if (item.subtitle.length && !center) {
                _subtitle = [SFLabel labelWithFont:[theme regular:21] color:theme.textDim];
                _subtitle.text = item.subtitle;
                [_subtitle sizeToFitWidth:w];
                _subtitle.position = CGPointMake(0, ih + U(18) + tth);
                [self addSublayer:_subtitle];
            }
        }
        [self refreshProgress];
    }
    return self;
}

- (id<CAAction>)actionForKey:(NSString *)event {
    if ([event isEqualToString:@"position"] || [event isEqualToString:@"bounds"]) return nil;
    return [super actionForKey:event];
}

- (void)loadImage {
    if (_imageRequested) return;
    _imageRequested = YES;
    _image.source = self.item.image;
}

- (void)refreshDownload {
    if (!_dlChip) return;
    double p = 0;
    SFDLState s = [[SFDownloads shared] stateFor:self.item.identifier progress:&p];
    NSString *t = nil;
    if (s == SFDLRunning) t = [NSString stringWithFormat:@"\u2193 %d %%", (int)round(p * 100)];
    else if (s == SFDLQueued) t = @"\u2193 wartet";
    // Everywhere a downloaded video appears (channel, continue watching, history …) – just not on the
    // downloads page itself. Formerly: !localPath, but saved entries inherit the path once the video
    // played from the downloads -> the chip was missing there (WBS Legal report 2026-11-04)
    else if (s == SFDLDone && [[SFDownloads shared] isKept:self.item.identifier]) t = @"\u2193 Behalten";   // also on the downloads page
    else if (s == SFDLDone && !self.item.inDownloadsList) t = @"\u2193 Offline";
    else if (s == SFDLFailed) t = [[SFDownloads shared] willRetry:self.item.identifier] ? @"\u2193 später erneut" : @"Download fehlgeschlagen";
    SFNoAnimate(^{
        self->_dlChip.hidden = (t == nil);
        if (!t) return;
        self->_dlLabel.text = t;
        NSSize ts = [t sizeWithAttributes:@{NSFontAttributeName: self->_dlLabel.font}];
        [self->_dlLabel sizeToFitWidth:ceil(ts.width) + 2];
        CGFloat pw = self->_dlLabel.bounds.size.width + U(14), ph = self->_dlLabel.bounds.size.height + U(4);
        CGFloat ih = self->_dlChip.superlayer.bounds.size.height;
        self->_dlChip.frame = CGRectMake(U(10), ih - ph - U(12), pw, ph);
        self->_dlLabel.position = CGPointMake(U(7), U(2));
    });
}

- (void)refreshProgress {
    [self refreshDownload];
    if (!_progressBg) return;
    double p = self.item.kind == SFItemVideo ? [[SFStore shared] progressFor:self.item.identifier] : 0;
    BOOL watched = p >= 1;
    SFNoAnimate(^{
        self->_progressBg.hidden = (p <= 0.01);
        CGFloat w = self->_progressBg.bounds.size.width;
        self->_progress.frame = CGRectMake(0, 0, watched ? w : w * p, U(6));
        self->_image.opacity = watched ? 0.6 : 1.0;
    });
}

- (void)setFocused:(BOOL)f {
    if (_focused == f) return;
    _focused = f;
    CALayer *holder = nil;
    for (CALayer *l in self.sublayers) if ([l.name isEqualToString:@"holder"]) holder = l;
    CGFloat s = _style == SFTileStyleApp ? 1.12 : (_style == SFTileStyleCircle ? 1.12 : 1.08);
    SFAnimate(0.22, ^{
        self.transform = f ? CATransform3DMakeScale(s, s, 1) : CATransform3DIdentity;
        self.zPosition = f ? 10 : 0;
        holder.shadowOpacity = f ? 0.55 : 0;
        self->_ring.opacity = f ? 1 : 0;
        self->_title.color = f ? self->_theme.text : self->_theme.text;
    });
    if (_title) {
        _title.opacity = 1;
    }
}
@end
