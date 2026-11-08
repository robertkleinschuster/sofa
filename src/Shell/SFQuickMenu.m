#import "SFQuickMenu.h"
#import "SFMenuScreen.h"
#import "SFAudioOutput.h"
#import "SFBluetooth.h"
#import "SFPower.h"
#import "SFHome.h"

@implementation SFQuickMenu

static __weak SFMenuScreen *gOpen;   // the quick menu on screen (MENU held again: no second one)

// (a chosen entry's action runs after its menu has closed - SFMenuScreen - so submenus just push)
+ (void)showOn:(SFNavigator *)nav {
    if (gOpen && [nav.stack containsObject:gOpen]) return;   // open already
    BOOL atHome = nav.stack.count <= 1;
    [SFAudioOutput outputs:^(NSArray *outputs) {   // the sound entry names the current output
        NSMutableArray *opts = [NSMutableArray new];
        if (!atHome) [opts addObject:[SFMenuOption option:@"Zum Startbildschirm" action:^{ [nav popToRoot]; }]];
        SFMenuOption *sound = [SFMenuOption option:@"Ton" action:^{ [self showSoundOn:nav]; }];
        sound.detail = [outputs.firstObject current] ? [outputs.firstObject name] : nil;
        [opts addObject:sound];
        [opts addObject:[SFMenuOption option:@"Energie" action:^{ [SFPower showPowerMenuOn:nav]; }]];
        [opts addObject:[SFMenuOption option:@"Einstellungen" action:^{ [SFHome showSettingsOn:nav]; }]];
        SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:@"Sofa" subtitle:nil options:opts theme:nav.top.theme];
        gOpen = m;
        SFLog(@"menu: quick menu - %@", [[opts valueForKey:@"title"] componentsJoinedByString:@", "]);
        [nav push:m];
    }];
}

// Where the sound comes out: every output the Mac has (the current one marked; choosing one moves
// the sound and the volume control there at once), the paired Bluetooth audio devices to connect or
// disconnect, and pairing new headphones
+ (void)showSoundOn:(SFNavigator *)nav {
    [SFAudioOutput outputs:^(NSArray *outputs) {
        NSMutableArray *opts = [NSMutableArray new];
        for (SFAudioOutput *o in outputs) {
            SFMenuOption *opt = [SFMenuOption option:o.name action:^{
                if (o.current) return;
                [SFAudioOutput choose:o done:^(BOOL ok) {
                    [nav toast:ok ? [NSString stringWithFormat:@"Ton über %@", o.name] : @"Dieser Ausgang lässt sich gerade nicht wählen"];
                }];
            }];
            opt.detail = o.current ? @"Aktiv" : (o.bluetooth ? @"Bluetooth" : nil);
            [opts addObject:opt];
        }
        if (!opts.count) [opts addObject:[SFMenuOption option:@"Kein Tonausgang gefunden" action:^{}]];
        if ([SFBluetooth poweredOn]) {
            for (SFBluetoothDevice *d in [SFBluetooth pairedAudioDevices]) {
                SFMenuOption *opt;
                if (d.connected) opt = [SFMenuOption option:[NSString stringWithFormat:@"%@ trennen", d.name ?: d.address] action:^{
                    [SFBluetooth disconnect:d];
                    [nav toast:[NSString stringWithFormat:@"%@ getrennt", d.name ?: d.address]];
                }];
                else {
                    opt = [SFMenuOption option:d.name ?: d.address action:^{ [self use:d pair:NO on:nav]; }];
                    opt.detail = @"Verbinden";
                }
                [opts addObject:opt];
            }
            [opts addObject:[SFMenuOption option:@"Kopfhörer koppeln" action:^{ [self showPairingOn:nav]; }]];
        } else {
            SFMenuOption *off = [SFMenuOption option:@"Bluetooth ist ausgeschaltet" action:^{}];
            off.keepOpen = YES;
            [opts addObject:off];
        }
        SFLog(@"menu: sound - %@", [[opts valueForKey:@"title"] componentsJoinedByString:@", "]);
        [nav push:[[SFMenuScreen alloc] initWithTitle:@"Ton" subtitle:@"Wo der Ton herauskommt" options:opts theme:nav.top.theme]];
    }];
}

