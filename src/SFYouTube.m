#import "SFYouTube.h"
#import "SFMenuScreen.h"
#import "SFYTResolver.h"
#import "SFNet.h"
#import "SFStore.h"
#import "SFLibrary.h"
#import "SFHome.h"
#import "SFIconArt.h"
#import "SFPairScreen.h"
#import "SFDownloads.h"
#import "SFFollows.h"
#import "SFEngine.h"
#import "SFScreen.h"
#import <CommonCrypto/CommonDigest.h>
#import <sqlite3.h>
#import <sys/stat.h>

static NSString *const kClientVersion = @"2.20261030.02.00";
static NSString *const kOrigin = @"https://www.youtube.com";

static id nn(id v) { return (v == [NSNull null]) ? nil : v; }
static NSString *str(id v) { v = nn(v); return [v isKindOfClass:[NSString class]] ? v : nil; }
static NSDictionary *dict(id v) { v = nn(v); return [v isKindOfClass:[NSDictionary class]] ? v : nil; }
static NSArray *arr(id v) { v = nn(v); return [v isKindOfClass:[NSArray class]] ? v : nil; }
static id path(id root, NSString *p) {
    id cur = root;
    for (NSString *k in [p componentsSeparatedByString:@"."]) {
        if (!k.length) continue;
        unichar c = [k characterAtIndex:0];
        if (c >= '0' && c <= '9') { NSArray *a = arr(cur); NSInteger i = k.integerValue; cur = (a && i < (NSInteger)a.count) ? a[i] : nil; }
        else cur = dict(cur)[k];
        if (!cur) return nil;
    }
    return nn(cur);
}
// Textknoten: "…" | {simpleText} | {runs:[{text}]} | {content}
static NSString *text(id n) {
    if (str(n)) return n;
    NSDictionary *d = dict(n);
    if (!d) return nil;
    if (str(d[@"simpleText"])) return d[@"simpleText"];
    if (str(d[@"content"])) return d[@"content"];
    NSArray *runs = arr(d[@"runs"]);
    if (runs) { NSMutableString *s = [NSMutableString new]; for (id r in runs) [s appendString:str(dict(r)[@"text"]) ?: @""]; return s.length ? s : nil; }
    return nil;
}
static NSString *lastURL(id sources) {
    NSString *u = str(dict(arr(sources).lastObject)[@"url"]);
    if ([u hasPrefix:@"//"]) u = [@"https:" stringByAppendingString:u];
    return u;
}
static NSTimeInterval parseDuration(NSString *s) {
    if (!s.length) return 0;
    NSTimeInterval t = 0;
    for (NSString *p in [s componentsSeparatedByString:@":"]) {
        NSString *q = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!q.length || [q rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) return 0;
        t = t * 60 + q.integerValue;
    }
    return t;
}

// "vor 3 Tagen", "vor 1 Stunde", "vor 2 Wochen", "vor 5 Monaten", "vor 1 Jahr" (auch
// "… gestreamt", "Premiere vor …") -> ungefähres Datum (für Sortierung/Behaltefrist)
static NSDate *relativeDate(NSString *s) {
    if (!s.length) return nil;
    NSRange v = [s rangeOfString:@"vor "];
    if (v.location == NSNotFound) return nil;
    NSScanner *sc = [NSScanner scannerWithString:[s substringFromIndex:NSMaxRange(v)]];
    NSInteger n = 0;
    if (![sc scanInteger:&n]) return nil;
    NSString *rest = [[s substringFromIndex:NSMaxRange(v)] lowercaseString];
    double unit = 0;
    if ([rest rangeOfString:@"sekunde"].location != NSNotFound) unit = 1;
    else if ([rest rangeOfString:@"minute"].location != NSNotFound) unit = 60;
    else if ([rest rangeOfString:@"stunde"].location != NSNotFound) unit = 3600;
    else if ([rest rangeOfString:@"tag"].location != NSNotFound) unit = 86400;
    else if ([rest rangeOfString:@"woche"].location != NSNotFound) unit = 7 * 86400;
    else if ([rest rangeOfString:@"monat"].location != NSNotFound) unit = 30.4 * 86400;
    else if ([rest rangeOfString:@"jahr"].location != NSNotFound) unit = 365 * 86400;
    return unit ? [NSDate dateWithTimeIntervalSinceNow:-n * unit] : nil;
}

#pragma mark - Auth (Firefox-Cookies)

static NSString *gCookieHeader, *gSAPISID;
static BOOL gLoggedIn;
static NSDate *gCookiesAt;

@implementation SFYouTube

+ (BOOL)loggedIn { return gLoggedIn; }

