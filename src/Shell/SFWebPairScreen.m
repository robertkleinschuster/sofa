#import "SFWebPairScreen.h"
#import "SFWebServer.h"
#import "SFWebDevices.h"
#import "SFLayers.h"
#import "SFMenuScreen.h"
#import "SFQRCode.h"

static const CGFloat kQRSide = 460;   // design units: modules of ~10 units (3 mm on a 27" screen) - a phone reads it from a few metres

@implementation SFWebPairScreen {
    SFLabel *_title, *_steps, *_code, *_hint, *_devices, *_countdown, *_qrCaption;
    CALayer *_barBg, *_bar, *_qrCard, *_qr;
    NSTimer *_second;
    NSString *_qrLink;   // what the QR code says now
    NSInteger _qrModules;  // its size in modules (0 = none)
}

// The pairing link (docs/api.md "Pairing by QR code"): the PWA's page that a native app claims as its
// Universal Link / App Link - one link opens the app where it is installed, else Sofa im Browser.
// Host and code travel in the fragment: never sent to the web server that serves the page.
+ (NSString *)pairingLinkHost:(NSString *)host port:(uint16_t)port code:(NSString *)code {
    if (!host.length || code.length != 6) return nil;
    NSString *base = [SFWebServer appURL];
    if (![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
    return [NSString stringWithFormat:@"%@pair#host=%@:%u&code=%@", base, host, port, code];
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
        _hint = [SFLabel labelWithFont:[theme regular:26] color:theme.textDim];
        _hint.maxLines = 0;
        _devices = [SFLabel labelWithFont:[theme medium:34] color:theme.accent];
        _devices.maxLines = 0;
        _countdown = [SFLabel labelWithFont:[theme medium:34] color:theme.text];
        _barBg = [CALayer layer]; _barBg.backgroundColor = [theme.textDim colorWithAlphaComponent:0.3].CGColor;
        _bar = [CALayer layer]; _bar.backgroundColor = theme.accent.CGColor; _bar.anchorPoint = CGPointZero;
        [_barBg addSublayer:_bar];
        // the QR code: dark on white whatever the theme (cameras read dark modules on light), on a card
        // with the theme's corner; scaled up module by module without smoothing (sharp edges)
        _qrCard = [CALayer layer]; _qrCard.backgroundColor = [NSColor whiteColor].CGColor;
        _qr = [CALayer layer]; _qr.magnificationFilter = kCAFilterNearest; _qr.minificationFilter = kCAFilterNearest;
        [_qrCard addSublayer:_qr];
        _qrCaption = [SFLabel labelWithFont:[theme medium:30] color:theme.text];
        _qrCaption.text = @"Oder mit dem Handy scannen";
        for (CALayer *l in @[_title, _steps, _code, _barBg, _countdown, _hint, _devices, _qrCard, _qrCaption]) [self.layer addSublayer:l];
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
        _steps.text = [NSString stringWithFormat:@"1.  Im Browser öffnen: %@\n2.  Als Adresse „%@“ eingeben\n3.  Diesen Code eingeben:", site, w.shortName];
        _code.text = code.length == 6 ? [NSString stringWithFormat:@"%@ %@", [code substringToIndex:3], [code substringFromIndex:3]] : @"···";
        _hint.text = @"Das Gerät braucht Tailscale, wie dieser Mac. Danach läuft dort alles für sich: eigene Wiedergabe, gemeinsame Listen und Fortschritt.";
    }
    NSArray *devs = [[SFWebDevices shared] devices];
    NSMutableArray *names = [NSMutableArray new];
    for (SFWebDevice *d in devs) [names addObject:[NSString stringWithFormat:@"%@ (%@)", d.name, d.client.label]];
    _devices.text = devs.count ? [NSString stringWithFormat:@"Verbunden: %@\nOK drücken: Geräte trennen", [names componentsJoinedByString:@", "]] : @"Noch kein Gerät verbunden.";
    [self updateQR:w.problem ? nil : [SFWebPairScreen pairingLinkHost:w.fullName port:w.port code:code]];
    if (self.size.width > 0) [self layoutForSize:self.size];
}

- (void)updateQR:(NSString *)link {
    SFNoAnimate(^{ self->_qrCard.hidden = self->_qrCaption.hidden = !link; });
    if (!link || [link isEqualToString:_qrLink]) return;
    _qrLink = link;
    SFQRCode *qr = [SFQRCode codeForText:link ecc:SFQRECCMedium];
    _qrModules = qr.size;
    CGImageRef img = [qr newImageWithQuietZone:0 dark:[NSColor blackColor].CGColor light:[NSColor whiteColor].CGColor];
    SFNoAnimate(^{ self->_qr.contents = (__bridge id)img; });
    if (img) CGImageRelease(img);
    SFLog(@"web: pairing QR code version %ld (%ld modules)", (long)qr.version, (long)qr.size);
}

// Two columns: the steps and the code on the left; the QR code (with the quiet zone the standard asks
// for: 4 modules of white) on the right, what the device needs under it; the connected devices below
// both. Every module a whole number of pixels: sharp on the screen, whatever scales the layer.
- (void)layoutForSize:(CGSize)size {
    [super layoutForSize:size];
    SFNoAnimate(^{
        CGFloat x = U(160), top = U(130), full = size.width - 2 * x, side = U(kQRSide), qrX = size.width - x - side;
        BOOL qr = !self->_qrCard.hidden;
        self->_qrCard.frame = CGRectMake(qrX, top + U(16), side, side);
        self->_qrCard.cornerRadius = U(MAX(8, self.theme.corner));
        CGFloat module = self->_qrModules ? floor(side / (self->_qrModules + 8)) : 0, inner = module * self->_qrModules;
        self->_qr.frame = CGRectMake(round((side - inner) / 2), round((side - inner) / 2), inner, inner);
        [self->_qrCaption sizeToFitWidth:side];
        self->_qrCaption.position = CGPointMake(qrX + (side - self->_qrCaption.bounds.size.width) / 2, top + U(16) + side + U(20));
        CGFloat right = top + U(16) + side + U(20) + self->_qrCaption.bounds.size.height + U(28);
        CGFloat w = qr ? qrX - U(100) - x : full, y = top;
        self->_title.position = CGPointMake(x, y); [self->_title sizeToFitWidth:w]; y += self->_title.bounds.size.height + U(40);
        self->_steps.position = CGPointMake(x, y); [self->_steps sizeToFitWidth:w]; y += self->_steps.bounds.size.height + U(30);
        self->_code.position = CGPointMake(x, y); [self->_code sizeToFitWidth:w]; y += self->_code.bounds.size.height + U(16);
        self->_barBg.frame = CGRectMake(x, y, MIN(U(720), w), U(8)); self->_barBg.cornerRadius = U(4);
        y += U(26);
        self->_countdown.position = CGPointMake(x, y); [self->_countdown sizeToFitWidth:w]; y += self->_countdown.bounds.size.height + U(36);
        if (qr) { self->_hint.position = CGPointMake(qrX, right); right += [self->_hint sizeToFitWidth:side]; }
        else { self->_hint.position = CGPointMake(x, y); [self->_hint sizeToFitWidth:full]; y += self->_hint.bounds.size.height + U(36); }
        y = MAX(y, right + U(36));
        self->_devices.position = CGPointMake(x, y); [self->_devices sizeToFitWidth:full];
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
        o.detail = [NSString stringWithFormat:@"%@ · seit %@", d.client.label, [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:d.paired]]];
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
