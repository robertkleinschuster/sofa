#import "SFEndTile.h"

@implementation SFEndTile {
    SFTheme *_theme;
    CALayer *_holder;            // shadow carrier
    SFImageLayer *_image;
    CAGradientLayer *_shade;     // under the title (video/playlist)
    SFLabel *_title;             // focused video/playlist: title over the thumbnail
    CALayer *_chip; SFLabel *_chipLabel;   // playlist marker / follow pill
    CALayer *_ring;
    CALayer *_caption; SFLabel *_capName, *_capAction;   // round tiles: name + action below (focused)
}

- (BOOL)round { return [_kind isEqualToString:SFEndCardChannel] || [_kind isEqualToString:SFEndCardFollow]; }

- (NSString *)elementTitle {
    NSString *t = _element[@"title"];
    return [t isKindOfClass:[NSString class]] && t.length ? t : nil;
}

- (CGRect)captionFrame {
    if (!_focused || !_caption) return CGRectNull;
    return [self convertRect:_caption.frame toLayer:self.superlayer];
}

- (NSString *)okAction {
    if ([_kind isEqualToString:SFEndCardVideo]) return @"abspielen";
    if ([_kind isEqualToString:SFEndCardPlaylist]) return @"Playlist abspielen";
    if ([_kind isEqualToString:SFEndCardChannel]) return @"zum Kanal";
    return _following ? @"nicht mehr folgen" : @"folgen";
}

- (void)buildWithTheme:(SFTheme *)theme {
    _theme = theme;
    CGSize sz = self.bounds.size;
    CGFloat corner = self.round ? sz.width / 2 : U(10);
    _holder = [CALayer layer];
    _holder.frame = self.bounds;
    _holder.cornerRadius = corner;
    _holder.backgroundColor = [NSColor colorWithDeviceWhite:0.12 alpha:1].CGColor;
    _holder.shadowColor = CGColorGetConstantColor(kCGColorBlack);
    _holder.shadowOpacity = 0.6; _holder.shadowRadius = U(14); _holder.shadowOffset = CGSizeMake(0, U(4));
    SFShadowPathFromBounds(_holder);
    [self addSublayer:_holder];
    _image = [SFImageLayer layer];
    _image.frame = self.bounds;
    _image.cornerRadius = corner; _image.masksToBounds = YES;
    _image.contentsGravity = kCAGravityResizeAspectFill;
    _image.placeholderColor = [NSColor colorWithDeviceWhite:0.16 alpha:1];
    if (self.round) { _image.borderWidth = U(3); _image.borderColor = [NSColor colorWithDeviceWhite:1 alpha:0.85].CGColor; }
    [_holder addSublayer:_image];

    if (!self.round) {
        // title over the lower part of the thumbnail, only while focused (YouTube's hover look)
        _shade = [CAGradientLayer layer];
        _shade.frame = CGRectMake(0, sz.height * 0.35, sz.width, sz.height * 0.65);
        _shade.colors = @[(id)[NSColor colorWithDeviceWhite:0 alpha:0].CGColor, (id)[NSColor colorWithDeviceWhite:0 alpha:0.88].CGColor];
        _shade.opacity = 0;
        [_image addSublayer:_shade];
        CGFloat fs = MAX(20, MIN(30, sz.width / SFScale / 17));
        _title = [SFLabel labelWithFont:[theme bold:fs] color:[NSColor whiteColor]];
        _title.maxLines = 2; _title.shadow = YES;
        _title.text = [self elementTitle] ?: @"";
        CGFloat pad = U(14), h = [_title sizeToFitWidth:sz.width - 2 * pad];
        _title.position = CGPointMake(pad, sz.height - pad - h);
        _title.opacity = 0;
        [_image addSublayer:_title];
    }
    if ([_kind isEqualToString:SFEndCardPlaylist]) {   // always visible: tells a playlist from a video
        _chipLabel = [SFLabel labelWithFont:[theme bold:20] color:[NSColor whiteColor]];
        _chipLabel.text = @"☰  Playlist";
        CGFloat w = ceil([_chipLabel.text sizeWithAttributes:@{NSFontAttributeName: [theme bold:20]}].width) + U(24);
        [_chipLabel sizeToFitWidth:w - U(24)];
        _chip = [CALayer layer];
        _chip.frame = CGRectMake(sz.width - w - U(10), U(10), w, U(34));
        _chip.cornerRadius = U(6);
        _chip.backgroundColor = [NSColor colorWithDeviceWhite:0 alpha:0.78].CGColor;
        _chipLabel.position = CGPointMake(U(12), (U(34) - _chipLabel.bounds.size.height) / 2);
        [_chip addSublayer:_chipLabel];
        [_image addSublayer:_chip];
    }
    if ([_kind isEqualToString:SFEndCardFollow]) {   // follow pill on the avatar's lower edge, always visible
        _chip = [CALayer layer];
        _chip.cornerRadius = U(17);
        _chipLabel = [SFLabel labelWithFont:[theme bold:20] color:[NSColor whiteColor]];
        _chipLabel.alignment = NSCenterTextAlignment;
        [_chip addSublayer:_chipLabel];
        [self addSublayer:_chip];
        [self updateFollowPill];
    }
    if (self.round) {   // focused: name + action below the avatar
        _caption = [CALayer layer];
        _caption.cornerRadius = U(10);
        _caption.backgroundColor = [NSColor colorWithDeviceWhite:0.05 alpha:0.85].CGColor;
        _capName = [SFLabel labelWithFont:[theme bold:24] color:[NSColor whiteColor]];
        _capName.alignment = NSCenterTextAlignment; _capName.maxLines = 1;
        _capAction = [SFLabel labelWithFont:[theme medium:20] color:[NSColor colorWithDeviceWhite:1 alpha:0.7]];
        _capAction.alignment = NSCenterTextAlignment;
        [_caption addSublayer:_capName]; [_caption addSublayer:_capAction];
        _caption.opacity = 0;
        [self addSublayer:_caption];
    }
    _ring = [CALayer layer];
    CGFloat pad = U(7);
    _ring.frame = CGRectInset(self.bounds, -pad, -pad);
    _ring.cornerRadius = corner + pad;
    _ring.borderWidth = U(4);
    _ring.borderColor = theme.focus.CGColor;
    _ring.opacity = 0;
    [self insertSublayer:_ring above:_holder];   // under the follow pill and the caption
}