+ (NSArray *)firefoxProfiles {
    NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Firefox"];
    NSString *ini = [NSString stringWithContentsOfFile:[base stringByAppendingPathComponent:@"profiles.ini"] encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *out = [NSMutableArray new];
    NSString *p = nil; BOOL rel = YES;
    for (NSString *raw in [[ini ?: @"" stringByAppendingString:@"\n["] componentsSeparatedByString:@"\n"]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([l hasPrefix:@"["]) { if (p) [out addObject:rel ? [base stringByAppendingPathComponent:p] : p]; p = nil; rel = YES; }
        else if ([l hasPrefix:@"Path="]) p = [l substringFromIndex:5];
        else if ([l hasPrefix:@"IsRelative="]) rel = [[l substringFromIndex:11] isEqualToString:@"1"];
    }
    return out;
}

// Liest die YouTube/Google-Cookies aus einer KOPIE von cookies.sqlite (+wal); Firefox hält
// die DB gesperrt und wird nie angefasst.
+ (NSArray *)cookiesFromProfile:(NSString *)prof {
    NSString *db = [prof stringByAppendingPathComponent:@"cookies.sqlite"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:db]) return nil;
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sofa-ck-%@", [[NSUUID UUID] UUIDString]]];
    [fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    NSString *copy = [tmp stringByAppendingPathComponent:@"cookies.sqlite"];
    [fm copyItemAtPath:db toPath:copy error:nil];
    if ([fm fileExistsAtPath:[db stringByAppendingString:@"-wal"]]) [fm copyItemAtPath:[db stringByAppendingString:@"-wal"] toPath:[copy stringByAppendingString:@"-wal"] error:nil];
    NSMutableArray *rows = [NSMutableArray new];
    sqlite3 *h = NULL;
    if (sqlite3_open_v2(copy.fileSystemRepresentation, &h, SQLITE_OPEN_READWRITE, NULL) == SQLITE_OK) {
        sqlite3_stmt *st = NULL;
        const char *q = "SELECT host,path,isSecure,expiry,name,value FROM moz_cookies WHERE host LIKE '%youtube.com' OR host LIKE '%google.com'";
        if (sqlite3_prepare_v2(h, q, -1, &st, NULL) == SQLITE_OK) {
            while (sqlite3_step(st) == SQLITE_ROW) {
                const char *c[6]; for (int i = 0; i < 6; i++) c[i] = (const char *)sqlite3_column_text(st, i);
                if (!c[0] || !c[4]) continue;
                long long exp = sqlite3_column_int64(st, 3);
                if (exp > 100000000000LL) exp /= 1000;
                [rows addObject:@{@"host": @(c[0]), @"path": @(c[1] ?: "/"), @"secure": @(sqlite3_column_int(st, 2)),
                                  @"expiry": @(exp), @"name": @(c[4]), @"value": @(c[5] ?: "")}];
            }
            sqlite3_finalize(st);
        }
        sqlite3_close(h);
    }
    [fm removeItemAtPath:tmp error:nil];
    return rows;
}

+ (void)loadCookies {
    NSArray *best = nil; NSDate *bestM = nil;
    for (NSString *prof in [self firefoxProfiles]) {
        NSArray *rows = [self cookiesFromProfile:prof];
        BOOL sapi = NO, login = NO;
        for (NSDictionary *r in rows) {
            if (![r[@"host"] isEqualToString:@".youtube.com"]) continue;
            if ([r[@"name"] isEqualToString:@"SAPISID"]) sapi = YES;
            if ([r[@"name"] isEqualToString:@"LOGIN_INFO"]) login = YES;
        }
        if (!(sapi && login)) continue;
        NSDate *m = [[NSFileManager defaultManager] attributesOfItemAtPath:[prof stringByAppendingPathComponent:@"cookies.sqlite"] error:nil].fileModificationDate;
        if (!best || [m compare:bestM] == NSOrderedDescending) { best = rows; bestM = m; }
    }
    NSMutableArray *hdr = [NSMutableArray new];
    NSMutableString *txt = [NSMutableString stringWithString:@"# Netscape HTTP Cookie File\n# von Sofa aus Firefox erzeugt\n"];
    NSString *sapisid = nil;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    for (NSDictionary *r in best) {
        if ([r[@"expiry"] longLongValue] && [r[@"expiry"] longLongValue] < now) continue;
        NSString *host = r[@"host"];
        if ([host isEqualToString:@".youtube.com"]) {
            [hdr addObject:[NSString stringWithFormat:@"%@=%@", r[@"name"], r[@"value"]]];
            if ([r[@"name"] isEqualToString:@"SAPISID"]) sapisid = r[@"value"];
        }
        [txt appendFormat:@"%@\t%@\t%@\t%@\t%lld\t%@\t%@\n", host, [host hasPrefix:@"."] ? @"TRUE" : @"FALSE", r[@"path"],
            [r[@"secure"] intValue] ? @"TRUE" : @"FALSE", [r[@"expiry"] longLongValue], r[@"name"], r[@"value"]];
    }
    NSString *cf = [SFYTResolver cookieFile];
    NSString *old = [NSString stringWithContentsOfFile:cf encoding:NSUTF8StringEncoding error:nil];
    BOOL changed = best && ![old isEqualToString:txt];
    if (changed) {
        [[NSFileManager defaultManager] createFileAtPath:cf contents:[txt dataUsingEncoding:NSUTF8StringEncoding] attributes:@{NSFilePosixPermissions: @0600}];
        chmod(cf.fileSystemRepresentation, 0600);
    }
    SFMain(^{
        gCookieHeader = hdr.count ? [hdr componentsJoinedByString:@"; "] : nil;
        gSAPISID = sapisid;
        gCookiesAt = [NSDate date];
        SFLog(@"yt: %@", sapisid ? [NSString stringWithFormat:@"Firefox-Login gefunden (%lu Cookies)", (unsigned long)hdr.count] : @"kein Firefox-Login");
        if (changed && old) [[SFYTResolver shared] restart];   // yt-dlp liest Cookies nur beim Start
    });
}

+ (NSString *)authHash {
    if (!gSAPISID) return nil;
    long ts = (long)[[NSDate date] timeIntervalSince1970];
    NSString *in = [NSString stringWithFormat:@"%ld %@ %@", ts, gSAPISID, kOrigin];
    NSData *d = [in dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char md[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, md);
    NSMutableString *hex = [NSMutableString new];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", md[i]];
    return [NSString stringWithFormat:@"SAPISIDHASH %ld_%@", ts, hex];
}

#pragma mark - InnerTube

+ (void)call:(NSString *)endpoint body:(NSDictionary *)body auth:(BOOL)auth cache:(NSTimeInterval)age done:(SFJSONDone)done {
    NSMutableDictionary *b = [body mutableCopy];
    b[@"context"] = @{@"client": @{@"clientName": @"WEB", @"clientVersion": kClientVersion, @"hl": @"de", @"gl": @"AT"}};
    NSMutableDictionary *h = [@{@"X-Youtube-Client-Name": @"1", @"X-Youtube-Client-Version": kClientVersion, @"Origin": kOrigin} mutableCopy];
    NSString *ah = auth ? [self authHash] : nil;
    if (ah && gCookieHeader) {
        h[@"Cookie"] = gCookieHeader;
        h[@"Authorization"] = ah;
        h[@"X-Goog-AuthUser"] = @"0";
        h[@"X-Origin"] = kOrigin;
    } else if (auth) {
        done(nil, SFError(@"Nicht bei YouTube angemeldet (Firefox)."));
        return;
    }
    NSString *url = [NSString stringWithFormat:@"https://www.youtube.com/youtubei/v1/%@?prettyPrint=false", endpoint];
    [SFNet postJSON:url body:b headers:h cacheAge:age done:^(id j, NSError *e) {
        if (auth && j) {
            // Fehlgeschlagene Anmeldung ist still (HTTP 200, leer) -> logged_in prüfen
            BOOL li = NO;
            for (NSDictionary *stp in arr(path(j, @"responseContext.serviceTrackingParams")))
                for (NSDictionary *pp in arr(dict(stp)[@"params"]))
                    if ([str(dict(pp)[@"key"]) isEqualToString:@"logged_in"]) li = [str(dict(pp)[@"value"]) isEqualToString:@"1"];
            if (!li) {
                gLoggedIn = NO;
                if (-[gCookiesAt timeIntervalSinceNow] > 300) SFBackground(^{ [self loadCookies]; });
                done(nil, SFError(@"YouTube-Anmeldung abgelaufen – in Firefox neu anmelden."));
                return;
            }
            gLoggedIn = YES;
        }
        done(j, e);
    }];
}

static NSString *restOfID(NSString *ident) { NSRange r = [ident rangeOfString:@":"]; return r.location == NSNotFound ? ident : [ident substringFromIndex:NSMaxRange(r)]; }

#pragma mark - Parser (rekursiver Walker, docs/youtube.md §3.0)

+ (SFItem *)videoItem:(NSString *)vid title:(NSString *)title channel:(NSString *)channel channelID:(NSString *)cid
                  meta:(NSString *)meta thumb:(NSString *)thumb duration:(NSTimeInterval)dur live:(BOOL)live {
    if (vid.length != 11) return nil;
    SFItem *local = [[SFDownloads shared] itemFor:[@"yt:" stringByAppendingString:vid]] ?: [[SFLibrary shared] episodeForYouTubeID:vid];
    if (local) {   // schon heruntergeladen: lokale Datei (Qualität, offline, gemeinsamer Fortschritt)
        SFItem *i = [local copy];
        i.subtitle = meta.length ? [NSString stringWithFormat:@"%@ · auf diesem Mac", meta] : @"Auf diesem Mac";
        return i;
    }
    SFItem *i = [SFItem new];
    i.kind = live ? SFItemLive : SFItemVideo;
    i.identifier = [@"yt:" stringByAppendingString:vid];
    i.resolverRef = [(live ? @"ytlive:" : @"yt:") stringByAppendingString:vid];
    i.externalID = vid;
    i.title = title;
    i.channel = channel;
    i.subtitle = meta;
    i.image = thumb ?: [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", vid];
    i.backdrop = i.image;
    i.duration = dur;
    i.source = @"youtube"; i.themeName = @"youtube";
    i.style = SFTileStyleLandscape;
    if (live) i.badge = @"LIVE";
    return i;
}

// Online-Item ohne Ersetzung durch lokale Kopie (für Downloads/Abos)
+ (SFItem *)videoItemOnline:(NSString *)vid {
    if (vid.length != 11) return nil;
    SFItem *i = [SFItem new];
    i.kind = SFItemVideo;
    i.identifier = [@"yt:" stringByAppendingString:vid];
    i.resolverRef = i.identifier;
    i.externalID = vid;
    i.image = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", vid];
    i.source = @"youtube"; i.themeName = @"youtube"; i.style = SFTileStyleLandscape;
    return i;
}

+ (SFItem *)channelItem:(NSString *)cid title:(NSString *)title avatar:(NSString *)avatar meta:(NSString *)meta {
    if (!cid.length || !title.length) return nil;
    SFItem *f = [SFItem new];
    f.kind = SFItemFolder;
    f.identifier = [@"ytchannel:" stringByAppendingString:cid];
    f.title = title; f.subtitle = meta;
    // Avatar-Größe frei wählbar (=s88-… -> =s400-…)
    NSRange r = [avatar rangeOfString:@"=s" options:NSBackwardsSearch];
    if (r.location != NSNotFound) {
        NSRange dash = [avatar rangeOfString:@"-" options:0 range:NSMakeRange(NSMaxRange(r), avatar.length - NSMaxRange(r))];
        if (dash.location != NSNotFound) avatar = [avatar stringByReplacingCharactersInRange:NSMakeRange(NSMaxRange(r), dash.location - NSMaxRange(r)) withString:@"400"];
    }
    f.image = avatar;
    f.style = SFTileStyleCircle;
    f.source = @"youtube"; f.themeName = @"youtube";
    f.pageLoader = [self channelLoader:cid title:title];
    return f;
}

+ (SFItem *)fromLockup:(NSDictionary *)l {
    NSString *type = str(l[@"contentType"]), *cid = str(l[@"contentId"]);
    NSDictionary *md = dict(path(l, @"metadata.lockupMetadataViewModel"));
    NSString *title = text(md[@"title"]);
    NSArray *rows = arr(path(md, @"metadata.contentMetadataViewModel.metadataRows"));
    NSMutableArray *rowTexts = [NSMutableArray new];
    for (NSDictionary *row in rows) {
        NSMutableArray *parts = [NSMutableArray new];
        for (NSDictionary *p in arr(dict(row)[@"metadataParts"])) { NSString *t = text(dict(p)[@"text"]); if (t.length) [parts addObject:t]; }
        if (parts.count) [rowTexts addObject:parts];
    }
    if ([type isEqualToString:@"LOCKUP_CONTENT_TYPE_VIDEO"]) {
        NSString *channel = rowTexts.count >= 2 ? [rowTexts[0] firstObject] : nil;
        NSString *meta = [rowTexts.lastObject componentsJoinedByString:@" · "];
        NSString *chID = str(path(md, @"image.decoratedAvatarViewModel.rendererContext.commandContext.onTap.innertubeCommand.browseEndpoint.browseId"));
        NSDictionary *tv = dict(path(l, @"contentImage.thumbnailViewModel"));
        NSString *thumb = lastURL(path(tv, @"image.sources"));
        NSTimeInterval dur = 0; BOOL live = NO, upcoming = NO;
        for (NSDictionary *ov in arr(tv[@"overlays"])) {
            for (NSDictionary *b in arr(path(ov, @"thumbnailBottomOverlayViewModel.badges"))) {
                NSDictionary *bv = dict(dict(b)[@"thumbnailBadgeViewModel"]);
                NSString *t = str(bv[@"text"]), *style = str(bv[@"badgeStyle"]);
                if ([style hasSuffix:@"LIVE"] || [t isEqualToString:@"LIVE"]) live = YES;
                else if ([t isEqualToString:@"Anstehend"] || [t.uppercaseString isEqualToString:@"UPCOMING"]) upcoming = YES;
                else if (parseDuration(t) > 0) dur = parseDuration(t);
            }
        }
        if (upcoming) return nil;   // noch nicht abspielbar
        if (channel && meta) meta = [NSString stringWithFormat:@"%@ · %@", channel, meta];
        SFItem *vi = [self videoItem:cid title:title channel:channel channelID:chID meta:meta ?: channel thumb:thumb duration:dur live:live];
        NSDate *when = nil;
        for (NSString *part in rowTexts.lastObject) if ((when = relativeDate(part))) break;
        if (!vi.localPath) vi.date = when;
        return vi;
    }
    if ([type isEqualToString:@"LOCKUP_CONTENT_TYPE_PLAYLIST"]) {
        NSDictionary *pt = dict(path(l, @"contentImage.collectionThumbnailViewModel.primaryThumbnail.thumbnailViewModel"));
        NSString *count = nil;
        for (NSDictionary *ov in arr(pt[@"overlays"]))
            for (NSDictionary *b in arr(path(ov, @"thumbnailOverlayBadgeViewModel.thumbnailBadges")))
                count = text(path(b, @"thumbnailBadgeViewModel.text")) ?: count;
        SFItem *f = [SFItem new];
        f.kind = SFItemFolder;
        f.identifier = [@"ytplaylist:" stringByAppendingString:cid ?: @""];
        f.title = title;
        f.subtitle = count;
        f.image = lastURL(path(pt, @"image.sources"));
        f.backdrop = f.image;
        f.style = SFTileStyleLandscape;
        f.source = @"youtube"; f.themeName = @"youtube";
        f.pageLoader = [self playlistLoader:cid title:title];
        return cid ? f : nil;
    }
    return nil;   // Shorts, Kanäle-Lockups usw.
}

+ (SFItem *)fromVideoRenderer:(NSDictionary *)v legacyPlaylist:(BOOL)pl {
    NSString *vid = str(v[@"videoId"]);
    NSString *title = text(v[@"title"]);
    NSDictionary *own = dict(arr(path(v, pl ? @"shortBylineText.runs" : @"ownerText.runs")).firstObject);
    NSString *channel = str(own[@"text"]);
    NSString *chID = str(path(own, @"navigationEndpoint.browseEndpoint.browseId"));
    BOOL live = NO;
    for (NSDictionary *b in arr(v[@"badges"])) if ([str(path(b, @"metadataBadgeRenderer.label")) isEqualToString:@"LIVE"]) live = YES;
    for (NSDictionary *o in arr(v[@"thumbnailOverlays"])) if ([str(path(o, @"thumbnailOverlayTimeStatusRenderer.style")) isEqualToString:@"LIVE"]) live = YES;
    NSTimeInterval dur = [str(v[@"lengthSeconds"]) doubleValue] ?: parseDuration(text(v[@"lengthText"]));
    NSMutableArray *meta = [NSMutableArray new];
    if (channel) [meta addObject:channel];
    NSString *views = text(v[@"viewCountText"]), *when = text(v[@"publishedTimeText"]);
    if (live && views) [meta addObject:views];
    if (when) [meta addObject:when];
    if ([v[@"isPlayable"] isKindOfClass:[NSNumber class]] && ![v[@"isPlayable"] boolValue]) return nil;
    SFItem *vi = [self videoItem:vid title:title channel:channel channelID:chID meta:[meta componentsJoinedByString:@" · "]
                     thumb:lastURL(path(v, @"thumbnail.thumbnails")) duration:dur live:live];
    if (!vi.localPath) vi.date = relativeDate(when);
    return vi;
}

static NSSet *skipKeys(void) {
    static NSSet *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [NSSet setWithArray:@[@"chipBarViewModel", @"feedFilterChipBarRenderer", @"engagementPanels", @"header",
        @"reelShelfRenderer", @"shortsLockupViewModel", @"topbar", @"frameworkUpdates", @"responseContext", @"sidebar",
        @"richSectionRenderer", @"autoplay", @"playerOverlays", @"onResponseReceivedEndpoints"]]; });
    return s;
}

+ (void)walk:(id)node items:(NSMutableArray *)items channels:(NSMutableArray *)channels cont:(NSString **)cont {
    if (arr(node)) { for (id x in node) [self walk:x items:items channels:channels cont:cont]; return; }
    NSDictionary *d = dict(node);
    if (!d) return;
    for (NSString *k in d) {
        id v = d[k];
        if ([skipKeys() containsObject:k]) continue;
        SFItem *it = nil;
        if ([k isEqualToString:@"lockupViewModel"]) it = [self fromLockup:dict(v)];
        else if ([k isEqualToString:@"videoRenderer"] || [k isEqualToString:@"gridVideoRenderer"] || [k isEqualToString:@"compactVideoRenderer"]) it = [self fromVideoRenderer:dict(v) legacyPlaylist:NO];
        else if ([k isEqualToString:@"playlistVideoRenderer"]) it = [self fromVideoRenderer:dict(v) legacyPlaylist:YES];
        else if ([k isEqualToString:@"channelRenderer"] || [k isEqualToString:@"gridChannelRenderer"]) {
            NSDictionary *c = dict(v);
            NSString *sub = text(c[@"subscriberCountText"]);
            if ([sub hasPrefix:@"@"]) sub = text(c[@"videoCountText"]);
            SFItem *ch = [self channelItem:str(c[@"channelId"]) title:text(c[@"title"]) avatar:lastURL(path(c, @"thumbnail.thumbnails")) meta:sub];
            if (ch) [channels addObject:ch];
            continue;
        }
        else if ([k isEqualToString:@"continuationItemRenderer"]) {
            NSString *t = str(path(v, @"continuationEndpoint.continuationCommand.token"));
            if (t && cont) *cont = t;
            continue;
        }
        else if ([k isEqualToString:@"continuationItemViewModel"]) {
            NSString *t = str(path(v, @"continuationCommand.innertubeCommand.continuationCommand.token"));
            if (t && cont) *cont = t;
            continue;
        }
        else { [self walk:v items:items channels:channels cont:cont]; continue; }
        if (it) [items addObject:it];
    }
}

+ (NSArray *)videosIn:(id)json cont:(NSString **)cont channels:(NSMutableArray *)channels {
    NSMutableArray *items = [NSMutableArray new];
    [self walk:json items:items channels:channels ?: [NSMutableArray new] cont:cont];
    NSMutableSet *seen = [NSMutableSet new];
    NSMutableArray *out = [NSMutableArray new];
    for (SFItem *i in items) if (![seen containsObject:i.identifier]) { [seen addObject:i.identifier]; [out addObject:i]; }
    return out;
}

#pragma mark - Seiten

+ (SFItem *)folder:(NSString *)title ident:(NSString *)ident loader:(SFPageLoader)l {
    SFItem *f = [SFItem new];
    f.kind = SFItemFolder; f.title = title; f.identifier = ident;
    f.themeName = @"youtube"; f.source = @"youtube"; f.style = SFTileStyleWide;
    f.pageLoader = l;
    return f;
}

// Liste mit Nachladen der Fortsetzungsseiten (bis max Einträge)
+ (void)collect:(NSString *)endpoint body:(NSDictionary *)body auth:(BOOL)auth cache:(NSTimeInterval)age max:(NSUInteger)max
           into:(NSMutableArray *)acc json:(void (^)(id first))first done:(void (^)(NSArray *items, NSError *e))done {
    [self call:endpoint body:body auth:auth cache:age done:^(id j, NSError *e) {
        if (!j) { done(acc.count ? acc : nil, e); return; }
        if (first) first(j);
        NSString *cont = nil;
        NSArray *items = [self videosIn:j cont:&cont channels:nil];
        NSMutableSet *have = [NSMutableSet new];
        for (SFItem *i in acc) [have addObject:i.identifier];
        for (SFItem *i in items) if (![have containsObject:i.identifier]) [acc addObject:i];
        if (cont && acc.count < max && items.count)
            [self collect:endpoint body:@{@"continuation": cont} auth:auth cache:age max:max into:acc json:nil done:done];
        else done(acc, nil);
    }];
}

+ (SFPageLoader)playlistLoader:(NSString *)pid title:(NSString *)title {
    return ^(SFPageDone done) {
        [self collect:@"browse" body:@{@"browseId": [@"VL" stringByAppendingString:pid]} auth:gCookieHeader != nil cache:600 max:300
                 into:[NSMutableArray new] json:nil done:^(NSArray *items, NSError *e) {
            if (!items) { done(nil, e); return; }
            for (SFItem *i in items) i.playlistID = pid;   // Wiedergabe folgt der Playlist-Reihenfolge
            SFPage *p = [SFPage page:title theme:@"youtube" shelves:@[[SFShelf grid:[NSString stringWithFormat:@"%lu Videos", (unsigned long)items.count] style:SFTileStyleLandscape items:items]]];
            if (!items.count) p.emptyText = @"Diese Playlist ist leer.";
            done(p, nil);
        }];
    };
}

+ (SFPageLoader)channelLoader:(NSString *)cid title:(NSString *)title {
    return ^(SFPageDone done) {
        // Alle Uploads, neueste zuerst: Playlist "UU" + Kanal-ID ohne "UC"
        // "UULF" = nur Langvideos (ohne Shorts); Fallback "UU" = alle Uploads
        NSString *uploads = [cid hasPrefix:@"UC"] ? [@"UULF" stringByAppendingString:[cid substringFromIndex:2]] : nil;
        __block NSString *banner = nil, *desc = nil, *meta = nil, *avatar = nil;
        __block NSArray *playlists = nil, *popular = nil, *streams = nil;
        void (^build)(NSArray *, NSError *) = ^(NSArray *items, NSError *e) {
            NSMutableArray *shelves = [NSMutableArray new];
            NSMutableArray *live = [NSMutableArray new], *vids = [NSMutableArray new];
            for (SFItem *i in items) [(i.kind == SFItemLive ? live : vids) addObject:i];
            // Live-Tab: laufende Streams zu „Jetzt live“ (ohne Doppelte), vergangene als eigenes Regal
            NSMutableArray *pastStreams = [NSMutableArray new];
            NSMutableSet *liveIDs = [NSMutableSet setWithArray:[live valueForKey:@"identifier"]];
            for (SFItem *i in streams) {
                if (i.kind == SFItemLive) { if (i.identifier && ![liveIDs containsObject:i.identifier]) { [liveIDs addObject:i.identifier]; [live addObject:i]; } }
                else if (i.kind != SFItemFolder) [pastStreams addObject:i];
            }
            // Kanalkopf wie bei YouTube: kompakte Knöpfe unter Banner/Name statt großer Kachel.
            // [Folgen] (rot, solange nicht gefolgt) · [Automatisch laden: An/Aus] (nur wenn gefolgt)
            SFDownloads *dl = [SFDownloads shared];
            SFFollows *fo = [SFFollows shared];
            NSString *fid = [@"ytchannel:" stringByAppendingString:cid];
            SFItem *folder = [SFItem new];
            folder.kind = SFItemFolder; folder.identifier = fid; folder.title = title; folder.source = @"youtube"; folder.image = avatar;
            BOOL following = [fo isFollowing:fid], autoDL = [dl isSubscribed:fid];
            SFNavigator *(^navi)(void) = ^SFNavigator *{ id d = [NSApp delegate]; return [d respondsToSelector:@selector(nav)] ? [d performSelector:@selector(nav)] : nil; };
            NSMutableArray *buttons = [NSMutableArray new];
            SFItem *fb = [SFItem new];
            fb.kind = SFItemAction; fb.style = SFTileStyleButton; fb.source = @"youtube"; fb.themeName = @"youtube";
            fb.identifier = [@"ytfollow:" stringByAppendingString:cid];
            fb.title = following ? @"✓  Gefolgt" : @"Folgen";
            if (!following) fb.tint = [SFTheme themeNamed:@"youtube"].accent;
            fb.backdrop = banner; fb.heroTitle = title; fb.heroMeta = meta; fb.plot = desc;
            fb.action = ^{
                if ([fo isFollowing:fid]) {
                    // Wie YouTube („Abo beenden?“): Entfolgen nur mit Rückfrage – der Knopf hat beim
                    // Öffnen den Fokus, ein reflexhaftes OK darf den Kanal nicht stillschweigend entfernen.
                    SFNavigator *nav = navi();
                    BOOL dlOn = [dl isSubscribed:fid];
                    SFMenuOption *no = [SFMenuOption option:@"Abbrechen" action:^{}];
                    SFMenuOption *yes = [SFMenuOption option:@"Nicht mehr folgen" action:^{
                        [fo unfollow:fid];
                        [nav toast:[NSString stringWithFormat:@"Du folgst „%@“ nicht mehr", title]];
                    }];
                    NSString *sub = dlOn ? @"Neue Videos erscheinen nicht mehr unter „Neue Folgen“ und werden nicht mehr geladen. Vorhandene Downloads bleiben."
                                         : @"Neue Videos erscheinen dann nicht mehr unter „Neue Folgen“.";
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [nav push:[[SFMenuScreen alloc] initWithTitle:[NSString stringWithFormat:@"„%@“ nicht mehr folgen?", title]
                                                             subtitle:sub options:@[no, yes] theme:[SFTheme themeNamed:@"youtube"]]];
                    });
                }
                else { [fo follow:folder]; [navi() toast:[NSString stringWithFormat:@"Du folgst „%@“ – neue Videos erscheinen unter „Neue Folgen“", title]]; }
            };
            [buttons addObject:fb];
            if (following) {
                SFItem *db = [SFItem new];
                db.kind = SFItemAction; db.style = SFTileStyleButton; db.source = @"youtube"; db.themeName = @"youtube";
                db.identifier = [@"ytautodl:" stringByAppendingString:cid];
                db.title = autoDL ? @"Automatisch laden: An" : @"Automatisch laden: Aus";
                db.backdrop = banner; db.heroTitle = title; db.heroMeta = meta;
                db.plot = @"Neue Videos dieses Kanals automatisch herunterladen – dann laufen sie auch ohne Internet.";
                db.action = ^{
                    if ([dl isSubscribed:fid]) { [dl unsubscribe:fid]; [navi() toast:@"Automatisch laden aus – vorhandene Videos bleiben"]; }
                    else { [dl subscribe:folder]; [navi() toast:[NSString stringWithFormat:@"Neue Videos von „%@“ werden heruntergeladen", title]]; }
                    [[NSNotificationCenter defaultCenter] postNotificationName:SFLibraryDidChangeNotification object:nil];
                };
                [buttons addObject:db];
            }
            [shelves addObject:[SFShelf shelf:nil style:SFTileStyleButton items:buttons]];
            if (live.count) [shelves addObject:[SFShelf shelf:@"Jetzt live" style:SFTileStyleLandscape items:live]];
            SFShow *local = [[SFLibrary shared] showNamed:title source:@"youtube"];
            if (local.episodes.count) {
                NSMutableArray *started = [NSMutableArray new];
                for (SFItem *x in local.episodes) { double pr = [[SFStore shared] progressFor:x.identifier]; if (pr > 0 && pr < 1) [started addObject:x]; }
                if (started.count) [shelves addObject:[SFShelf shelf:@"Weiterschauen" style:SFTileStyleLandscape items:started]];
            }
            if (vids.count) [shelves addObject:[SFShelf shelf:@"Neueste Videos" style:SFTileStyleLandscape items:[vids subarrayWithRange:NSMakeRange(0, MIN(vids.count, (NSUInteger)12))]]];
            if (popular.count >= 4) [shelves addObject:[SFShelf shelf:@"Beliebt" style:SFTileStyleLandscape items:[popular subarrayWithRange:NSMakeRange(0, MIN(popular.count, (NSUInteger)12))]]];
            if (playlists.count) [shelves addObject:[SFShelf shelf:@"Playlists" style:SFTileStyleLandscape items:playlists]];
            if (pastStreams.count) [shelves addObject:[SFShelf shelf:@"Livestreams" style:SFTileStyleLandscape items:[pastStreams subarrayWithRange:NSMakeRange(0, MIN(pastStreams.count, (NSUInteger)12))]]];
            // Ältere Videos weiter unten als Raster (wie der Videos-Tab), ohne die Reihe oben zu wiederholen
            if (vids.count > 12) [shelves addObject:[SFShelf grid:@"Alle Videos" style:SFTileStyleLandscape items:[vids subarrayWithRange:NSMakeRange(12, vids.count - 12)]]];
            if (!shelves.count && !items) { done(nil, e); return; }
            SFPage *p = [SFPage page:title theme:@"youtube" shelves:shelves];
            p.backdrop = banner;
            if (!shelves.count) p.emptyText = @"Dieser Kanal hat keine Videos.";
            done(p, nil);
        };
        if (!uploads) { build(nil, SFError(@"Unbekannter Kanal.")); return; }
        // Kanalkopf (Banner, Abonnenten, Beschreibung) parallel zu den Uploads
        dispatch_group_t g = dispatch_group_create();
        dispatch_group_enter(g);
        [self call:@"browse" body:@{@"browseId": cid} auth:NO cache:86400 done:^(id j, NSError *he) {
            NSDictionary *vm = dict(path(j, @"header.pageHeaderRenderer.content.pageHeaderViewModel"));
            // Banner-Vorlage ist 2560x1440; ohne fcrop-Ausschnitt = volles TV-Motiv (16:9)
            NSString *bu = str(dict(arr(path(vm, @"banner.imageBannerViewModel.image.sources")).lastObject)[@"url"]);
            NSRange eq = [bu rangeOfString:@"=" options:NSBackwardsSearch];
            if (eq.location != NSNotFound) banner = [[bu substringToIndex:eq.location] stringByAppendingString:@"=w1920-fcrop64=1,00000000ffffffff-k-c0xffffffff-no-nd-rj"];
            avatar = str(dict(arr(path(vm, @"image.decoratedAvatarViewModel.avatar.avatarViewModel.image.sources")).lastObject)[@"url"]);
            NSMutableArray *parts = [NSMutableArray new];
            for (NSDictionary *row in arr(path(vm, @"metadata.contentMetadataViewModel.metadataRows")))
                for (NSDictionary *pt in arr(dict(row)[@"metadataParts"])) { NSString *t = str(path(pt, @"text.content")); if (t.length) [parts addObject:t]; }
            meta = parts.count ? [parts componentsJoinedByString:@" · "] : nil;
            desc = str(path(vm, @"description.descriptionPreviewViewModel.description.content"));
            dispatch_group_leave(g);
        }];
        // Playlists-Tab des Kanals (wie bei YouTube): parallel
        dispatch_group_enter(g);
        [self call:@"browse" body:@{@"browseId": cid, @"params": @"EglwbGF5bGlzdHPyBgQKAkIA"} auth:NO cache:3600 done:^(id j, NSError *pe) {
            NSMutableArray *pl = [NSMutableArray new];
            for (SFItem *i in (j ? [self videosIn:j cont:NULL channels:nil] : @[])) if (i.kind == SFItemFolder && ![i.identifier hasPrefix:@"ytplaylist:RD"]) { i.style = SFTileStyleLandscape; [pl addObject:i]; }   // Mixe (RD…) sind keine Kanal-Playlists
            playlists = pl;
            dispatch_group_leave(g);
        }];
        // „Beliebt“ wie im Videos-Tab von YouTube: Tab laden, Sortier-Chip „Beliebt“ → dessen Fortsetzung
        // liefert die Videos nach Aufrufen sortiert (Chip-Text sprachabhängig; sonst der zweite von drei)
        dispatch_group_enter(g);
        [self call:@"browse" body:@{@"browseId": cid, @"params": @"EgZ2aWRlb3PyBgQKAjoA"} auth:NO cache:86400 done:^(id j, NSError *ve) {
            NSString *tok = nil;
            for (NSDictionary *tab in arr(path(j, @"contents.twoColumnBrowseResultsRenderer.tabs"))) {
                NSArray *chips = arr(path(tab, @"tabRenderer.content.richGridRenderer.header.chipBarViewModel.chips"));
                for (NSUInteger k = 0; k < chips.count && !tok; k++) {
                    NSDictionary *c = dict(dict(chips[k])[@"chipViewModel"]);
                    NSString *t = str(c[@"text"]);
                    if ([t isEqualToString:@"Beliebt"] || [t isEqualToString:@"Popular"] || (chips.count == 3 && k == 1 && !t.length))
                        tok = str(path(c, @"tapCommand.innertubeCommand.continuationCommand.token"));
                }
                if (!tok && chips.count == 3) tok = str(path(dict(chips[1]), @"chipViewModel.tapCommand.innertubeCommand.continuationCommand.token"));
            }
            if (!tok) { dispatch_group_leave(g); return; }
            [self call:@"browse" body:@{@"continuation": tok} auth:NO cache:86400 done:^(id pj, NSError *pe) {
                NSMutableArray *pv = [NSMutableArray new];
                for (SFItem *i in (pj ? [self videosIn:pj cont:NULL channels:nil] : @[])) if (i.kind != SFItemFolder && i.kind != SFItemLive) [pv addObject:i];   // auch heruntergeladene (lokale Kopie)
                popular = pv;
                dispatch_group_leave(g);
            }];
        }];
        // Live-Tab (wie bei YouTube): laufende + vergangene Streams; kurz gecacht, Live-Status ändert sich
        dispatch_group_enter(g);
        [self call:@"browse" body:@{@"browseId": cid, @"params": @"EgdzdHJlYW1z8gYECgJ6AA=="} auth:NO cache:600 done:^(id j, NSError *le) {
            streams = j ? [self videosIn:j cont:NULL channels:nil] : nil;
            dispatch_group_leave(g);
        }];
        void (^build0)(NSArray *, NSError *) = build;
        build = ^(NSArray *items, NSError *e) { dispatch_group_notify(g, dispatch_get_main_queue(), ^{ build0(items, e); }); };
        [self collect:@"browse" body:@{@"browseId": [@"VL" stringByAppendingString:uploads]} auth:NO cache:600 max:100
                 into:[NSMutableArray new] json:nil done:^(NSArray *items, NSError *e) {
            if (items.count) { [[SFLibrary shared] whenReady:^{ build(items, e); }]; return; }
            NSString *all = [@"VLUU" stringByAppendingString:[cid substringFromIndex:2]];
            [self collect:@"browse" body:@{@"browseId": all} auth:NO cache:600 max:100 into:[NSMutableArray new] json:nil done:^(NSArray *i2, NSError *e2) {
                [[SFLibrary shared] whenReady:^{ build(i2, e2); }];
            }];
        }];
    };
}

