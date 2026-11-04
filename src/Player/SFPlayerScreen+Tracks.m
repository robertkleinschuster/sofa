#import "SFPlayerScreen+Private.h"

@implementation SFPlayerScreen (Tracks)

#pragma mark Ton & Untertitel

- (BOOL)tracksAvailable {
    return [_engine respondsToSelector:@selector(tracksOfType:)] && _engine.status == SFEngineReady;
}

- (void)updateTrackHint {
    float op = [self tracksAvailable] ? 1 : 0;
    SFNoAnimate(^{ self->_trackHint.opacity = op; self->_trackKey.opacity = op; });
}

// „en-US“ -> „Englisch“ (Region weglassen; Schrift bleibt: „Chinesisch (Vereinfacht)“);
// ISO 639-2 („deu“) wird ebenfalls verstanden
static NSString *SFLanguageName(NSString *code) {
    if (!code.length || [code isEqualToString:@"und"]) return @"Unbekannte Sprache";
    NSDictionary *c = [NSLocale componentsFromLocaleIdentifier:[NSLocale canonicalLocaleIdentifierFromString:code]];
    NSMutableDictionary *k = [NSMutableDictionary new];
    if (c[NSLocaleLanguageCode]) k[NSLocaleLanguageCode] = c[NSLocaleLanguageCode];
    if (c[NSLocaleScriptCode]) k[NSLocaleScriptCode] = c[NSLocaleScriptCode];
    NSString *canon = [NSLocale localeIdentifierFromComponents:k];
    NSString *n = [[NSLocale localeWithLocaleIdentifier:@"de"] displayNameForKey:NSLocaleIdentifier value:canon];
    if (!n.length) return code;
    return [[n substringToIndex:1].uppercaseString stringByAppendingString:[n substringFromIndex:1]];
}
static NSString *SFBaseLanguage(NSString *code) {
    if (!code.length) return nil;
    NSString *canon = [NSLocale canonicalLanguageIdentifierFromString:code];
    return [[canon componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]].firstObject lowercaseString];
}

// Auswahlmöglichkeiten: je Eintrag title, selected, apply (Block), lang (für die Vorliebe)
- (NSArray *)trackChoices:(NSString *)type {
    NSMutableArray *out = [NSMutableArray new];
    NSDictionary *src = SFMPVSourceFor(_openURL);
    NSArray *engineTracks = [_engine tracksOfType:type];
    NSMutableSet *externalURLs = [NSMutableSet new];
    NSString *selectedURL = nil; NSInteger selectedID = 0;
    for (NSDictionary *t in engineTracks) {
        if (t[@"url"]) [externalURLs addObject:t[@"url"]];
        if ([t[@"selected"] boolValue]) { selectedURL = t[@"url"]; selectedID = [t[@"id"] integerValue]; }
    }
    id<SFEngine> eng = _engine;
    if ([type isEqualToString:@"sub"]) {
        [out addObject:@{@"title": @"Aus", @"selected": @(selectedID == 0),
                         @"apply": ^{ [eng selectTrack:@"sub" trackID:0]; }}];
    }
    // Quelle mit eigener Spurliste (YouTube): Tonspuren je Sprache, Untertitel als WebVTT
    NSArray *ext = [type isEqualToString:@"sub"] ? src[@"subs"] : src[@"audios"];
    if (![ext isKindOfClass:[NSArray class]]) ext = @[];
    NSString *dashAudio = src[@"audio"];
    // Reihenfolge: Deutsch, dann Originalsprache (Ton: Original zuerst), dann alphabetisch
    NSString *origLang = nil;
    for (NSDictionary *t in src[@"audios"] ?: @[]) if ([t[@"original"] boolValue]) origLang = SFBaseLanguage(t[@"lang"]);
    if (!origLang) origLang = SFBaseLanguage(src[@"alang"]);
    NSInteger (^rank)(NSDictionary *) = ^NSInteger(NSDictionary *t) {
        if ([t[@"original"] boolValue]) return 0;
        NSString *b = SFBaseLanguage(t[@"lang"]);
        if ([b isEqualToString:@"de"]) return 1;
        if (origLang && [b isEqualToString:origLang]) return 2;
        return 3;
    };
    ext = [ext sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger ra = rank(a), rb = rank(b);
        if (ra != rb) return ra < rb ? NSOrderedAscending : NSOrderedDescending;
        int ka = [a[@"kind"] isEqual:@"manual"] ? 0 : [a[@"kind"] isEqual:@"auto"] ? 1 : 2;
        int kb = [b[@"kind"] isEqual:@"manual"] ? 0 : [b[@"kind"] isEqual:@"auto"] ? 1 : 2;
        if (ka != kb) return ka < kb ? NSOrderedAscending : NSOrderedDescending;
        return [SFLanguageName(a[@"lang"]) localizedCaseInsensitiveCompare:SFLanguageName(b[@"lang"])];
    }];
    for (NSDictionary *t in ext) {
        NSString *name = SFLanguageName(t[@"lang"]);
        if ([type isEqualToString:@"sub"]) {
            if ([t[@"kind"] isEqual:@"auto"]) name = [name stringByAppendingString:@" (automatisch)"];
            if ([t[@"kind"] isEqual:@"translated"]) name = [name stringByAppendingString:@" (automatisch übersetzt)"];
        } else {
            if ([t[@"original"] boolValue]) name = [name stringByAppendingString:@" · Original"];
            else if ([t[@"described"] boolValue]) name = [name stringByAppendingString:@" · Audiodeskription"];
            else if ([t[@"dubbed"] boolValue]) name = [name stringByAppendingString:@" · synchronisiert"];
        }
        NSString *url = t[@"url"];
        BOOL sel = selectedURL ? [selectedURL isEqualToString:url]
                               : ([type isEqualToString:@"audio"] && _openedDash && [url isEqualToString:dashAudio]);
        NSString *n = name;
        [out addObject:@{@"title": name, @"selected": @(sel), @"lang": t[@"lang"] ?: @"",
                         @"apply": ^{ [eng addTrack:type url:[NSURL URLWithString:url] title:n lang:t[@"lang"]]; }}];
    }
    // Spuren im Stream selbst (ZDF/ARD/ORF-HLS, Dateien): alles, was nicht oben schon steht
    BOOL haveExt = ext.count > 0;
    for (NSDictionary *t in engineTracks) {
        if (t[@"url"] && ([externalURLs containsObject:t[@"url"]] && (haveExt || [t[@"url"] isEqualToString:dashAudio]))) continue;
        NSString *name = t[@"lang"] ? SFLanguageName(t[@"lang"]) : nil;
        NSString *title = t[@"title"];
        if (title.length && ![title isEqualToString:name]) name = name ? [NSString stringWithFormat:@"%@ – %@", name, title] : title;
        if (!name) name = [NSString stringWithFormat:@"Spur %@", t[@"id"]];
        NSInteger tid = [t[@"id"] integerValue];
        [out addObject:@{@"title": name, @"selected": t[@"selected"] ?: @NO, @"lang": t[@"lang"] ?: @"",
                         @"apply": ^{ [eng selectTrack:type trackID:tid]; }}];
    }
    return out;
}

