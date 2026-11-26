// SFWebServer - the JSON routes of Sofa im Browser (docs/pwa.md, "API"). Main thread: the same
// modules the TV's screens use (SFHome's pages, the apps, SFStore, SFWatchLater, SFFollows,
// SFDownloads, the TV's player through SFWebTV).
#import "SFWebServer+Private.h"
#import "SFHome.h"
#import "SFApp.h"
#import "SFStore.h"
#import "SFWatchLater.h"
#import "SFFollows.h"
#import "SFSearch.h"
#import "SFLibrary.h"
#import "SFUpdater.h"
#import "SFWebDevices.h"
#import "SFWebItems.h"
#import "SFWebStreams.h"
#import "SFWebTV.h"
#import "SFWebStatus.h"
#import "SFDownloads.h"
#import "SFJSON.h"
#import "SFWebErrors.h"

static const NSTimeInterval kPageTimeout = 45;

// What this Sofa offers within the API version (`hello`; docs/api.md "Versions", api/openapi.yaml
// `Feature`): a client asks for a feature, never for a Sofa version.
static NSArray *Features(void) {
    return @[@"error-codes", @"client-identity", @"discover", @"formats", @"session-formats", @"paused-streams",
             @"persistent-images", @"tv", @"downloads", @"status"];
}