+ (SFPageLoader)searchLoader:(NSString *)q {
    return ^(SFPageDone done) {
        // Erste Seite liefert auch die Kanäle; Fortsetzungsseiten bis ~60 Treffer
        NSMutableArray *channels = [NSMutableArray new];
        [self collect:@"search" body:@{@"query": q ?: @""} auth:NO cache:600 max:60 into:[NSMutableArray new]
                 json:^(id first) { [self videosIn:first cont:NULL channels:channels]; }
                 done:^(NSArray *all, NSError *e) {
            if (!all) { done(nil, e); return; }
            // Reihenfolge von YouTube (Relevanz) behalten; Mixe (RD…) sind keine echten Playlists
            NSMutableArray *results = [NSMutableArray new];
            for (SFItem *i in all) if (![i.identifier hasPrefix:@"ytplaylist:RD"]) [results addObject:i];
            NSMutableArray *shelves = [NSMutableArray new];
            if (channels.count) [shelves addObject:[SFShelf shelf:@"Kanäle" style:SFTileStyleCircle items:channels]];
            if (results.count) [shelves addObject:[SFShelf grid:@"Videos und Playlists" style:SFTileStyleLandscape items:results]];
            SFPage *p = [SFPage page:[NSString stringWithFormat:@"„%@“", q] theme:@"youtube" shelves:shelves];
            if (!shelves.count) p.emptyText = [NSString stringWithFormat:@"Keine Treffer für „%@“.", q];
            done(p, nil);
        }];
    };
}

