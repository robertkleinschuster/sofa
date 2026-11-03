#import "SFPairScreen.h"
#import "SFLounge.h"
#import "SFLayers.h"
#import "SFLogo.h"

@implementation SFPairScreen {
    SFLabel *_title, *_steps, *_code, *_hint, *_phones, *_countdown;
    CALayer *_barBg, *_bar;
    NSDate *_validUntil;
    NSTimer *_second;
    NSTimer *_refresh;
    BOOL _visible, _loading;
}

- (instancetype)initWithTheme:(SFTheme *)theme {
    if ((self = [super initWithTheme:theme])) {
        self.layer.backgroundColor = theme.background.CGColor;
        _title = [SFLabel labelWithFont:[theme bold:64] color:theme.text];
        _title.text = @"Mit dem Handy verbinden";
        _steps = [SFLabel labelWithFont:[theme regular:34] color:theme.textDim];
        _steps.lineSpacing = U(10);
        _steps.maxLines = 0;
        _steps.text = @"1.  YouTube-App am Handy öffnen\n2.  Profilbild → Einstellungen → „Auf Fernseher ansehen“\n3.  „Mit TV-Code verbinden“ wählen und diesen Code eingeben:";
        _code = [SFLabel labelWithFont:[theme bold:150] color:theme.text];
        _code.text = @"···";
        _hint = [SFLabel labelWithFont:[theme regular:28] color:theme.textDim];
        _hint.maxLines = 0;
        _phones = [SFLabel labelWithFont:[theme medium:34] color:theme.accent];
        _countdown = [SFLabel labelWithFont:[theme medium:34] color:theme.text];
        _barBg = [CALayer layer]; _barBg.backgroundColor = [theme.textDim colorWithAlphaComponent:0.3].CGColor;
        _bar = [CALayer layer]; _bar.backgroundColor = theme.accent.CGColor; _bar.anchorPoint = CGPointZero;
        [_barBg addSublayer:_bar];
        [self.layer addSublayer:_countdown]; [self.layer addSublayer:_barBg];
        for (CALayer *l in @[_title, _steps, _code, _hint, _phones]) [self.layer addSublayer:l];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updatePhones) name:SFLoungeRemotesDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; [_refresh invalidate]; }

- (void)layoutForSize:(CGSize)size {
    [super layoutForSize:size];
    SFNoAnimate(^{
        CGFloat x = U(160), w = size.width - 2 * x, y = U(170);
        self->_title.position = CGPointMake(x, y); [self->_title sizeToFitWidth:w]; y += self->_title.bounds.size.height + U(50);
        self->_steps.position = CGPointMake(x, y); [self->_steps sizeToFitWidth:w]; y += self->_steps.bounds.size.height + U(40);
        self->_code.position = CGPointMake(x, y); [self->_code sizeToFitWidth:w]; y += self->_code.bounds.size.height + U(20);
        CGFloat cw = U(1130);   // Breite des Codes
        self->_barBg.frame = CGRectMake(x, y, cw, U(8)); self->_barBg.cornerRadius = U(4);
        y += U(28);
        self->_countdown.position = CGPointMake(x, y); [self->_countdown sizeToFitWidth:w]; y += self->_countdown.bounds.size.height + U(30);
        [self updateCountdown];
        self->_hint.position = CGPointMake(x, y); [self->_hint sizeToFitWidth:w]; y += self->_hint.bounds.size.height + U(60);
        self->_phones.position = CGPointMake(x, y); [self->_phones sizeToFitWidth:w];
    });
}

- (void)willAppear {
    [super willAppear];
    _visible = YES;
    [self updatePhones];
    [self loadCode];
    // Countdown sekündlich; neuer Code kurz vor Ablauf (Code lebt gemessen 300–307 s)
    _second = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateCountdown) userInfo:nil repeats:YES];
}

- (void)willDisappear {
    [super willDisappear];
    _visible = NO;
    [_refresh invalidate]; _refresh = nil;
    [_second invalidate]; _second = nil;
}

static const NSTimeInterval kCodeLife = 295;   // sicher unter den gemessenen 300 s

- (void)updateCountdown {
    if (!_validUntil) {
        SFNoAnimate(^{ self->_countdown.text = @""; self->_barBg.hidden = YES; });
        return;
    }
    NSTimeInterval left = [_validUntil timeIntervalSinceNow];
    if (left <= 10 && !_loading) [self loadCode];   // nahtlos erneuern
    left = MAX(0, left);
    int s = (int)ceil(left);
    SFNoAnimate(^{
        self->_countdown.text = [NSString stringWithFormat:@"Gültig noch %d:%02d", s / 60, s % 60];
        self->_barBg.hidden = NO;
        self->_bar.frame = CGRectMake(0, 0, self->_barBg.bounds.size.width * MIN(1, left / kCodeLife), self->_barBg.bounds.size.height);
        self->_bar.cornerRadius = self->_barBg.cornerRadius;
    });
}

- (void)loadCode {
    if (_loading || !_visible) return;
    _loading = YES;
    __weak SFPairScreen *ws = self;
    [[SFLounge shared] fetchPairingCode:^(NSString *code, NSError *e) {
        SFPairScreen *s = ws;
        if (!s) return;
        s->_loading = NO;
        if (!s->_visible) return;
        if (code) {
            NSString *f = [NSString stringWithFormat:@"%@ %@ %@ %@", [code substringWithRange:NSMakeRange(0, 3)], [code substringWithRange:NSMakeRange(3, 3)],
                           [code substringWithRange:NSMakeRange(6, 3)], [code substringWithRange:NSMakeRange(9, 3)]];
            s->_code.text = f;
            s->_validUntil = [NSDate dateWithTimeIntervalSinceNow:kCodeLife];
            s->_hint.text = @"Kurz vor Ablauf erscheint automatisch ein neuer Code. Einmal verbunden, findet das Handy Sofa danach von selbst (Cast-Symbol).";
        } else {
            s->_code.text = @"–";
            s->_validUntil = nil;
            s->_hint.text = e.localizedDescription ?: @"Kein Code verfügbar.";
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws loadCode]; });
        }
        [s layoutForSize:s.size];
    }];
}

- (void)updatePhones {
    NSArray *n = [SFLounge shared].remoteNames;
    _phones.text = n.count ? [@"Verbunden: " stringByAppendingString:[n componentsJoinedByString:@", "]] : @"";
    if (self.size.width > 0) [self layoutForSize:self.size];
}

- (BOOL)handleKey:(SFKey)key { return NO; }   // Menu -> zurück (Navigator)
@end