static NSString *CSSColor(NSColor *c) {
    NSColor *x = [c colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    if (!x) return nil;
    return [NSString stringWithFormat:@"rgba(%d,%d,%d,%.3g)", (int)round(x.redComponent * 255), (int)round(x.greenComponent * 255),
            (int)round(x.blueComponent * 255), x.alphaComponent];
}

static NSDictionary *ThemeJSON(SFTheme *t) {
    NSMutableDictionary *d = [NSMutableDictionary new];
    NSDictionary *colors = @{@"background": t.background ?: [NSNull null], @"backgroundTop": t.backgroundTop ?: [NSNull null],
                             @"surface": t.surface ?: [NSNull null], @"text": t.text ?: [NSNull null], @"textDim": t.textDim ?: [NSNull null],
                             @"accent": t.accent ?: [NSNull null], @"accentText": t.accentText ?: [NSNull null], @"focus": t.focus ?: [NSNull null],
                             @"focusText": t.focusText ?: [NSNull null], @"progress": t.progressColor ?: [NSNull null],
                             @"seekBar": t.seekBarColor ?: [NSNull null], @"wordmarkColor": t.wordmarkColor ?: [NSNull null],
                             @"headerMarkColor": t.headerMarkColor ?: [NSNull null]};
    [colors enumerateKeysAndObjectsUsingBlock:^(NSString *k, id c, BOOL *stop) { NSString *s = c == [NSNull null] ? nil : CSSColor(c); if (s) d[k] = s; }];
    d[@"fonts"] = @{@"regular": t.fontRegular ?: @"", @"medium": t.fontMedium ?: @"", @"bold": t.fontBold ?: @"", @"wordmark": t.fontWordmark ?: t.fontBold ?: @""};
    d[@"corner"] = @(t.corner);
    d[@"light"] = @(t.light);
    d[@"uppercaseHeaders"] = @(t.uppercaseHeaders);
    if (t.wordmark) d[@"wordmark"] = t.wordmark;
    if (t.logo) { d[@"logo"] = t.logo; d[@"logoVariant"] = @(t.logoVariant); }
    d[@"headerMark"] = @[@"none", @"playPill", @"bar", @"dot"][MIN((NSUInteger)t.headerMark, 3u)];
    return d;
}

// A page loader's first answer (some answer again with fresher data - the TV takes each; the browser
// asks again when it wants), bounded in time
static void RunLoader(SFPageLoader loader, SFHTTPExchange *x) {
    if (!loader) { SFWebReply(x, 410, SFWebError(SFWebErrPageGone, @"Diese Seite ist nicht mehr da – bitte neu laden.")); return; }
    __block BOOL answered = NO;
    loader(^(SFPage *page, NSError *e) {
        SFMain(^{
            if (answered) return;
            answered = YES;
            if (!page) SFWebReply(x, 502, SFWebError(SFWebErrUpstream, e.localizedDescription ?: @"Der Inhalt konnte gerade nicht geladen werden."));
            else SFWebReply(x, 200, [SFWebItems page:page]);
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPageTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (answered) return;
        answered = YES;
        SFWebReply(x, 504, SFWebError(SFWebErrTimeout, @"Der Inhalt antwortet gerade nicht."));
    });
}

@implementation SFWebServer (API)

- (void)api:(SFHTTPExchange *)x parts:(NSArray *)parts device:(NSString *)device {
    SFHTTPRequest *r = x.request;
    NSString *what = parts.firstObject ?: @"", *m = r.method;
    BOOL get = [m isEqualToString:@"GET"], post = [m isEqualToString:@"POST"];
    NSDictionary *body = post ? dict([NSJSONSerialization JSONObjectWithData:r.body options:0 error:nil]) : nil;
    if ([what isEqualToString:@"hello"] && get) {
        SFWebReply(x, 200, @{@"name": @"Sofa", @"version": [SFUpdater shared].installedVersion ?: @"", @"paired": device ? @YES : @NO,
                             @"api": @{@"version": @(SFWebAPIVersion), @"min": @(SFWebAPIMinVersion)}, @"features": Features()});
        return;
    }
    if ([what isEqualToString:@"pair"] && post) {
        if (!body) { SFWebReply(x, 400, SFWebError(SFWebErrBadRequest, @"Unvollständige Anfrage.")); return; }
        NSInteger st = 0;
        SFWebClient *client = [SFWebClient clientFrom:body[@"client"]];
        if (!client) { SFWebReply(x, 400, SFWebError(SFWebErrBadRequest, @"Unbekannte App.")); return; }
        NSDictionary *ok = [[SFWebDevices shared] pairWithCode:str(body[@"code"]) name:str(body[@"name"]) client:client status:&st];
        NSDictionary *err = st == 429 ? SFWebError(SFWebErrRateLimited, @"Zu viele falsche Versuche – bitte eine Minute warten.")
                          : st == 410 ? SFWebError(SFWebErrNoPairingOpen, @"Am Fernseher ist gerade kein Code offen: Einstellungen → Sofa im Browser.")
                          : st == 500 ? SFWebError(SFWebErrInternal, @"Das hat nicht geklappt – bitte noch einmal versuchen.")
                          : SFWebError(SFWebErrWrongCode, @"Der Code stimmt nicht. Der aktuelle steht am Fernseher.");
        SFWebReply(x, st, ok ?: err);
        return;
    }
    if (!device) { SFWebReply(x, 401, SFWebError(SFWebErrNotPaired, @"Dieses Gerät ist nicht (mehr) mit Sofa verbunden.")); return; }
    if ([what isEqualToString:@"pair"] && [m isEqualToString:@"DELETE"]) { [[SFWebDevices shared] remove:device]; SFWebReply(x, 200, @{@"ok": @YES}); return; }
    if ([what isEqualToString:@"info"] && get) { [self info:x device:device]; return; }
    if ([what isEqualToString:@"home"] && get) { RunLoader([SFHome homeLoader], x); return; }
    if ([what isEqualToString:@"app"] && get && parts.count == 2) {
        SFPageLoader loader = [SFHome appLoader:parts[1]];
        if (loader) RunLoader(loader, x); else SFWebReply(x, 404, SFWebError(SFWebErrNotFound, @"Diese App gibt es hier nicht."));
        return;
    }
    if ([what isEqualToString:@"page"] && get && parts.count == 2) { RunLoader([SFWebItems pageLoaderForHandle:parts[1]], x); return; }
    if ([what isEqualToString:@"more"] && get && parts.count == 2) { [self more:parts[1] to:x]; return; }
    if ([what isEqualToString:@"show"] && get) {
        NSString *ref = r.query[@"ref"];
        if (ref && [SFAppRegistry isShowRef:ref]) RunLoader(SFShowPageLoader(ref, r.query[@"title"]), x);
        else SFWebReply(x, 404, SFWebError(SFWebErrNotFound, @"Diese Sendung gibt es hier nicht."));
        return;
    }
    if ([what isEqualToString:@"search"] && get) { [self search:x]; return; }
    if ([what isEqualToString:@"suggest"] && get) { [self suggest:x]; return; }
    if ([what isEqualToString:@"play"] && post) {
        SFItem *item = [SFWebItems itemFromBrowser:dict(body[@"item"])];
        if (!item) { SFWebReply(x, 400, SFWebError(SFWebErrUnknownItem, @"Unbekanntes Video.")); return; }
        // the codecs the client decodes, in its order of preference (it says so; an older PWA: H.264 + AAC,
        // what every browser plays)
        NSMutableOrderedSet *formats = [NSMutableOrderedSet new];
        for (id f in [body[@"formats"] isKindOfClass:[NSArray class]] ? body[@"formats"] : @[@"avc1", @"mp4a"])
            if ([f isKindOfClass:[NSString class]]) [formats addObject:[f lowercaseString]];
        [[SFWebStreams shared] play:item device:device formats:formats.array done:^(NSDictionary *answer, NSInteger status, NSString *code, NSString *message) {
            SFWebReply(x, status, answer ?: SFWebError(code, message ?: @"Das Video ließ sich nicht abspielen."));
        }];
        return;
    }
    if ([what isEqualToString:@"stream"] && post && parts.count == 2) {
        NSInteger st = [[SFWebStreams shared] report:parts[1] device:device state:body ?: @{}];
        SFWebReply(x, st, st == 200 ? @{@"ok": @YES} : SFWebStreamReportError(st));
        return;
    }
    if ([what isEqualToString:@"state"] && post) { [self state:body to:x]; return; }
    if ([what isEqualToString:@"status"] && get) { [[SFWebStatus shared] answer:x since:r.query[@"since"] ?: @""]; return; }
    if ([what isEqualToString:@"tv"] && post && parts.count == 2) { [self tv:parts[1] body:body device:device to:x]; return; }
    SFWebReply(x, 404, SFWebError(SFWebErrNotFound, @"Nicht gefunden."));
}

- (void)info:(SFHTTPExchange *)x device:(NSString *)device {
    NSMutableArray *apps = [NSMutableArray new];
    NSMutableDictionary *themes = [@{@"home": ThemeJSON([SFTheme themeNamed:@"home"])} mutableCopy];
    for (Class<SFApp> a in [SFAppRegistry apps]) {
        NSString *ident = [a appIdentifier];
        themes[ident] = ThemeJSON([SFTheme themeNamed:ident]);
        NSMutableDictionary *d = [@{@"id": ident, @"name": [a appName], @"summary": [a appSummary] ?: @"",
                                    @"search": @(SFHasSearch(ident))} mutableCopy];
        if ([a respondsToSelector:@selector(searchPlaceholder)]) d[@"searchPlaceholder"] = [a searchPlaceholder];
        [apps addObject:d];
    }
    NSString *name = @"";
    for (SFWebDevice *d in [[SFWebDevices shared] devices]) if ([d.identifier isEqualToString:device]) name = d.name ?: @"";
    SFWebReply(x, 200, @{@"apps": apps, @"themes": themes, @"device": name, @"host": self.shortName ?: @""});
}

- (void)more:(NSString *)handle to:(SFHTTPExchange *)x {
    void (^more)(void (^)(NSArray *, BOOL)) = [SFWebItems moreLoaderForHandle:handle];
    if (!more) { SFWebReply(x, 410, SFWebError(SFWebErrPageGone, @"Diese Liste ist nicht mehr da – bitte neu laden.")); return; }
    __block BOOL answered = NO;
    more(^(NSArray *items, BOOL further) {
        SFMain(^{
            if (answered) return;
            answered = YES;
            SFWebReply(x, 200, @{@"items": [SFWebItems items:items ?: @[]], @"more": @(further)});
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPageTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!answered) { answered = YES; SFWebReply(x, 504, SFWebError(SFWebErrTimeout, @"Die Liste antwortet gerade nicht.")); }
    });
}

- (void)search:(SFHTTPExchange *)x {
    NSString *source = x.request.query[@"app"], *q = [x.request.query[@"q"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    Class<SFApp> app = source ? [SFAppRegistry appNamed:source] : nil;
    if (!app || ![app respondsToSelector:@selector(searchLoader:)]) { SFWebReply(x, 404, SFWebError(SFWebErrNoSearch, @"Hier gibt es keine Suche.")); return; }
    if (!q.length) { SFWebReply(x, 200, @{@"recent": SFRecentSearches(source) ?: @[]}); return; }
    SFAddRecentSearch(source, q);   // shared with the TV's keyboard (one household)
    RunLoader([app searchLoader:q], x);
}

- (void)suggest:(SFHTTPExchange *)x {
    NSString *source = x.request.query[@"app"], *q = x.request.query[@"q"];
    Class<SFApp> app = source ? [SFAppRegistry appNamed:source] : nil;
    if (!q.length || ![app respondsToSelector:@selector(suggestions:done:)]) { SFWebReply(x, 200, @{@"list": @[]}); return; }
    [app suggestions:q done:^(NSArray *list) { SFWebReply(x, 200, @{@"list": list ?: @[]}); }];
}

// The TV: play {item, fromStart?, at?, replace?} -> {tv}; control {action: play|pause|stop} -> {tv}
- (void)tv:(NSString *)what body:(NSDictionary *)body device:(NSString *)device to:(SFHTTPExchange *)x {
    SFWebTV *tv = [SFWebTV shared];
    if ([what isEqualToString:@"play"]) {
        SFItem *item = [SFWebItems itemFromBrowser:dict(body[@"item"])];
        if (!item) { SFWebReply(x, 400, SFWebError(SFWebErrUnknownItem, @"Unbekanntes Video.")); return; }
        [tv play:item fromStart:[body[@"fromStart"] boolValue] at:MAX(0, [num(body[@"at"]) doubleValue]) replace:[body[@"replace"] boolValue]
          device:device done:^(NSInteger status, NSDictionary *answer) { SFWebReply(x, status, answer); }];
        return;
    }
    if ([what isEqualToString:@"control"]) {
        NSInteger st = [tv control:str(body[@"action"]) ?: @""];
        SFWebReply(x, st, st == 200 ? @{@"tv": [tv state] ?: [NSNull null]}
                       : st == 404 ? SFWebError(SFWebErrTVIdle, @"Am Fernseher läuft gerade nichts.") : SFWebError(SFWebErrBadAction, @"Unbekannte Aktion."));
        return;
    }
    SFWebReply(x, 404, SFWebError(SFWebErrNotFound, @"Nicht gefunden."));
}

// Marks on an item: {item, later?, watched?, follow?, forget?, download?, keep?} -> the item as it is
// now; a download started also says what the TV would tell ({message}: SFDownloads download:told:).
// download false cancels a waiting or running one, or deletes it (as "Download löschen" on the TV:
// asking first, for a kept one or one no longer online, is the browser's - as it is the TV's menu's).
- (void)state:(NSDictionary *)body to:(SFHTTPExchange *)x {
    SFItem *item = [SFWebItems itemFromBrowser:dict(body[@"item"])];
    if (!item) { SFWebReply(x, 400, SFWebError(SFWebErrUnknownItem, @"Unbekannter Eintrag.")); return; }
    BOOL startDownload = num(body[@"download"]) && [body[@"download"] boolValue];
    if (startDownload && (item.kind != SFItemVideo || item.drm || !item.resolverRef)) {
        SFWebReply(x, 400, SFWebError(SFWebErrNotDownloadable, @"Dieses Video lässt sich nicht herunterladen."));
        return;
    }
    BOOL changed = NO;
    if (num(body[@"later"]) && (item.kind == SFItemVideo || item.kind == SFItemLive)) {
        if ([body[@"later"] boolValue]) [[SFWatchLater shared] add:item]; else [[SFWatchLater shared] remove:item.identifier];
    }
    if (num(body[@"watched"]) && item.kind == SFItemVideo) {
        [[SFStore shared] setWatched:[body[@"watched"] boolValue] forItem:item];
        changed = YES;
    }
    if ([body[@"forget"] boolValue]) { [[SFStore shared] removeFromContinue:item.identifier]; changed = YES; }
    if (num(body[@"follow"]) && item.kind == SFItemFolder && [[SFFollows shared] canFollow:item]) {
        if ([body[@"follow"] boolValue]) [[SFFollows shared] follow:item]; else [[SFFollows shared] unfollow:item.identifier];
    }
    SFDownloads *dl = [SFDownloads shared];
    if (num(body[@"keep"]) && item.kind == SFItemVideo && [dl stateFor:item.identifier progress:NULL] == SFDLDone)
        [dl setKept:[body[@"keep"] boolValue] forIdentifier:item.identifier];
    if (num(body[@"download"]) && !startDownload && item.kind == SFItemVideo) [dl remove:item.identifier];
    if (changed) [[NSNotificationCenter defaultCenter] postNotificationName:SFLibraryDidChangeNotification object:nil];   // the TV's pages
    if (startDownload) {
        [dl download:item told:^(NSString *message) { SFWebReply(x, 200, @{@"item": [SFWebItems item:item] ?: @{}, @"message": message ?: @""}); }];
        return;
    }
    SFWebReply(x, 200, @{@"item": [SFWebItems item:item] ?: @{}});
}
@end