+ (void)suggestions:(NSString *)prefix done:(void (^)(NSArray *))done {
    NSString *u = [NSString stringWithFormat:@"https://suggestqueries-clients6.youtube.com/complete/search?client=youtube&ds=yt&hl=de&gl=AT&oe=utf-8&xhr=t&q=%@",
                   [SFNet escape:prefix]];
    [SFNet getJSON:u headers:nil cacheAge:0 done:^(id j, NSError *e) {
        // ["q", [["vorschlag", 0, [...]], ...], {...}]
        NSMutableArray *out = [NSMutableArray new];
        for (id s in arr(arr(j).count > 1 ? arr(j)[1] : nil)) {
            NSString *t = str(arr(s).firstObject) ?: str(s);
            if (t.length) [out addObject:t];
        }
        done(out);
    }];
}

+ (SFPageLoader)homeLoader {
    return ^(SFPageDone done) {
        __block NSArray *subs = nil, *later = nil;
        NSMutableArray *channels = [NSMutableArray new];
        __block NSError *authErr = nil;
        dispatch_group_t g = dispatch_group_create();
        BOOL auth = gCookieHeader != nil;
        if (auth) {
            dispatch_group_enter(g);
            [self call:@"browse" body:@{@"browseId": @"FEsubscriptions"} auth:YES cache:300 done:^(id j, NSError *e) {
                subs = j ? [self videosIn:j cont:NULL channels:nil] : nil;
                if (!j) authErr = e;
                dispatch_group_leave(g);
            }];
            dispatch_group_enter(g);
            [self call:@"browse" body:@{@"browseId": @"VLWL"} auth:YES cache:120 done:^(id j, NSError *e) {
                later = j ? [self videosIn:j cont:NULL channels:nil] : nil;
                dispatch_group_leave(g);
            }];
            dispatch_group_enter(g);
            [self call:@"browse" body:@{@"browseId": @"FEchannels"} auth:YES cache:3600 done:^(id j, NSError *e) {
                if (j) [self videosIn:j cont:NULL channels:channels];
                dispatch_group_leave(g);
            }];
        }
        dispatch_group_enter(g);
        [[SFLibrary shared] whenReady:^{ dispatch_group_leave(g); }];
        dispatch_group_notify(g, dispatch_get_main_queue(), ^{
            NSMutableArray *shelves = [NSMutableArray new];
            NSArray *cont = [[SFStore shared] continueWatching:20 source:@"youtube"];
            if (cont.count) [shelves addObject:[SFShelf shelf:@"Weiterschauen" style:SFTileStyleLandscape items:cont]];
            // Folgen-Konzept (User 2026-11-03): eine gemeinsame Sofa-Liste statt Konto-Abos.
            // Die Kanäle des angemeldeten Kontos werden einmalig als Folgen übernommen.
            SFFollows *fo = [SFFollows shared];
            [fo importFollows:channels key:@"follows.ytAccountImported"];
            NSMutableArray *lives = [NSMutableArray new];
            for (SFItem *i in subs) if (i.kind == SFItemLive) [lives addObject:i];
            if (lives.count) [shelves addObject:[SFShelf shelf:@"Jetzt live" style:SFTileStyleLandscape items:lives]];
            NSArray *news = [fo latest:40 source:@"youtube"];
            if (news.count) [shelves addObject:[SFShelf shelf:@"Neue Videos" style:SFTileStyleLandscape items:news]];
            else {   // offline / erste Aktualisierung läuft: Heruntergeladenes
                NSArray *latest = [[NSArray alloc] initWithArray:[[SFLibrary shared] latestEpisodes:40 source:@"youtube"] copyItems:YES];
                for (SFItem *e in latest) e.subtitle = [NSString stringWithFormat:@"%@ · %@", e.channel, SFFormatDateShort(e.date)];
                if (latest.count) [shelves addObject:[SFShelf shelf:@"Neu heruntergeladen" style:SFTileStyleLandscape items:latest]];
            }
            if (later.count) [shelves addObject:[SFShelf shelf:@"Später ansehen" style:SFTileStyleLandscape items:later]];
            // Kanäle: gefolgte (echte Kanalseiten) + heruntergeladene ohne bekannte Kanal-ID (Offline-Seite)
            NSMutableArray *chs = [NSMutableArray new];
            NSMutableSet *names = [NSMutableSet new];
            for (SFItem *c in [fo follows:@"youtube"]) { c.style = SFTileStyleCircle; [chs addObject:c]; [names addObject:c.title.lowercaseString]; }
            for (SFShow *sh in [[SFLibrary shared] showsForSource:@"youtube"]) {
                if ([names containsObject:sh.name.lowercaseString]) continue;
                SFItem *i = [SFItem new];
                i.kind = SFItemFolder; i.title = sh.name; i.identifier = [@"show:" stringByAppendingString:sh.name];
                i.image = sh.poster; i.style = SFTileStyleCircle; i.source = @"youtube"; i.themeName = @"youtube";
                i.subtitle = @"Heruntergeladen";
                NSString *name = sh.name;
                i.pageLoader = ^(SFPageDone d2) {
                    SFShow *s2 = [[SFLibrary shared] showNamed:name source:@"youtube"];
                    SFPage *p = [SFPage page:name theme:@"youtube" shelves:@[[SFShelf grid:@"Heruntergeladen" style:SFTileStyleLandscape items:s2.episodes ?: @[]]]];
                    d2(p, nil);
                };
                [chs addObject:i];
            }
            // Handy (YouTube „Mit TV verbinden“): Status + Einstellungen; „Neues Handy verbinden“ steckt im Menü
            SFItem *pair = [SFHome phoneTile];
            pair.style = SFTileStyleWide; pair.source = @"youtube"; pair.themeName = @"youtube";
            pair.image = SFIconArt(@"phone", @"youtube");
            [shelves addObject:[SFShelf shelf:@"Mehr" style:SFTileStyleWide items:@[[SFHome downloadsTile:@"youtube"], pair]]];
            // Kanäle alphabetisch (online + lokal gemischt), wie man sie im Kopf sucht
            [chs sortUsingComparator:^NSComparisonResult(SFItem *x, SFItem *y) { return [x.title localizedCaseInsensitiveCompare:y.title]; }];
            if (chs.count) [shelves addObject:[SFShelf grid:@"Kanäle" style:SFTileStyleCircle items:chs]];
            SFPage *p = [SFPage page:nil theme:@"youtube" shelves:shelves];
            // Kein Anmelde-Hinweis in der Oberfläche (Gerät für alle; ohne Anmeldung gibt es eben keine Abos-Regale)
            if (authErr) SFLog(@"yt: Abos nicht verfügbar: %@", authErr.localizedDescription);
            if (!shelves.count) p.emptyText = @"YouTube ist gerade nicht erreichbar.";
            done(p, nil);
        });
    };
}

