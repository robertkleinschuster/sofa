#import "SFPlayerScreen+Private.h"

NSString *const SFPlayerSubtitlesNotification = @"SFPlayerSubtitlesNotification";

static NSDictionary *SFSubtitleStateOf(NSDictionary *choice) {
    NSString *lang = choice[@"lang"];
    if (!lang.length) return nil;   // "Aus" (off)
    return @{@"lang": lang, @"kind": choice[@"kind"] ?: @"manual", @"title": choice[@"title"] ?: lang};
}

// Report the chosen track (phone/Lounge) - with the choice itself, since mpv applies sub-add only asynchronously
static void SFPostSubtitles(SFPlayerScreen *p, NSDictionary *state) {
    [[NSNotificationCenter defaultCenter] postNotificationName:SFPlayerSubtitlesNotification object:p userInfo:state ?: @{}];
}

@implementation SFPlayerScreen (Tracks)

#pragma mark Audio & subtitles

- (BOOL)tracksAvailable {
    return [_engine respondsToSelector:@selector(tracksOfType:)] && _engine.status == SFEngineReady;
}

// "en-US" -> "Englisch" (drop the region; the script stays: "Chinesisch (Vereinfacht)");
// ISO 639-2 ("deu") is understood as well
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

// Choices: per entry title, selected, apply (block), lang (for the preference)
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
    // source with its own track list (YouTube): audio tracks per language, subtitles as WebVTT
    NSArray *ext = [type isEqualToString:@"sub"] ? src[@"subs"] : src[@"audios"];
    if (![ext isKindOfClass:[NSArray class]]) ext = @[];
    NSString *dashAudio = src[@"audio"];
    // order: German, then the original language (audio: original first), then alphabetical
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
        [out addObject:@{@"title": name, @"selected": @(sel), @"lang": t[@"lang"] ?: @"", @"kind": t[@"kind"] ?: @"manual",
                         @"apply": ^{ [eng addTrack:type url:[NSURL URLWithString:url] title:n lang:t[@"lang"]]; }}];
    }
    // tracks in the stream itself (ZDF/ARD/ORF HLS, files): everything not already listed above
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

// Downloaded: the file only has the downloaded audio track - online there are all audio and
// subtitle tracks (user request 2026-11-04: be able to switch to the stream)
- (BOOL)canSwitchToStream {
    return _openURL.isFileURL && (_item.resolverRef || _item.externalID) && _item.kind == SFItemVideo;
}

// Switch from the download to the online stream, at the same position
- (void)switchToStream {
    SFItem *it = [_item copy];
    it.localPath = nil; it.playURL = nil; it.streamOnly = YES;   // otherwise the download lookup finds the file again
    if (!it.resolverRef) it.resolverRef = it.identifier;   // e.g. "yt:<id>": the identifier is the app's ref
    NSMutableArray *q = [_queue mutableCopy];
    if (_index < q.count) q[_index] = it;
    SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:it queue:q index:_index];
    ps.remoteListID = self.remoteListID;
    NSTimeInterval t = [self currentTime];
    if (t > 1) ps.startPosition = t; else ps.startFromBeginning = YES;
    SFLog(@"player: Download -> online at %.0f s", t);
    SFNavigator *nav = self.navigator;
    [nav popAbove:self];   // chosen in the info panel: replace the player, not the panel
    [nav replaceTop:ps];
}

- (void)showChoices:(NSArray *)choices type:(NSString *)type title:(NSString *)title on:(SFNavigator *)nav {
    NSMutableArray *opts = [NSMutableArray new];
    NSInteger sel = 0;
    for (NSDictionary *c in choices) {
        if ([c[@"selected"] boolValue]) sel = opts.count;
        NSString *t = c[@"title"], *lang = c[@"lang"];
        SFMenuOption *o = [SFMenuOption option:t action:^{
            // the stream may have been reopened while the menu was up: the choice as the engine
            // playing now has it (by title), never the engine the menu was built for
            NSArray *now = [self tracksAvailable] ? [self trackChoices:type] : nil;
            NSDictionary *cur = [self choiceTitled:t in:now];
            if (!cur) { [nav toast:[NSString stringWithFormat:@"%@: %@ gerade nicht verfügbar", title, t]]; return; }
            ((dispatch_block_t)cur[@"apply"])();
            if ([type isEqualToString:@"sub"]) {
                [self rememberSubtitle:lang choices:now];   // remember for the next videos
                SFPostSubtitles(self, SFSubtitleStateOf(cur));                       // bring the phone (Lounge) up to date
            }
            [nav toast:[NSString stringWithFormat:@"%@: %@", title, t]];
        }];
        if ([c[@"selected"] boolValue]) o.detail = @"✓";
        [opts addObject:o];
    }
    SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:title subtitle:_item.title options:opts theme:self.theme];
    m.initialSelection = sel;
    [nav push:m];
}