- (void)setFollowing:(BOOL)f {
    BOOL changed = f != _following;
    _following = f;
    if (changed) [self updateFollowPill];
}

- (void)updateFollowPill {
    if (![_kind isEqualToString:SFEndCardFollow] || !_chip) return;
    CGSize sz = self.bounds.size;
    SFNoAnimate(^{
        self->_chipLabel.text = self->_following ? @"✓ Gefolgt" : @"Folgen";
        CGFloat w = MAX(sz.width * 0.8, ceil([self->_chipLabel.text sizeWithAttributes:@{NSFontAttributeName: [self->_theme bold:20]}].width) + U(28));
        self->_chip.frame = CGRectMake((sz.width - w) / 2, sz.height - U(22), w, U(34));
        self->_chip.backgroundColor = self->_following ? [NSColor colorWithDeviceWhite:0.18 alpha:0.95].CGColor : self->_theme.accent.CGColor;
        [self->_chipLabel sizeToFitWidth:w];
        self->_chipLabel.position = CGPointMake(0, (U(34) - self->_chipLabel.bounds.size.height) / 2);
    });
}

- (void)loadImage {
    NSString *src = _element[@"image"];
    if ([src isKindOfClass:[NSString class]] && src.length && !_image.source) _image.source = src;
}

// engaged = the tiles have focus: the focused one stands out (full, ring, text), the others step back.
// limit = video rect (round tiles keep their caption inside it).
- (void)setLook:(BOOL)engaged focused:(BOOL)focused bounds:(CGRect)limit {
    _focused = focused;
    if (focused && _caption) {
        SFNoAnimate(^{
            CGSize sz = self.bounds.size;
            self->_capName.text = [self elementTitle] ?: @"Kanal";
            self->_capAction.text = [self.kind isEqualToString:SFEndCardChannel] ? @"Zum Kanal" : (self->_following ? @"Du folgst diesem Kanal" : @"Kanal folgen");
            CGFloat tw = MAX([self->_capName.text sizeWithAttributes:@{NSFontAttributeName: self->_capName.font}].width,
                             [self->_capAction.text sizeWithAttributes:@{NSFontAttributeName: self->_capAction.font}].width);
            CGFloat w = MIN(MAX(ceil(tw) + U(36), sz.width), U(460)), pad = U(10);
            CGFloat h1 = [self->_capName sizeToFitWidth:w - U(24)], h2 = [self->_capAction sizeToFitWidth:w - U(24)];
            CGFloat h = pad + h1 + U(2) + h2 + pad;
            CGFloat below = [self.kind isEqualToString:SFEndCardFollow] ? U(26) : U(14);
            CGFloat y = sz.height + below;
            CGRect inSuper = [self convertRect:CGRectMake(0, y, w, h) toLayer:self.superlayer];
            if (CGRectGetMaxY(inSuper) > CGRectGetMaxY(limit) - U(10)) y = -h - U(14);   // no room below: above
            CGFloat x = (sz.width - w) / 2;
            CGFloat sx = self.frame.origin.x + x;   // keep inside the video horizontally
            if (sx < CGRectGetMinX(limit) + U(10)) x += CGRectGetMinX(limit) + U(10) - sx;
            if (sx + w > CGRectGetMaxX(limit) - U(10)) x -= sx + w - CGRectGetMaxX(limit) + U(10);
            self->_caption.frame = CGRectMake(x, y, w, h);
            self->_capName.position = CGPointMake(U(12), pad);
            self->_capAction.position = CGPointMake(U(12), pad + h1 + U(2));
        });
    }
    CGFloat s = self.round ? 1.1 : 1.06;
    SFAnimate(0.22, ^{
        self.opacity = !self.shownNow ? 0 : (focused ? 1 : (engaged ? 0.55 : 0.92));
        self.transform = focused ? CATransform3DMakeScale(s, s, 1) : CATransform3DIdentity;
        self.zPosition = focused ? 10 : 0;
        self->_ring.opacity = focused ? 1 : 0;
        self->_shade.opacity = focused ? 1 : 0;
        self->_title.opacity = focused ? 1 : 0;
        self->_caption.opacity = focused ? 1 : 0;
    });
}
@end