#pragma mark - Einzelvideo (Handy-Koppeln)

+ (SFItem *)itemForVideoID:(NSString *)vid {
    return [self videoItem:vid title:@"YouTube" channel:nil channelID:nil meta:nil thumb:nil duration:0 live:NO];
}

+ (void)fillDetails:(SFItem *)item done:(dispatch_block_t)done {
    if (item.localPath || !item.externalID) { if (done) done(); return; }
    [self call:@"player" body:@{@"videoId": item.externalID, @"contentCheckOk": @YES, @"racyCheckOk": @YES} auth:NO cache:3600 done:^(id j, NSError *e) {
        NSDictionary *vd = dict(dict(j)[@"videoDetails"]);
        if (vd) {
            item.title = str(vd[@"title"]) ?: item.title;
            item.channel = str(vd[@"author"]);
            item.subtitle = item.channel;
            item.plot = str(vd[@"shortDescription"]);
            item.duration = [str(vd[@"lengthSeconds"]) doubleValue];
            if ([vd[@"isLive"] boolValue] || ([vd[@"isLiveContent"] boolValue] && item.duration == 0)) {
                item.kind = SFItemLive; item.badge = @"LIVE";
                item.resolverRef = [@"ytlive:" stringByAppendingString:item.externalID];
            }
            item.image = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", item.externalID];
            item.backdrop = item.image;
        }
        if (done) done();
    }];
}

