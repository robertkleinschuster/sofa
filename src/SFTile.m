#import "SFTile.h"
#import "SFStore.h"
#import "SFLogo.h"

SFTileMetrics SFMetricsForStyle(SFTileStyle st) {
    switch (st) {
        case SFTileStyleCircle:   return (SFTileMetrics){200, 200, 64, 52};
        case SFTileStylePoster:   return (SFTileMetrics){240, 360, 64, 36};
        case SFTileStyleApp:      return (SFTileMetrics){320, 192, 0, 40};
        case SFTileStyleWide:     return (SFTileMetrics){560, 315, 0, 40};
        case SFTileStyleLandscape:
        default:                  return (SFTileMetrics){384, 216, 112, 36};
    }
}

@implementation SFTileLayer {
    SFTileStyle _style;
    SFTheme *_theme;
    SFImageLayer *_image;
    CALayer *_ring;
    CALayer *_progressBg, *_progress;
    CALayer *_durationPill;
    SFLabel *_duration;
    CALayer *_badgeBg;
    SFLabel *_badge;
    SFLabel *_title, *_subtitle;
    CAGradientLayer *_scrim;
    BOOL _imageRequested;
}

- (instancetype)initWithItem:(SFItem *)item style:(SFTileStyle)st theme:(SFTheme *)theme {
    if ((self = [super init])) {
        _item = item; _style = st; _theme = theme;
        SFTileMetrics m = SFMetricsForStyle(st);
        CGFloat w = U(m.width), ih = U(m.imageHeight), th = U(m.textHeight);
        self.anchorPoint = CGPointMake(0.5, 0);    // skaliert von oben-mitte
        self.bounds = CGRectMake(0, 0, w, ih + (th ? U(14) + th : 0));
        CGFloat corner = st == SFTileStyleCircle ? ih / 2 : U(theme.corner);

        // Schatten-Träger (ohne masksToBounds), darin das maskierte Bild
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
            // Text im Bild (App-Kacheln, Rubriken)
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
        if (item.imageFit) { _image.contentsGravity = kCAGravityResizeAspect; _image.backgroundColor = theme.surface.CGColor; }
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
        } else if (st == SFTileStyleWide) {
            SFLabel *wt = [SFLabel labelWithFont:[theme bold:34] color:[NSColor whiteColor]];
            wt.text = item.title; wt.maxLines = 2; wt.shadow = YES;
            CGFloat h = [wt sizeToFitWidth:w - U(48)];
            wt.position = CGPointMake(U(24), ih - h - U(20));
            [_image addSublayer:wt];
        }

        // Badge (LIVE / NEU / LOKAL)
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

        // Dauer unten rechts
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

        // Fortschritt
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

        // Fokus-Rahmen
        _ring = [CALayer layer];
        CGFloat pad = U(5);
        _ring.frame = CGRectInset(holder.frame, -pad, -pad);
        _ring.cornerRadius = corner + pad;
        _ring.borderWidth = U(4);
        _ring.borderColor = theme.focus.CGColor;
        _ring.opacity = 0;
        [self addSublayer:_ring];

        // Texte
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

- (void)refreshProgress {
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
