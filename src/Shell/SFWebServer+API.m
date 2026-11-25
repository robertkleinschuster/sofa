// SFWebServer - the JSON routes of Sofa im Browser (docs/pwa.md, "API"). Main thread: the same
// modules the TV's screens use (SFHome's pages, the apps, SFStore, SFWatchLater, SFFollows).
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
#import "SFJSON.h"

static const NSTimeInterval kPageTimeout = 45;

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
    if (!loader) { SFWebReply(x, 410, @{@"error": @"Diese Seite ist nicht mehr da – bitte neu laden."}); return; }
    __block BOOL answered = NO;
    loader(^(SFPage *page, NSError *e) {
        SFMain(^{
            if (answered) return;
            answered = YES;
            if (!page) SFWebReply(x, 502, @{@"error": e.localizedDescription ?: @"Der Inhalt konnte gerade nicht geladen werden."});
            else SFWebReply(x, 200, [SFWebItems page:page]);
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPageTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (answered) return;
        answered = YES;
        SFWebReply(x, 504, @{@"error": @"Der Inhalt antwortet gerade nicht."});
    });
}

@implementation SFWebServer (API)

- (void)api:(SFHTTPExchange *)x parts:(NSArray *)parts device:(NSString *)device {
    SFHTTPRequest *r = x.request;
    NSString *what = parts.firstObject ?: @"", *m = r.method;
    BOOL get = [m isEqualToString:@"GET"], post = [m isEqualToString:@"POST"];
    NSDictionary *body = post ? dict([NSJSONSerialization JSONObjectWithData:r.body options:0 error:nil]) : nil;
    if ([what isEqualToString:@"hello"] && get) {
        SFWebReply(x, 200, @{@"name": @"Sofa", @"version": [SFUpdater shared].installedVersion ?: @"", @"paired": device ? @YES : @NO});
        return;
    }
    if ([what isEqualToString:@"pair"] && post) {
        NSInteger st = 0;
        NSDictionary *ok = [[SFWebDevices shared] pairWithCode:str(body[@"code"]) name:str(body[@"name"]) status:&st];
        NSString *msg = st == 429 ? @"Zu viele falsche Versuche – bitte eine Minute warten."
                      : st == 410 ? @"Am Fernseher ist gerade kein Code offen: Einstellungen → Sofa im Browser."
                      : @"Der Code stimmt nicht. Der aktuelle steht am Fernseher.";
        SFWebReply(x, st, ok ?: @{@"error": msg});
        return;
    }
    if (!device) { SFWebReply(x, 401, @{@"error": @"Dieses Gerät ist nicht (mehr) mit Sofa verbunden."}); return; }
    if ([what isEqualToString:@"pair"] && [m isEqualToString:@"DELETE"]) { [[SFWebDevices shared] remove:device]; SFWebReply(x, 200, @{@"ok": @YES}); return; }
    if ([what isEqualToString:@"info"] && get) { [self info:x device:device]; return; }
    if ([what isEqualToString:@"home"] && get) { RunLoader([SFHome homeLoader], x); return; }
    if ([what isEqualToString:@"app"] && get && parts.count == 2) { RunLoader([SFHome appLoader:parts[1]], x); return; }
    if ([what isEqualToString:@"page"] && get && parts.count == 2) { RunLoader([SFWebItems pageLoaderForHandle:parts[1]], x); return; }
    if ([what isEqualToString:@"more"] && get && parts.count == 2) { [self more:parts[1] to:x]; return; }
    if ([what isEqualToString:@"show"] && get) {
        NSString *ref = r.query[@"ref"];
        RunLoader(ref && [SFAppRegistry isShowRef:ref] ? SFShowPageLoader(ref, r.query[@"title"]) : nil, x);
        return;
    }
    if ([what isEqualToString:@"search"] && get) { [self search:x]; return; }
    if ([what isEqualToString:@"suggest"] && get) { [self suggest:x]; return; }
    if ([what isEqualToString:@"play"] && post) {
        SFItem *item = [SFWebItems itemFromBrowser:dict(body[@"item"])];
        if (!item) { SFWebReply(x, 400, @{@"error": @"Unbekanntes Video."}); return; }
        [[SFWebStreams shared] play:item device:device done:^(NSDictionary *answer, NSInteger status, NSString *message) {
            SFWebReply(x, status, answer ?: @{@"error": message ?: @"Das Video ließ sich nicht abspielen."});
        }];
        return;
    }
    if ([what isEqualToString:@"stream"] && post && parts.count == 2) {
        NSInteger st = [[SFWebStreams shared] report:parts[1] device:device state:body ?: @{}];
        SFWebReply(x, st, @{@"ok": st == 200 ? @YES : @NO});
        return;
    }
    if ([what isEqualToString:@"state"] && post) { [self state:body to:x]; return; }
    SFWebReply(x, 404, @{@"error": @"not found"});
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
    for (SFWebDevice *d in [[SFWebDevices shared] devices]) if ([d.identifier isEqualToString:device]) name = d.name;
    SFWebReply(x, 200, @{@"apps": apps, @"themes": themes, @"device": name, @"host": self.shortName ?: @""});
}

- (void)more:(NSString *)handle to:(SFHTTPExchange *)x {
    void (^more)(void (^)(NSArray *, BOOL)) = [SFWebItems moreLoaderForHandle:handle];
    if (!more) { SFWebReply(x, 410, @{@"error": @"Diese Liste ist nicht mehr da – bitte neu laden."}); return; }
    __block BOOL answered = NO;
    more(^(NSArray *items, BOOL further) {
        SFMain(^{
            if (answered) return;
            answered = YES;
            SFWebReply(x, 200, @{@"items": [SFWebItems items:items ?: @[]], @"more": @(further)});
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPageTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!answered) { answered = YES; SFWebReply(x, 504, @{@"error": @"Die Liste antwortet gerade nicht."}); }
    });
}

- (void)search:(SFHTTPExchange *)x {
    NSString *source = x.request.query[@"app"], *q = [x.request.query[@"q"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    Class<SFApp> app = source ? [SFAppRegistry appNamed:source] : nil;
    if (!app || ![app respondsToSelector:@selector(searchLoader:)]) { SFWebReply(x, 404, @{@"error": @"Hier gibt es keine Suche."}); return; }
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

// Marks on an item: {item, later?, watched?, follow?, forget?} -> the item as it is now
- (void)state:(NSDictionary *)body to:(SFHTTPExchange *)x {
    SFItem *item = [SFWebItems itemFromBrowser:dict(body[@"item"])];
    if (!item) { SFWebReply(x, 400, @{@"error": @"Unbekannter Eintrag."}); return; }
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
    if (changed) [[NSNotificationCenter defaultCenter] postNotificationName:SFLibraryDidChangeNotification object:nil];   // the TV's pages
    SFWebReply(x, 200, @{@"item": [SFWebItems item:item] ?: @{}});
}
@end
