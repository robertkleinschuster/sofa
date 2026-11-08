#import "SFQuickMenu.h"
#import "SFMenuScreen.h"
#import "SFAudioOutput.h"
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

// Where the sound comes out: every output the Mac has, the current one marked; choosing one moves
// the sound (and the volume control) there at once
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
        [nav push:[[SFMenuScreen alloc] initWithTitle:@"Ton" subtitle:@"Wo der Ton herauskommt" options:opts theme:nav.top.theme]];
    }];
}
@end
