// SFHome – settings (start & remote, subtitles, updates with release notes) and
// the phone tile (YouTube → Mehr) that opens the connection settings.
#import "SFHome.h"
#import "SFMenuScreen.h"
#import "SFSettings.h"
#import "SFUpdater.h"
#import "SFRuntime.h"

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
        SFNavigator *nav = [SFNavigator main];
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
    NSString *installed = up.installedVersion;
    if (SFBundledNotes(installed)) [opts addObject:[SFMenuOption option:[NSString stringWithFormat:@"Neu in Version %@", installed]
                                                                 action:^{ [nav push:[SFHome installedNotesMenu:installed nav:nav]]; }]];
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:@"Einstellungen" subtitle:subtitle
                                                  options:opts theme:[SFTheme themeNamed:@"home"]];
    m.initialSelection = sel;
    gSettingsMenu = m;
    return m;
}

// Manual update: first show what is new (release notes from GitHub), then decide
// Changelog Markdown -> plain lines for a menu text: bullets "•", continuation lines joined to their
// bullet (the Markdown wraps at ~100 columns, the menu wraps itself), no emphasis/code marks.
static NSArray *SFNotesLinesBold(NSString *md, BOOL keepBold) {
    NSMutableArray *lines = [NSMutableArray new];
    for (NSString *raw in [md ?: @"" componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([l rangeOfString:@"sofa-notes-end"].location != NSNotFound) break;   // after this: only for the release page
        if (!l.length || [l hasPrefix:@"#"] || [l hasPrefix:@"<!--"]) continue;
        if (!keepBold) l = [l stringByReplacingOccurrencesOfString:@"**" withString:@""];
        l = [l stringByReplacingOccurrencesOfString:@"`" withString:@""];
        BOOL bullet = [l hasPrefix:@"- "] || [l hasPrefix:@"* "];
        if (bullet) l = [@"•  " stringByAppendingString:[l substringFromIndex:2]];
        if (!bullet && lines.count && [raw hasPrefix:@" "]) lines[lines.count - 1] = [lines.lastObject stringByAppendingFormat:@" %@", l];
        else [lines addObject:l];
    }
    if (!lines.count) [lines addObject:@"Für diese Version gibt es keine Beschreibung."];
    return lines;
}
static NSArray *SFNotesLines(NSString *md) { return SFNotesLinesBold(md, NO); }

// The section "## <version>" of the bundled CHANGELOG.md (nil if missing)
static NSString *SFBundledNotes(NSString *version) {
    NSString *md = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"CHANGELOG" ofType:@"md"] encoding:NSUTF8StringEncoding error:nil];
    NSRange h = version.length ? [md rangeOfString:[NSString stringWithFormat:@"\n## %@\n", version]] : (NSRange){NSNotFound, 0};
    if (!md || h.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(h);
    NSRange next = [md rangeOfString:@"\n## " options:0 range:NSMakeRange(start, md.length - start)];
    return [md substringWithRange:NSMakeRange(start, (next.location == NSNotFound ? md.length : next.location) - start)];
}

// "Neu in Version …" for the installed version (from the bundle - works offline): one row per
// change (its bold lead), OK shows the whole text - the side panel is too narrow for all of it at once
+ (SFMenuScreen *)installedNotesMenu:(NSString *)version nav:(SFNavigator *)nav {
    NSMutableArray *opts = [NSMutableArray new];
    for (NSString *line in SFNotesLinesBold(SFBundledNotes(version), YES)) {
        // "**Lead:** text" -> row "Lead", details "text"; "**Lead** text" -> row "Lead", details all
        NSString *md = [line hasPrefix:@"•  "] ? [line substringFromIndex:3] : line;
        NSString *text = [md stringByReplacingOccurrencesOfString:@"**" withString:@""], *head = text, *body = nil;
        NSRange end = [md hasPrefix:@"**"] ? [md rangeOfString:@"**" options:0 range:NSMakeRange(2, md.length - 2)] : (NSRange){NSNotFound, 0};
        if (end.location != NSNotFound) {
            head = [md substringWithRange:NSMakeRange(2, end.location - 2)];
            if ([head hasSuffix:@":"]) {
                head = [head substringToIndex:head.length - 1];
                body = [[md substringFromIndex:NSMaxRange(end)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                body = [body stringByReplacingOccurrencesOfString:@"**" withString:@""];
            } else body = text;
        }
        if (head.length > 60) head = [[head substringToIndex:57] stringByAppendingString:@" …"];
        SFMenuOption *o = [SFMenuOption option:head action:^{
            SFMenuScreen *d = [[SFMenuScreen alloc] initWithTitle:head subtitle:body ?: text
                options:@[[SFMenuOption option:@"Zurück" action:^{}]] theme:[SFTheme themeNamed:@"home"]];
            d.subtitleLines = 16;
            [nav push:d];
        }];
        o.keepOpen = YES;
        [opts addObject:o];
    }
    return [[SFMenuScreen alloc] initWithTitle:[@"Neu in Sofa " stringByAppendingString:version]
        subtitle:@"OK zeigt die Einzelheiten." options:opts theme:[SFTheme themeNamed:@"home"]];
}

+ (SFMenuScreen *)releaseNotesMenu:(SFNavigator *)nav {
    SFUpdater *up = [SFUpdater shared];
    NSArray *lines = SFNotesLines(up.releaseNotes);
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

@end
