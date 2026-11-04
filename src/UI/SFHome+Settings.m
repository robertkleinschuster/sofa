// SFHome – settings (start & remote, subtitles, updates with release notes) and
// the phone tile (YouTube → Mehr) that opens the connection settings.
#import "SFHome+Private.h"
#import "SFMenuScreen.h"
#import "SFSettings.h"
#import "SFUpdater.h"
#import "SFRuntime.h"
#import "SFLounge.h"
#import "SFPairScreen.h"

@implementation SFHome (Settings)

#pragma mark Settings (start & remote)

+ (SFItem *)settingsTile {
    SFItem *i = [SFItem new];
    i.kind = SFItemAction;
    i.identifier = @"settings:";
    i.title = @"Einstellungen";
    i.subtitle = @"Start, Fernbedienung, Untertitel, Updates";
    i.plot = @"Festlegen, ob Sofa beim Anmelden startet, ob die Apple Remote Sofa öffnet und wann Untertitel mitlaufen. Nach Updates suchen und sehen, was neu ist.";
    i.themeName = @"home";
    i.style = SFTileStyleApp; i.tint = SFHex(0x566573);
    i.action = ^{
        id d = [NSApp delegate];
        SFNavigator *nav = [d respondsToSelector:@selector(nav)] ? [d performSelector:@selector(nav)] : nil;
        if (nav) [SFHome showSettingsOn:nav];
    };
    return i;
}

+ (void)showSettingsOn:(SFNavigator *)nav { [nav push:[self settingsMenu:nav selection:0]]; }

// Settings: switches + update. Every change rebuilds the menu at the same row.
// gSettingsMenu = the settings menu currently visible (later callbacks too, e.g. after the
// update check, rebuild the current one – not the one they were started from).
static __weak SFMenuScreen *gSettingsMenu;
+ (SFMenuScreen *)settingsMenu:(SFNavigator *)nav selection:(NSInteger)sel {
    SFUpdater *up = [SFUpdater shared];
    void (^refresh)(void) = ^{
        SFMenuScreen *m = gSettingsMenu;
        if (m && nav.top == m) [nav replaceTop:[SFHome settingsMenu:nav selection:m.selectedIndex]];
    };
    SFMenuOption *(^toggle)(NSString *, BOOL, void (^)(BOOL), NSString *, NSString *) =
        ^SFMenuOption *(NSString *title, BOOL on, void (^set)(BOOL), NSString *onText, NSString *offText) {
        SFMenuOption *o = [SFMenuOption option:title action:^{
            set(!on);
            [nav toast:!on ? onText : offText];
            refresh();
        }];
        o.detail = on ? @"An" : @"Aus";
        o.keepOpen = YES;
        return o;
    };
    NSMutableArray *opts = [NSMutableArray new];
    [opts addObject:toggle(@"Beim Anmelden starten", SFAutostartEnabled(), ^(BOOL v) { SFSetAutostartEnabled(v); },
                           @"Sofa startet beim Anmelden automatisch", @"Sofa startet nicht mehr automatisch")];
    [opts addObject:toggle(@"Mit der Apple Remote starten", SFRemoteLaunchEnabled(), ^(BOOL v) { SFSetRemoteLaunchEnabled(v); },
                           @"Jede Taste der Apple Remote öffnet Sofa", @"Ist Sofa geschlossen, steuert die Apple Remote wieder den Mac")];
    // subtitles: the same two preferences that "Ton & Untertitel" in the player remembers (hold OK)
    [opts addObject:toggle(@"Untertitel zum Mitlesen", SFSubtitlesSameLanguage(), ^(BOOL v) { SFSetSubtitlesSameLanguage(v); },
                           @"Untertitel laufen mit, wo die Sendung welche hat (z.B. für Hörgeschädigte)",
                           @"Bei Sendungen in der Sprache des Tons keine Untertitel")];
    NSString *foreign = SFSubtitleLanguage();
    SFMenuOption *fo = [SFMenuOption option:@"Untertitel übersetzt" action:^{
        SFSetSubtitleLanguage(foreign ? nil : @"de");
        [nav toast:foreign ? @"Fremdsprachige Videos laufen ohne Untertitel"
                           : @"Fremdsprachige Videos bekommen deutsche Untertitel, wo vorhanden"];
        refresh();
    }];
    NSString *fname = foreign ? [[NSLocale localeWithLocaleIdentifier:@"de"] displayNameForKey:NSLocaleLanguageCode value:foreign] : nil;
    fo.detail = foreign ? (fname.length ? [[fname substringToIndex:1].uppercaseString stringByAppendingString:[fname substringFromIndex:1]] : foreign) : @"Aus";
    fo.keepOpen = YES;
    [opts addObject:fo];
    NSString *subtitle = [@"Version " stringByAppendingString:up.installedVersion];
    if (up.available) {
        [opts addObject:toggle(@"Automatisch aktualisieren", SFAutoUpdateEnabled(), ^(BOOL v) { SFSetAutoUpdateEnabled(v); },
                               @"Updates werden geladen und installiert, wenn Sofa ruht", @"Updates nur noch über „Nach Updates suchen“")];
        SFMenuOption *u;
        if (up.updateAvailable) {
            subtitle = [NSString stringWithFormat:@"Installiert: %@ · Verfügbar: %@", up.installedVersion, up.latestVersion];
            u = [SFMenuOption option:@"Update installieren" action:^{ [nav push:[SFHome releaseNotesMenu:nav]]; }];
            u.detail = [NSString stringWithFormat:@"%@ → %@", up.installedVersion, up.latestVersion];
        } else {
            if (up.lastCheck) subtitle = [subtitle stringByAppendingString:@" · aktuell"];
            u = [SFMenuOption option:up.busy ? @"Suche läuft …" : @"Nach Updates suchen" action:^{
                [[SFUpdater shared] check:^(NSString *msg) { [nav toast:msg]; refresh(); }];
                refresh();
            }];
            if (up.lastCheck) {
                NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"HH:mm";
                u.detail = [@"zuletzt " stringByAppendingString:[f stringFromDate:up.lastCheck]];
            }
        }
        u.keepOpen = YES;
        [opts addObject:u];
    } else if (SFRuntimeDir()) {
        subtitle = [subtitle stringByAppendingString:@" · Updates erst, wenn Sofa in „Programme“ liegt"];
    }
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:@"Einstellungen" subtitle:subtitle
                                                  options:opts theme:[SFTheme themeNamed:@"home"]];
    m.initialSelection = sel;
    gSettingsMenu = m;
    return m;
}