// Apply the remembered subtitle language (real before automatic before translated subtitles)
// Language of the playing audio (base code, e.g. "de"); nil = unknown
- (NSString *)audioLanguage {
    for (NSDictionary *t in [_engine tracksOfType:@"audio"])
        if ([t[@"selected"] boolValue] && [t[@"lang"] length] && ![t[@"lang"] isEqualToString:@"und"]) return SFBaseLanguage(t[@"lang"]);
    NSDictionary *src = SFMPVSourceFor(_openURL);
    if (_openedDash && src[@"alang"]) return SFBaseLanguage(src[@"alang"]);
    for (NSDictionary *t in src[@"audios"] ?: @[]) if ([t[@"original"] boolValue]) return SFBaseLanguage(t[@"lang"]);
    return SFBaseLanguage(src[@"alang"]);
}

// Remember the choice - separated by purpose: subtitles in the audio language (hearing impaired) apply
// to all videos of that kind; another language is a translation and only applies to foreign-language
// audio. So "Deutsch" for an English video doesn't also turn on subtitles for every ZDF show.
- (void)rememberSubtitle:(NSString *)lang choices:(NSArray *)choices {
    NSString *audio = [self audioLanguage], *base = SFBaseLanguage(lang);
    if (base) {
        if (audio && [base isEqualToString:audio]) SFSetSubtitlesSameLanguage(YES);
        else SFSetSubtitleLanguage(base);
        return;
    }
    // "Aus" (off): only switch off the preference that just applied here
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
    if (audio && [want isEqualToString:audio]) want = nil;   // no translation needed
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
    SFPostSubtitles(self, SFSubtitleStateOf(pick));
    SFLog(@"player: subtitles %@ (remembered language, audio %@)", pick[@"title"], audio ?: @"?");
}

#pragma mark Track carry (reopen)

- (NSDictionary *)chosenTracks {
    if (![self tracksAvailable]) return nil;
    NSMutableDictionary *out = [NSMutableDictionary new];
    for (NSString *type in @[@"audio", @"sub"])
        for (NSDictionary *c in [self trackChoices:type]) if ([c[@"selected"] boolValue]) { out[type] = c[@"title"]; break; }
    return out;
}

// Choices are matched by title: a reopened session may hand out new URLs and ids for the same
// tracks, the names stay
- (NSDictionary *)choiceTitled:(NSString *)title in:(NSArray *)choices {
    for (NSDictionary *c in choices) if ([c[@"title"] isEqualToString:title]) return c;
    return nil;
}

- (void)restoreTracks:(NSDictionary *)tracks {
    if (![self tracksAvailable]) return;
    for (NSString *type in tracks) {
        NSDictionary *c = [self choiceTitled:tracks[type] in:[self trackChoices:type]];
        if (!c || [c[@"selected"] boolValue]) continue;
        ((dispatch_block_t)c[@"apply"])();
        if ([type isEqualToString:@"sub"]) SFPostSubtitles(self, SFSubtitleStateOf(c));
        SFLog(@"player: %@ track %@ kept across the reopen", type, c[@"title"]);
    }
}

@end

#pragma mark - Subtitles from the phone (Lounge)

@implementation SFPlayerScreen (Subtitles)

- (NSDictionary *)subtitleState {
    if (![self tracksAvailable]) return nil;
    for (NSDictionary *c in [self trackChoices:@"sub"]) if ([c[@"selected"] boolValue]) return SFSubtitleStateOf(c);
    return nil;
}

// Like the choice in the menu (incl. remembering the preference): exact language before base language,
// the requested kind (real/automatic) before the other, translated last
- (NSString *)remoteSelectSubtitles:(NSString *)lang autoGenerated:(BOOL)autoGenerated {
    if (![self tracksAvailable]) return nil;
    NSArray *choices = [self trackChoices:@"sub"];
    NSDictionary *pick = nil;
    if (!lang.length) {
        pick = choices.firstObject;   // "Aus" (off)
    } else {
        NSString *want = SFBaseLanguage(lang);
        int best = 0;
        for (NSDictionary *c in choices) {
            NSString *cl = c[@"lang"];
            if (!cl.length || ![SFBaseLanguage(cl) isEqualToString:want]) continue;
            NSString *kind = c[@"kind"] ?: @"manual";
            int score = [kind isEqualToString:@"translated"] ? 1 : ([kind isEqualToString:@"auto"] == autoGenerated ? 4 : 2);
            if ([cl caseInsensitiveCompare:lang] == NSOrderedSame) score += 4;
            if (score > best) { best = score; pick = c; }
        }
    }
    if (!pick) {   // not available: reset the phone to the actual state
        SFPostSubtitles(self, [self subtitleState]);
        return nil;
    }
    ((dispatch_block_t)pick[@"apply"])();
    [self rememberSubtitle:pick[@"lang"] choices:choices];
    SFPostSubtitles(self, SFSubtitleStateOf(pick));
    SFLog(@"player: subtitles from the phone: %@", pick[@"title"]);
    return pick[@"title"];
}

@end