#pragma mark - Setup

+ (void)upNextFor:(NSString *)vid done:(void (^)(SFItem *))done {
    [self call:@"next" body:@{@"videoId": vid} auth:NO cache:1800 done:^(id j, NSError *e) {
        id sec = path(j, @"contents.twoColumnWatchNextResults.secondaryResults.secondaryResults.results");
        SFItem *pick = nil;
        for (SFItem *i in (sec ? [self videosIn:sec cont:NULL channels:nil] : @[])) {
            if (i.kind != SFItemVideo || !i.identifier || [i.externalID isEqualToString:vid]) continue;
            if (i.duration > 0 && i.duration < 90) continue;                 // keine Shorts
            if ([[SFStore shared] watched:i.identifier]) continue;           // schon gesehen
            pick = i; break;
        }
        SFMain(^{ done(pick); });
    }];
}

+ (void)resolveChannelURL:(NSString *)url done:(void (^)(NSString *))done {
    [self call:@"navigation/resolve_url" body:@{@"url": url} auth:NO cache:86400 done:^(id j, NSError *e) {
        id be = [j isKindOfClass:[NSDictionary class]] ? j[@"endpoint"][@"browseEndpoint"][@"browseId"] : nil;
        SFMain(^{ done([be isKindOfClass:[NSString class]] && [be hasPrefix:@"UC"] ? be : nil); });
    }];
}