// Manual update: first show what is new (release notes from GitHub), then decide
+ (SFMenuScreen *)releaseNotesMenu:(SFNavigator *)nav {
    SFUpdater *up = [SFUpdater shared];
    NSMutableArray *lines = [NSMutableArray new];
    for (NSString *raw in [up.releaseNotes ?: @"" componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([l rangeOfString:@"sofa-notes-end"].location != NSNotFound) break;   // after this: only for the release page
        if (!l.length || [l hasPrefix:@"#"] || [l hasPrefix:@"<!--"]) continue;
        l = [l stringByReplacingOccurrencesOfString:@"**" withString:@""];
        l = [l stringByReplacingOccurrencesOfString:@"`" withString:@""];
        if ([l hasPrefix:@"- "] || [l hasPrefix:@"* "]) l = [@"•  " stringByAppendingString:[l substringFromIndex:2]];
        [lines addObject:l];
    }
    if (!lines.count) [lines addObject:@"Für diese Version gibt es keine Beschreibung."];
    SFMenuOption *go = [SFMenuOption option:@"Jetzt installieren" action:^{
        [[SFUpdater shared] install:^(NSString *msg) { [nav toast:msg]; }];
    }];
    go.detail = [NSString stringWithFormat:@"%@ → %@", up.installedVersion, up.latestVersion];
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:[@"Neu in Sofa " stringByAppendingString:up.latestVersion ?: @""]
        subtitle:[lines componentsJoinedByString:@"\n"]
        options:@[go, [SFMenuOption option:@"Später" action:^{}]] theme:[SFTheme themeNamed:@"home"]];
    m.subtitleLines = 14;
    return m;
}

#pragma mark Phone (YouTube "Mit TV verbinden") – settings reachable directly from Home

+ (SFItem *)phoneTile {
    // One tile that adapts to the situation (YouTube → Mehr):
    //  no phone connected    -> "Mit Handy verbinden" opens the code directly (OK there = settings)
    //  connected / paused    -> "Handy: Name" / "Handy pausiert" opens the settings
    SFLounge *l = [SFLounge shared];
    NSArray *n = l.remoteNames;
    BOOL active = l.paused || n.count;
    SFItem *i = [SFItem new];
    i.kind = SFItemAction;
    i.identifier = @"phone:";
    i.title = l.paused ? @"Handy pausiert" : n.count ? [@"Handy: " stringByAppendingString:[n componentsJoinedByString:@", "]] : @"Mit Handy verbinden";
    i.subtitle = active ? @"Verbindung verwalten" : @"Videos vom Handy auf den Fernseher schicken";
    i.plot = active ? @"Verbindung pausieren oder fortsetzen, festlegen was das Handy sieht, ein weiteres Handy verbinden oder alle trennen."
                    : @"YouTube-App am Handy öffnen und mit dem TV-Code verbinden. Danach findet das Handy Sofa von selbst.";
    i.themeName = @"youtube";
    i.action = ^{
        id d = [NSApp delegate];
        SFNavigator *nav = [d respondsToSelector:@selector(nav)] ? [d performSelector:@selector(nav)] : nil;
        if (!nav) return;
        SFLounge *ll = [SFLounge shared];
        if (ll.paused || ll.remoteNames.count) [SFPairScreen showConnectionMenuOn:nav];
        else [nav push:[[SFPairScreen alloc] initWithTheme:[SFTheme themeNamed:@"youtube"]]];
    };
    return i;
}

@end
