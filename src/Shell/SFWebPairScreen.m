#import "SFWebPairScreen.h"
#import "SFWebServer.h"
#import "SFWebDevices.h"
#import "SFLayers.h"
#import "SFMenuScreen.h"

@implementation SFWebPairScreen {
    SFLabel *_title, *_steps, *_code, *_hint, *_devices, *_countdown;
    CALayer *_barBg, *_bar;
    NSTimer *_second;
}

- (instancetype)initWithTheme:(SFTheme *)theme {
    if ((self = [super initWithTheme:theme])) {
        self.layer.backgroundColor = theme.background.CGColor;
        _title = [SFLabel labelWithFont:[theme bold:64] color:theme.text];
        _title.text = @"Sofa im Browser";
        _steps = [SFLabel labelWithFont:[theme regular:34] color:theme.textDim];
        _steps.lineSpacing = U(10);
        _steps.maxLines = 0;
        _code = [SFLabel labelWithFont:[theme bold:150] color:theme.text];
        _hint = [SFLabel labelWithFont:[theme regular:28] color:theme.textDim];
        _hint.maxLines = 0;
        _devices = [SFLabel labelWithFont:[theme medium:34] color:theme.accent];
        _devices.maxLines = 0;
        _countdown = [SFLabel labelWithFont:[theme medium:34] color:theme.text];
        _barBg = [CALayer layer]; _barBg.backgroundColor = [theme.textDim colorWithAlphaComponent:0.3].CGColor;
        _bar = [CALayer layer]; _bar.backgroundColor = theme.accent.CGColor; _bar.anchorPoint = CGPointZero;
        [_barBg addSublayer:_bar];
        for (CALayer *l in @[_title, _steps, _code, _barBg, _countdown, _hint, _devices]) [self.layer addSublayer:l];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(update) name:SFWebDevicesDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(update) name:SFWebServerStatusDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; [_second invalidate]; }

- (void)willAppear {
    [super willAppear];
    [[SFWebDevices shared] openPairing];   // a code exists only while this screen shows it
    [_second invalidate];
    _second = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateCountdown) userInfo:nil repeats:YES];
    [self update];
}

- (void)willDisappear {
    [super willDisappear];
    [_second invalidate]; _second = nil;
    [[SFWebDevices shared] closePairing];
}