// Pairing: the search's finds fill the list while it is open; choosing one pairs (or, paired
// already, connects) it and moves the sound there
+ (void)showPairingOn:(SFNavigator *)nav {
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:@"Kopfhörer koppeln"
        subtitle:@"Kopfhörer einschalten und in den Kopplungsmodus bringen – meist die Einschalttaste einige Sekunden halten, bis ein Licht blinkt."
        options:@[] theme:nav.top.theme];
    m.subtitleLines = 3;
    NSMutableArray *order = [NSMutableArray new];          // addresses as found
    NSMutableDictionary *found = [NSMutableDictionary new];   // address -> SFBluetoothDevice (the latest)
    __block BOOL searching = NO;
    __weak SFMenuScreen *wm = m;
    __block void (^search)(void);
    // the search's state on top, the finds appended below it: nothing moves while the list fills
    // and the selection stays where it is
    void (^refresh)(void) = ^{
        NSMutableArray *opts = [NSMutableArray new];
        SFMenuOption *more;
        if (searching) more = [SFMenuOption option:@"Suche läuft …" action:^{}];
        else more = [SFMenuOption option:order.count ? @"Erneut suchen" : @"Nichts gefunden – erneut suchen" action:^{ search(); }];
        more.keepOpen = YES;
        [opts addObject:more];
        for (NSString *a in order) {
            SFBluetoothDevice *d = found[a];
            SFMenuOption *o = [SFMenuOption option:d.name ?: @"Gerät wird erkannt …" action:^{
                [SFBluetooth stopSearch];
                if (d.connected) return;
                [self use:d pair:!d.paired on:nav];
            }];
            o.detail = d.paired ? @"Gekoppelt" : @"Koppeln";
            [opts addObject:o];
        }
        [wm setOptions:opts];
    };
    search = ^{
        searching = YES;
        refresh();
        [SFBluetooth search:^(SFBluetoothDevice *d) {
            if (!found[d.address]) [order addObject:d.address];
            found[d.address] = d;
            SFLog(@"bluetooth: found %@ (%@)", d.name ?: @"?", d.paired ? @"paired" : @"new");
            refresh();
        } done:^{ searching = NO; refresh(); }];
    };
    m.onDisappear = ^{ [SFBluetooth stopSearch]; search = nil; };   // (the block cycle ends here)
    [nav push:m];
    search();
}

// Pair (if asked) and connect a Bluetooth audio device, then move the sound to its output once it
// is there (CoreAudio adds it a moment after the connection)
+ (void)use:(SFBluetoothDevice *)d pair:(BOOL)pair on:(SFNavigator *)nav {
    NSString *name = d.name ?: d.address;
    [nav toast:[NSString stringWithFormat:pair ? @"Kopple %@ …" : @"Verbinde %@ …", name]];
    void (^connected)(BOOL) = ^(BOOL ok) {
        if (!ok) { [nav toast:[NSString stringWithFormat:pair ? @"Koppeln mit %@ hat nicht geklappt" : @"%@ ist nicht erreichbar – eingeschaltet?", name]]; return; }
        [SFAudioOutput waitForOutput:d.address timeout:10 done:^(SFAudioOutput *o) {
            if (!o) { SFLog(@"bluetooth: %@ connected, no sound output", name); [nav toast:[NSString stringWithFormat:@"%@ verbunden, aber ohne Tonausgang", name]]; return; }
            // macOS usually moves the sound to a connecting headset by itself: one more switch would
            // only add a change while the device comes up (each one reloads the player's output)
            if (o.current) { [nav toast:[NSString stringWithFormat:@"Ton über %@", o.name]]; return; }   // (checked by itself)
            [SFAudioOutput verify:o done:^(BOOL plays) {
                if (!plays) { [nav toast:[NSString stringWithFormat:@"%@ ist verbunden, spielt aber keinen Ton – ist es noch mit einem anderen Gerät verbunden?", name]]; return; }
                [SFAudioOutput choose:o done:^(BOOL chosen) {
                    [nav toast:chosen ? [NSString stringWithFormat:@"Ton über %@", o.name] : [NSString stringWithFormat:@"%@ verbunden", name]];
                }];
            }];
        }];
    };
    if (pair) [SFBluetooth pair:d done:connected]; else [SFBluetooth connect:d done:connected];
}
@end