- (NSString *)currentChoice:(NSArray *)choices {
    for (NSDictionary *c in choices) if ([c[@"selected"] boolValue]) return c[@"title"];
    return choices.count ? [choices.firstObject[@"title"] isEqual:@"Aus"] ? @"Aus" : @"Standard" : @"–";
}

- (void)showTrackMenu {
    SFNavigator *nav = self.navigator;
    NSArray *audio = [self trackChoices:@"audio"], *subs = [self trackChoices:@"sub"];
    NSMutableArray *opts = [NSMutableArray new];
    __weak SFPlayerScreen *ws = self;
    SFMenuOption *a = [SFMenuOption option:@"Ton" action:^{
        dispatch_async(dispatch_get_main_queue(), ^{ [ws showChoices:audio type:@"audio" title:@"Ton" on:nav]; });
    }];
    a.detail = audio.count > 1 ? [self currentChoice:audio] : (audio.count ? [self currentChoice:audio] : @"nur eine Tonspur");
    SFMenuOption *u = [SFMenuOption option:@"Untertitel" action:^{
        dispatch_async(dispatch_get_main_queue(), ^{ [ws showChoices:subs type:@"sub" title:@"Untertitel" on:nav]; });
    }];
    u.detail = subs.count > 1 ? [self currentChoice:subs] : @"keine vorhanden";
    if (audio.count > 1) [opts addObject:a];
    if (subs.count > 1) [opts addObject:u];
    // Heruntergeladen: die Datei hat nur die geladene Tonspur – online gibt es alle Ton- und
    // Untertitelspuren (User-Wunsch 2026-11-04: auf den Stream wechseln können)
    if (_openURL.isFileURL && (_item.resolverRef || _item.externalID)) {
        SFMenuOption *o = [SFMenuOption option:@"Online abspielen" action:^{
            dispatch_async(dispatch_get_main_queue(), ^{ [ws switchToStream]; });
        }];
        o.detail = @"alle Spuren";
        [opts addObject:o];
    }
    if (!opts.count) { [nav toast:@"Dieses Video hat nur eine Tonspur und keine Untertitel"]; return; }
    [nav push:[[SFMenuScreen alloc] initWithTitle:@"Ton & Untertitel" subtitle:_item.title options:opts theme:self.theme]];
}