+ (void)setup {
    SFRegisterResolver(@"yt", ^(NSString *vid, SFURLDone done) {
        SFItem *local = [[SFLibrary shared] episodeForYouTubeID:vid];
        if (local.localPath && [[NSFileManager defaultManager] fileExistsAtPath:local.localPath]) { done([NSURL fileURLWithPath:local.localPath], nil); return; }
        [[SFYTResolver shared] resolve:vid live:NO done:^(NSDictionary *r, NSError *e) {
            NSURL *u = r ? [NSURL URLWithString:r[@"url"]] : nil;
            if (u) SFSetAlternateURLs(u, r[@"alt"]);
            if (u && [r[@"dash"] isKindOfClass:[NSDictionary class]]) {   // VP9/AV1 für die mpv-Engine
                NSMutableDictionary *d = [r[@"dash"] mutableCopy];
                if (r[@"height"]) d[@"hlsHeight"] = r[@"height"];
                if (r[@"fps"]) d[@"hlsFps"] = r[@"fps"];
                SFSetMPVSource(u, d);
            }
            done(u, e);
        }];
    });
    // Abo-Feed: Langvideos eines Kanals, neueste zuerst (immer als Online-Items)
    SFRegisterShowPage(@"ytchannel", ^SFPageLoader(NSString *cid, NSString *title) { return [self channelLoader:cid title:title]; });
    SFRegisterFeed(@"ytchannel", ^(NSString *cid, void (^done)(NSArray *, NSError *)) {
        if (![cid hasPrefix:@"UC"]) { done(nil, SFError(@"Unbekannter Kanal")); return; }
        [self call:@"browse" body:@{@"browseId": [@"VLUULF" stringByAppendingString:[cid substringFromIndex:2]]} auth:NO cache:900 done:^(id j, NSError *e) {
            NSMutableArray *online = [NSMutableArray new];
            for (SFItem *i in (j ? [self videosIn:j cont:NULL channels:nil] : @[])) {
                if (i.kind != SFItemVideo) continue;
                if (i.localPath) {   // lokale Kopie ersetzt: Online-Identität wiederherstellen
                    SFItem *o = [self videoItemOnline:i.externalID ?: restOfID(i.identifier)];
                    if (!o) continue;
                    o.title = i.title; o.channel = i.channel; o.date = i.date; o.duration = i.duration;
                    [online addObject:o];
                    continue;
                }
                [online addObject:i];
            }
            done(j ? online : nil, e);
        }];
    });
    // Downloads in 720p (wie bisher ytdl-sub): spart Platz, am TV gut genug
    SFRegisterDownloadURL(@"yt", ^(SFItem *item, SFURLDone done) {
        NSString *vid = item.externalID ?: restOfID(item.identifier);
        [[SFYTResolver shared] resolve:vid live:NO done:^(NSDictionary *r, NSError *e) {
            NSString *u = r[@"url"];
            for (NSString *a in r[@"alt"]) if ([a rangeOfString:@"/itag/95/"].location != NSNotFound) { u = a; break; }
            done(u ? [NSURL URLWithString:u] : nil, e);
        }];
    });
    SFRegisterResolver(@"ytlive", ^(NSString *vid, SFURLDone done) {
        [[SFYTResolver shared] resolve:vid live:YES done:^(NSDictionary *r, NSError *e) {
            done(r ? [NSURL URLWithString:r[@"url"]] : nil, e);
        }];
    });
    SFBackground(^{
        [self loadCookies];
        SFMain(^{ [[SFYTResolver shared] start]; });
    });
    // Firefox rotiert Session-Cookies -> regelmäßig neu lesen
    [NSTimer scheduledTimerWithTimeInterval:3 * 3600 target:self selector:@selector(refreshCookies) userInfo:nil repeats:YES];
}

+ (void)refreshCookies { SFBackground(^{ [self loadCookies]; }); }
@end