- (void)update {
    SFWebServer *w = [SFWebServer shared];
    NSString *site = [[[SFWebServer appURL] stringByReplacingOccurrencesOfString:@"https://" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSString *code = [SFWebDevices shared].pairingCode;
    if (w.problem || !w.shortName) {
        _steps.text = [NSString stringWithFormat:@"Am Handy oder Computer: %@", site];
        _code.text = @"–";
        _hint.text = w.problem ?: @"Die sichere Verbindung wird vorbereitet …";
    } else {
        _steps.text = [NSString stringWithFormat:@"1.  Am Handy oder Computer öffnen: %@\n2.  Als Adresse „%@“ eingeben\n3.  Diesen Code eingeben:", site, w.shortName];
        _code.text = code.length == 6 ? [NSString stringWithFormat:@"%@ %@", [code substringToIndex:3], [code substringFromIndex:3]] : @"···";
        _hint.text = @"Das Gerät braucht Tailscale, wie dieser Mac. Danach läuft dort alles für sich: eigene Wiedergabe, gemeinsame Listen und Fortschritt.";
    }
    NSArray *devs = [[SFWebDevices shared] devices];
    NSString *names = [[devs valueForKey:@"name"] componentsJoinedByString:@", "];
    _devices.text = devs.count ? [NSString stringWithFormat:@"Verbunden: %@\nOK drücken: Geräte trennen", names] : @"Noch kein Gerät verbunden.";
    if (self.size.width > 0) [self layoutForSize:self.size];
}

- (void)layoutForSize:(CGSize)size {
    [super layoutForSize:size];
    SFNoAnimate(^{
        CGFloat x = U(160), w = size.width - 2 * x, y = U(170);
        self->_title.position = CGPointMake(x, y); [self->_title sizeToFitWidth:w]; y += self->_title.bounds.size.height + U(50);
        self->_steps.position = CGPointMake(x, y); [self->_steps sizeToFitWidth:w]; y += self->_steps.bounds.size.height + U(40);
        self->_code.position = CGPointMake(x, y); [self->_code sizeToFitWidth:w]; y += self->_code.bounds.size.height + U(20);
        self->_barBg.frame = CGRectMake(x, y, U(720), U(8)); self->_barBg.cornerRadius = U(4);
        y += U(28);
        self->_countdown.position = CGPointMake(x, y); [self->_countdown sizeToFitWidth:w]; y += self->_countdown.bounds.size.height + U(30);
        self->_hint.position = CGPointMake(x, y); [self->_hint sizeToFitWidth:w]; y += self->_hint.bounds.size.height + U(60);
        self->_devices.position = CGPointMake(x, y); [self->_devices sizeToFitWidth:w];
    });
    [self updateCountdown];
}

- (void)updateCountdown {
    NSDate *until = [SFWebDevices shared].pairingCodeExpires;
    BOOL show = until && ![SFWebServer shared].problem && [SFWebServer shared].shortName;
    NSTimeInterval left = MAX(0, [until timeIntervalSinceNow]);
    int s = (int)ceil(left);
    SFNoAnimate(^{
        self->_barBg.hidden = !show;
        self->_countdown.text = show ? [NSString stringWithFormat:@"Gültig noch %d:%02d – danach erscheint ein neuer", s / 60, s % 60] : @"";
        self->_bar.frame = CGRectMake(0, 0, self->_barBg.bounds.size.width * MIN(1, left / 300), self->_barBg.bounds.size.height);
        self->_bar.cornerRadius = self->_barBg.cornerRadius;
    });
}

// OK: the paired devices, each can be disconnected; all at once with a confirmation
- (void)showDevices {
    SFNavigator *nav = self.navigator;
    SFTheme *t = self.theme;
    NSArray *devs = [[SFWebDevices shared] devices];
    if (!devs.count) { [nav toast:@"Noch kein Gerät verbunden"]; return; }
    NSMutableArray *opts = [NSMutableArray new];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"d.M.yyyy";
    for (SFWebDevice *d in devs) {
        SFMenuOption *o = [SFMenuOption option:[d.name stringByAppendingString:@" trennen"] action:^{
            [[SFWebDevices shared] remove:d.identifier];
            [nav toast:[NSString stringWithFormat:@"%@ getrennt – zum Verbinden neuen Code eingeben", d.name]];
        }];
        o.detail = [@"seit " stringByAppendingString:[f stringFromDate:[NSDate dateWithTimeIntervalSince1970:d.paired]]];
        [opts addObject:o];
    }
    if (devs.count > 1) {
        [opts addObject:[SFMenuOption option:@"Alle Geräte trennen" action:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                SFMenuOption *no = [SFMenuOption option:@"Abbrechen" action:^{}];
                SFMenuOption *yes = [SFMenuOption option:[NSString stringWithFormat:@"Ja, %lu Geräte trennen", (unsigned long)devs.count] action:^{
                    [[SFWebDevices shared] removeAll];
                    [nav toast:@"Alle Geräte getrennt"];
                }];
                [nav push:[[SFMenuScreen alloc] initWithTitle:@"Alle Geräte trennen?" subtitle:@"Jedes Gerät braucht danach einen neuen Code." options:@[no, yes] theme:t]];
            });
        }]];
    }
    [nav push:[[SFMenuScreen alloc] initWithTitle:@"Verbundene Geräte" subtitle:@"Ein getrenntes Gerät kommt nur mit einem neuen Code wieder dazu." options:opts theme:t]];
}

- (BOOL)handleKey:(SFKey)key {
    if (key == SFKeySelect || key == SFKeySelectHold) { [self showDevices]; return YES; }
    return NO;   // Menu -> back (navigator)
}
@end