// Vom Download auf den Online-Stream wechseln, an derselben Stelle
- (void)switchToStream {
    SFItem *it = [_item copy];
    it.localPath = nil; it.playURL = nil; it.streamOnly = YES;   // sonst findet die Download-Suche die Datei wieder
    if (!it.resolverRef && it.externalID) it.resolverRef = [@"yt:" stringByAppendingString:it.externalID];
    NSMutableArray *q = [_queue mutableCopy];
    if (_index < q.count) q[_index] = it;
    SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:it queue:q index:_index];
    ps.remoteListID = self.remoteListID;
    NSTimeInterval t = [self currentTime];
    if (t > 1) ps.startPosition = t; else ps.startFromBeginning = YES;
    SFLog(@"player: Download -> online bei %.0f s", t);
    [self.navigator replaceTop:ps];
}

- (void)showChoices:(NSArray *)choices type:(NSString *)type title:(NSString *)title on:(SFNavigator *)nav {
    NSMutableArray *opts = [NSMutableArray new];
    NSInteger sel = 0;
    for (NSDictionary *c in choices) {
        if ([c[@"selected"] boolValue]) sel = opts.count;
        dispatch_block_t apply = c[@"apply"];
        NSString *t = c[@"title"], *lang = c[@"lang"];
        SFMenuOption *o = [SFMenuOption option:t action:^{
            apply();
            if ([type isEqualToString:@"sub"]) [self rememberSubtitle:lang choices:choices];   // für die nächsten Videos merken
            [nav toast:[NSString stringWithFormat:@"%@: %@", title, t]];
        }];
        if ([c[@"selected"] boolValue]) o.detail = @"✓";
        [opts addObject:o];
    }
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:title subtitle:_item.title options:opts theme:self.theme];
    m.initialSelection = sel;
    [nav push:m];
}

// Gemerkte Untertitelsprache anwenden (echte vor automatischen vor übersetzten Untertiteln)
// Sprache des laufenden Tons (Basis-Code, z.B. "de"); nil = unbekannt
- (NSString *)audioLanguage {
    for (NSDictionary *t in [_engine tracksOfType:@"audio"])
        if ([t[@"selected"] boolValue] && [t[@"lang"] length] && ![t[@"lang"] isEqualToString:@"und"]) return SFBaseLanguage(t[@"lang"]);
    NSDictionary *src = SFMPVSourceFor(_openURL);
    if (_openedDash && src[@"alang"]) return SFBaseLanguage(src[@"alang"]);
    for (NSDictionary *t in src[@"audios"] ?: @[]) if ([t[@"original"] boolValue]) return SFBaseLanguage(t[@"lang"]);
    return SFBaseLanguage(src[@"alang"]);
}

// Wahl merken – getrennt nach Zweck: Untertitel in der Tonsprache (Hörgeschädigte) gelten für alle
// Videos dieser Art; eine andere Sprache ist eine Übersetzung und gilt nur bei fremdsprachigem Ton.
// So schaltet „Deutsch“ zu einem englischen Video nicht auch bei jeder ZDF-Sendung Untertitel ein.
- (void)rememberSubtitle:(NSString *)lang choices:(NSArray *)choices {
    NSString *audio = [self audioLanguage], *base = SFBaseLanguage(lang);
    if (base) {
        if (audio && [base isEqualToString:audio]) SFSetSubtitlesSameLanguage(YES);
        else SFSetSubtitleLanguage(base);
        return;
    }
    // „Aus“: nur die Vorliebe abschalten, die hier gerade gegriffen hat
    NSString *was = nil;
    for (NSDictionary *c in choices) if ([c[@"selected"] boolValue]) was = SFBaseLanguage(c[@"lang"]);
    if (!was) return;
    if (audio && [was isEqualToString:audio]) SFSetSubtitlesSameLanguage(NO);
    else SFSetSubtitleLanguage(nil);
}

- (void)applyPreferredSubtitles {
    if (![self tracksAvailable]) return;
    NSString *audio = [self audioLanguage];
    NSString *want = SFSubtitleLanguage();
    if (audio && [want isEqualToString:audio]) want = nil;   // Übersetzung nicht nötig
    if (audio && SFSubtitlesSameLanguage()) want = audio;
    if (!want) return;
    NSDictionary *pick = nil; int best = 0;
    for (NSDictionary *c in [self trackChoices:@"sub"]) {
        if (![SFBaseLanguage(c[@"lang"]) isEqualToString:want]) continue;
        NSString *t = c[@"title"];
        int score = [t hasSuffix:@"(automatisch übersetzt)"] ? 1 : [t hasSuffix:@"(automatisch)"] ? 2 : 3;
        if (score > best) { best = score; pick = c; }
    }
    if (!pick) return;
    ((dispatch_block_t)pick[@"apply"])();
    SFLog(@"player: Untertitel %@ (gemerkte Sprache, Ton %@)", pick[@"title"], audio ?: @"?");
}

@end
