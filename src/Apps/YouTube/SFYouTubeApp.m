#import "SFYouTubeApp.h"
#import "SFJSON.h"
#import "SFMenuScreen.h"
#import "SFYTResolver.h"
#import "SFYTSabr.h"
#import "SFYTBreaker.h"
#import "SFStats.h"
#import "SFSettings.h"
#import "SFNet.h"
#import "SFStore.h"
#import "SFLibrary.h"
#import "SFIconArt.h"
#import "SFPairScreen.h"
#import "SFLounge.h"
#import "SFLibraryPages.h"
#import "SFPlayerScreen.h"
#import "SFDownloads.h"
#import "SFCurl.h"
#import "SFFollows.h"
#import "SFWatchLater.h"
#import "SFEngine.h"
#import "SFScreen.h"
#import <sqlite3.h>
#import <sys/stat.h>

static NSString *const kClientVersion = @"2.20261030.02.00";
static NSString *const kOrigin = @"https://www.youtube.com";

// TV-sized picture of a video (backdrop); falls back to the tile picture where missing (SFImageLayer)
static NSString *SFYouTubeBackdrop(NSString *videoID) {
    return videoID.length ? [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/maxresdefault.jpg", videoID] : nil;
}
static SFItem *downloadedVideo(NSString *vid) { return vid.length ? [[SFDownloads shared] itemFor:[@"yt:" stringByAppendingString:vid]] : nil; }

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
// If a channel lacks the requested tab (e.g. no "Live"), YouTube silently returns the
// "Home" tab - its content would then wrongly show up as e.g. "Livestreams".
static BOOL selectedTabIs(id j, NSString *suffix) {
    for (id t in arr(path(j, @"contents.twoColumnBrowseResultsRenderer.tabs"))) {
        NSDictionary *tr = dict(dict(t)[@"tabRenderer"]);
        if (![tr[@"selected"] boolValue]) continue;
        return [str(path(tr, @"endpoint.commandMetadata.webCommandMetadata.url")) hasSuffix:suffix];
    }
    return NO;
}
// text node: "..." | {simpleText} | {runs:[{text}]} | {content}
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

// "vor 3 Tagen", "vor 1 Stunde", "vor 2 Wochen", "vor 5 Monaten", "vor 1 Jahr" (also
// "... gestreamt", "Premiere vor ...") -> approximate date. FALLBACK ONLY: InnerTube lists carry
// nothing better; feeds take exact times from RSS (rssPublished), the info panel from the watch page.
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

@implementation SFYouTubeApp

#pragma mark - InnerTube

// Without sign-in (user 2026-11-04: no dependency on Firefox/account) - everything Sofa
// needs (channels, playlists, search, player data, recommendations) is public.
+ (void)call:(NSString *)endpoint body:(NSDictionary *)body cache:(NSTimeInterval)age done:(SFJSONDone)done {
    NSMutableDictionary *b = [body mutableCopy];
    b[@"context"] = @{@"client": @{@"clientName": @"WEB", @"clientVersion": kClientVersion, @"hl": @"de", @"gl": @"AT"}};
    NSDictionary *h = @{@"X-Youtube-Client-Name": @"1", @"X-Youtube-Client-Version": kClientVersion, @"Origin": kOrigin};
    NSString *url = [NSString stringWithFormat:@"https://www.youtube.com/youtubei/v1/%@?prettyPrint=false", endpoint];
    [SFNet postJSON:url body:b headers:h cacheAge:age done:done];
}

static NSString *restOfID(NSString *ident) { NSRange r = [ident rangeOfString:@":"]; return r.location == NSNotFound ? ident : [ident substringFromIndex:NSMaxRange(r)]; }

#pragma mark - Parser (recursive walker, docs/youtube.md §3.0)

+ (SFItem *)videoItem:(NSString *)vid title:(NSString *)title channel:(NSString *)channel channelID:(NSString *)cid
                  meta:(NSString *)meta thumb:(NSString *)thumb duration:(NSTimeInterval)dur live:(BOOL)live {
    if (vid.length != 11) return nil;
    SFItem *local = downloadedVideo(vid);
    if (local) {   // already downloaded: local file (quality, offline, shared progress)
        SFItem *i = [local copy];
        i.subtitle = meta.length ? [NSString stringWithFormat:@"%@ · auf diesem Mac", meta] : @"Auf diesem Mac";
        if (!i.showRef && [cid hasPrefix:@"UC"]) i.showRef = [@"ytchannel:" stringByAppendingString:cid];
        return i;
    }
    SFItem *i = [SFItem new];
    i.kind = live ? SFItemLive : SFItemVideo;
    i.identifier = [@"yt:" stringByAppendingString:vid];
    i.resolverRef = [(live ? @"ytlive:" : @"yt:") stringByAppendingString:vid];
    i.externalID = vid;
    i.title = title;
    i.channel = channel;
    if ([cid hasPrefix:@"UC"]) i.showRef = [@"ytchannel:" stringByAppendingString:cid];
    i.subtitle = meta;
    i.image = thumb ?: [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", vid];
    i.backdrop = SFYouTubeBackdrop(vid);
    i.duration = dur;
    i.source = @"youtube"; i.themeName = @"youtube";
    i.style = SFTileStyleLandscape;
    if (live) i.badge = @"LIVE";
    return i;
}

// Online item without replacement by the local copy (for downloads/subscriptions)
+ (SFItem *)videoItemOnline:(NSString *)vid {
    if (vid.length != 11) return nil;
    SFItem *i = [SFItem new];
    i.kind = SFItemVideo;
    i.identifier = [@"yt:" stringByAppendingString:vid];
    i.resolverRef = i.identifier;
    i.externalID = vid;
    i.image = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", vid];
    i.backdrop = SFYouTubeBackdrop(vid);
    i.source = @"youtube"; i.themeName = @"youtube"; i.style = SFTileStyleLandscape;
    return i;
}

+ (SFItem *)channelItem:(NSString *)cid title:(NSString *)title avatar:(NSString *)avatar meta:(NSString *)meta {
    if (!cid.length || !title.length) return nil;
    SFItem *f = [SFItem new];
    f.kind = SFItemFolder;
    f.identifier = [@"ytchannel:" stringByAppendingString:cid];
    f.title = title; f.subtitle = meta;
    // avatar size freely selectable (=s88-... -> =s400-...)
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
        if (upcoming) return nil;   // not playable yet
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
    return nil;   // Shorts, channel lockups etc.
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

#pragma mark - Pages

+ (SFItem *)folder:(NSString *)title ident:(NSString *)ident loader:(SFPageLoader)l {
    SFItem *f = [SFItem new];
    f.kind = SFItemFolder; f.title = title; f.identifier = ident;
    f.themeName = @"youtube"; f.source = @"youtube"; f.style = SFTileStyleWide;
    f.pageLoader = l;
    return f;
}

// List with loading of continuation pages (up to max entries)
+ (void)collect:(NSString *)endpoint body:(NSDictionary *)body cache:(NSTimeInterval)age max:(NSUInteger)max
           into:(NSMutableArray *)acc json:(void (^)(id first))first done:(void (^)(NSArray *items, NSError *e))done {
    [self call:endpoint body:body cache:age done:^(id j, NSError *e) {
        if (!j) { done(acc.count ? acc : nil, e); return; }
        if (first) first(j);
        NSString *cont = nil;
        NSArray *items = [self videosIn:j cont:&cont channels:nil];
        NSMutableSet *have = [NSMutableSet new];
        for (SFItem *i in acc) [have addObject:i.identifier];
        for (SFItem *i in items) if (![have containsObject:i.identifier]) [acc addObject:i];
        if (cont && acc.count < max && items.count)
            [self collect:endpoint body:@{@"continuation": cont} cache:age max:max into:acc json:nil done:done];
        else done(acc, nil);
    }];
}

+ (SFPageLoader)playlistLoader:(NSString *)pid title:(NSString *)title {
    return ^(SFPageDone done) {
        [self collect:@"browse" body:@{@"browseId": [@"VL" stringByAppendingString:pid]} cache:600 max:300
                 into:[NSMutableArray new] json:nil done:^(NSArray *items, NSError *e) {
            if (!items) { done(nil, e); return; }
            for (SFItem *i in items) i.playlistID = pid;   // playback follows the playlist order
            SFPage *p = [SFPage page:title theme:@"youtube" shelves:@[[SFShelf grid:[NSString stringWithFormat:@"%lu Videos", (unsigned long)items.count] style:SFTileStyleLandscape items:items]]];
            if (!items.count) p.emptyText = @"Diese Playlist ist leer.";
            done(p, nil);
        }];
    };
}

+ (SFPageLoader)channelLoader:(NSString *)cid title:(NSString *)title {
    return ^(SFPageDone done) {
        // all uploads, newest first: playlist "UU" + channel ID without "UC"
        // "UULF" = long videos only (no Shorts); fallback "UU" = all uploads
        NSString *uploads = [cid hasPrefix:@"UC"] ? [@"UULF" stringByAppendingString:[cid substringFromIndex:2]] : nil;
        __block NSString *banner = nil, *desc = nil, *meta = nil, *avatar = nil;
        __block NSArray *playlists = nil, *popular = nil, *streams = nil;
        void (^build)(NSArray *, NSError *) = ^(NSArray *items, NSError *e) {
            NSMutableArray *shelves = [NSMutableArray new];
            NSMutableArray *live = [NSMutableArray new], *vids = [NSMutableArray new];
            for (SFItem *i in items) [(i.kind == SFItemLive ? live : vids) addObject:i];
            // live tab: running streams go to "Jetzt live" (without duplicates), past ones as their own shelf
            NSMutableArray *pastStreams = [NSMutableArray new];
            NSMutableSet *liveIDs = [NSMutableSet setWithArray:[live valueForKey:@"identifier"]];
            for (SFItem *i in streams) {
                if (i.kind == SFItemLive) { if (i.identifier && ![liveIDs containsObject:i.identifier]) { [liveIDs addObject:i.identifier]; [live addObject:i]; } }
                else if (i.kind != SFItemFolder) [pastStreams addObject:i];
            }
            // channel header like YouTube's: compact buttons under banner/name instead of a big tile.
            // [Folgen] (red while not followed) · [Automatisch laden: An/Aus] (only when followed)
            SFDownloads *dl = [SFDownloads shared];
            SFFollows *fo = [SFFollows shared];
            NSString *fid = [@"ytchannel:" stringByAppendingString:cid];
            SFItem *folder = [SFItem new];
            folder.kind = SFItemFolder; folder.identifier = fid; folder.title = title; folder.source = @"youtube"; folder.image = avatar;
            BOOL following = [fo isFollowing:fid], autoDL = [dl isSubscribed:fid];
            SFNavigator *(^navi)(void) = ^SFNavigator *{ return [SFNavigator main]; };
            NSMutableArray *buttons = [NSMutableArray new];
            SFItem *fb = [SFItem new];
            fb.kind = SFItemAction; fb.style = SFTileStyleButton; fb.source = @"youtube"; fb.themeName = @"youtube";
            fb.identifier = [@"ytfollow:" stringByAppendingString:cid];
            fb.title = following ? @"✓  Gefolgt" : @"Folgen";
            if (!following) fb.tint = [SFTheme themeNamed:@"youtube"].accent;
            fb.backdrop = banner; fb.heroTitle = title; fb.heroMeta = meta; fb.plot = desc;
            fb.action = ^{
                if ([fo isFollowing:fid]) {
                    // Like YouTube ("Abo beenden?"): unfollow only with confirmation - the button has focus
                    // on opening, a reflexive OK must not silently remove the channel.
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
            // older videos further down as a grid (like the videos tab), without repeating the row above
            if (vids.count > 12) [shelves addObject:[SFShelf grid:@"Alle Videos" style:SFTileStyleLandscape items:[vids subarrayWithRange:NSMakeRange(12, vids.count - 12)]]];
            if (!shelves.count && !items) { done(nil, e); return; }
            SFPage *p = [SFPage page:title theme:@"youtube" shelves:shelves];
            p.backdrop = banner;
            if (!shelves.count) p.emptyText = @"Dieser Kanal hat keine Videos.";
            done(p, nil);
        };
        if (!uploads) { build(nil, SFError(@"Unbekannter Kanal.")); return; }
        // channel header (banner, subscribers, description) in parallel to the uploads
        dispatch_group_t g = dispatch_group_create();
        dispatch_group_enter(g);
        [self call:@"browse" body:@{@"browseId": cid} cache:86400 done:^(id j, NSError *he) {
            NSDictionary *vm = dict(path(j, @"header.pageHeaderRenderer.content.pageHeaderViewModel"));
            // banner template is 2560x1440; without the fcrop crop = full TV image (16:9)
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
        // the channel's playlists tab (like YouTube): in parallel
        dispatch_group_enter(g);
        [self call:@"browse" body:@{@"browseId": cid, @"params": @"EglwbGF5bGlzdHPyBgQKAkIA"} cache:3600 done:^(id j, NSError *pe) {
            if (!selectedTabIs(j, @"/playlists")) j = nil;
            NSMutableArray *pl = [NSMutableArray new];
            for (SFItem *i in (j ? [self videosIn:j cont:NULL channels:nil] : @[])) if (i.kind == SFItemFolder && ![i.identifier hasPrefix:@"ytplaylist:RD"]) { i.style = SFTileStyleLandscape; [pl addObject:i]; }   // mixes (RD...) are not channel playlists
            playlists = pl;
            dispatch_group_leave(g);
        }];
        // "Beliebt" (popular) like in YouTube's videos tab: load the tab, sort chip "Beliebt" -> its continuation
        // returns the videos sorted by views (chip text is language-dependent; otherwise the second of three)
        dispatch_group_enter(g);
        [self call:@"browse" body:@{@"browseId": cid, @"params": @"EgZ2aWRlb3PyBgQKAjoA"} cache:86400 done:^(id j, NSError *ve) {
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
            [self call:@"browse" body:@{@"continuation": tok} cache:86400 done:^(id pj, NSError *pe) {
                NSMutableArray *pv = [NSMutableArray new];
                for (SFItem *i in (pj ? [self videosIn:pj cont:NULL channels:nil] : @[])) if (i.kind != SFItemFolder && i.kind != SFItemLive) [pv addObject:i];   // downloaded ones too (local copy)
                popular = pv;
                dispatch_group_leave(g);
            }];
        }];
        // live tab (like YouTube): running + past streams; cached briefly, live status changes
        dispatch_group_enter(g);
        [self call:@"browse" body:@{@"browseId": cid, @"params": @"EgdzdHJlYW1z8gYECgJ6AA=="} cache:600 done:^(id j, NSError *le) {
            streams = selectedTabIs(j, @"/streams") ? [self videosIn:j cont:NULL channels:nil] : nil;
            dispatch_group_leave(g);
        }];
        void (^build0)(NSArray *, NSError *) = build;
        build = ^(NSArray *items, NSError *e) { dispatch_group_notify(g, dispatch_get_main_queue(), ^{ build0(items, e); }); };
        [self collect:@"browse" body:@{@"browseId": [@"VL" stringByAppendingString:uploads]} cache:600 max:100
                 into:[NSMutableArray new] json:nil done:^(NSArray *items, NSError *e) {
            if (items.count) { [[SFLibrary shared] whenReady:^{ build(items, e); }]; return; }
            NSString *all = [@"VLUU" stringByAppendingString:[cid substringFromIndex:2]];
            [self collect:@"browse" body:@{@"browseId": all} cache:600 max:100 into:[NSMutableArray new] json:nil done:^(NSArray *i2, NSError *e2) {
                [[SFLibrary shared] whenReady:^{ build(i2, e2); }];
            }];
        }];
    };
}

+ (SFPageLoader)searchLoader:(NSString *)q {
    return ^(SFPageDone done) {
        // the first page also returns the channels; continuation pages up to ~60 hits
        NSMutableArray *channels = [NSMutableArray new];
        [self collect:@"search" body:@{@"query": q ?: @""} cache:600 max:60 into:[NSMutableArray new]
                 json:^(id first) { [self videosIn:first cont:NULL channels:channels]; }
                 done:^(NSArray *all, NSError *e) {
            if (!all) { done(nil, e); return; }
            // keep YouTube's order (relevance); mixes (RD...) are not real playlists
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
        // ["q", [["suggestion", 0, [...]], ...], {...}]
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
        dispatch_group_t g = dispatch_group_create();
        dispatch_group_enter(g);
        [[SFLibrary shared] whenReady:^{ dispatch_group_leave(g); }];
        dispatch_group_notify(g, dispatch_get_main_queue(), ^{
            NSMutableArray *shelves = [NSMutableArray new];
            NSArray *cont = [[SFStore shared] continueWatching:20 source:@"youtube"];
            if (cont.count) [shelves addObject:[SFShelf shelf:@"Weiterschauen" style:SFTileStyleLandscape items:cont]];
            // follow concept (user 2026-11-03): one shared Sofa list instead of account subscriptions
            SFFollows *fo = [SFFollows shared];
            NSArray *news = [fo latest:40 source:@"youtube"];
            if (news.count) [shelves addObject:[SFShelf shelf:@"Neue Videos" style:SFTileStyleLandscape items:news]];
            else {   // offline / first refresh running: downloaded content
                NSArray *latest = [[NSArray alloc] initWithArray:[[SFLibrary shared] recentDownloads:40 source:@"youtube"] copyItems:YES];
                for (SFItem *e in latest) e.subtitle = SFDotJoin(e.channel, SFFormatDateShort(e.date));
                if (latest.count) [shelves addObject:[SFShelf shelf:@"Neu heruntergeladen" style:SFTileStyleLandscape items:latest]];
            }
            // channels: followed (real channel pages) + downloaded ones without a known channel ID (offline page)
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
            // phone (YouTube "Link with TV code"): status + settings; "Neues Handy verbinden" lives in the menu
            SFItem *pair = [self phoneTile];
            pair.style = SFTileStyleWide; pair.source = @"youtube"; pair.themeName = @"youtube";
            pair.image = SFIconArt(@"phone", @"youtube");
            [shelves addObject:[SFShelf shelf:@"Mehr" style:SFTileStyleWide items:@[[SFLibraryPages downloadsTile:@"youtube"], pair]]];
            // channels alphabetically (online + local mixed), the way you look for them in your head
            [chs sortUsingComparator:^NSComparisonResult(SFItem *x, SFItem *y) { return [x.title localizedCaseInsensitiveCompare:y.title]; }];
            if (chs.count) [shelves addObject:[SFShelf grid:@"Kanäle" style:SFTileStyleCircle items:chs]];
            SFPage *p = [SFPage page:nil theme:@"youtube" shelves:shelves];
            if (!shelves.count) p.emptyText = @"YouTube ist gerade nicht erreichbar.";
            done(p, nil);
        });
    };
}

#pragma mark - Single video (phone pairing)

+ (SFItem *)itemForVideoID:(NSString *)vid {
    return [self videoItem:vid title:@"YouTube" channel:nil channelID:nil meta:nil thumb:nil duration:0 live:NO];
}

+ (SFItem *)itemForVideoID:(NSString *)vid title:(NSString *)title thumb:(NSString *)thumb {
    return [self videoItem:vid title:title.length ? title : @"YouTube" channel:nil channelID:nil meta:nil thumb:thumb.length ? thumb : nil duration:0 live:NO];
}

+ (void)fillDetails:(SFItem *)item done:(dispatch_block_t)done {
    if (item.localPath || !item.externalID) { if (done) done(); return; }
    [self call:@"player" body:@{@"videoId": item.externalID, @"contentCheckOk": @YES, @"racyCheckOk": @YES} cache:3600 done:^(id j, NSError *e) {
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
            item.backdrop = SFYouTubeBackdrop(item.externalID);
        }
        if (done) done();
    }];
}

#pragma mark - Setup

// Watch page ("next", docs/youtube.md §3.4): related videos + metadata the browse lists lack
// (description, channel ID and avatar). One cached call serves the info panel and autoplay.
+ (void)watchPageFor:(NSString *)vid done:(void (^)(NSArray *, NSDictionary *))done {
    if (vid.length != 11) { SFMain(^{ done(@[], nil); }); return; }
    [self call:@"next" body:@{@"videoId": vid} cache:1800 done:^(id j, NSError *e) {
        NSMutableArray *related = [NSMutableArray new];
        id sec = path(j, @"contents.twoColumnWatchNextResults.secondaryResults.secondaryResults.results");
        for (SFItem *i in (sec ? [self videosIn:sec cont:NULL channels:nil] : @[])) {
            if (i.kind != SFItemVideo || !i.identifier || [i.externalID isEqualToString:vid]) continue;
            if (i.duration > 0 && i.duration < 90) continue;                 // no Shorts
            [related addObject:i];
        }
        NSMutableDictionary *d = nil;
        if (dict(j)) {
            d = [NSMutableDictionary new];
            for (id c in arr(path(j, @"contents.twoColumnWatchNextResults.results.results.contents")) ?: @[]) {
                NSDictionary *pri = dict(dict(c)[@"videoPrimaryInfoRenderer"]);
                NSDictionary *secr = dict(dict(c)[@"videoSecondaryInfoRenderer"]);
                if (pri) {   // "02.11.2026", also "Premiere am 02.11.2026" / "Live übertragen am ..."
                    NSString *dt = text(pri[@"dateText"]);
                    NSRange r = dt ? [dt rangeOfString:@"[0-9]{1,2}\\.[0-9]{1,2}\\.[0-9]{4}" options:NSRegularExpressionSearch] : NSMakeRange(NSNotFound, 0);
                    if (r.location != NSNotFound) {
                        NSDateFormatter *f = [NSDateFormatter new];
                        f.dateFormat = @"d.M.yyyy"; f.locale = [NSLocale localeWithLocaleIdentifier:@"de_AT"];
                        NSDate *date = [f dateFromString:[dt substringWithRange:r]];
                        if (date) d[@"date"] = date;
                    }
                }
                if (secr) {
                    NSString *desc = str(path(secr, @"attributedDescription.content")) ?: text(secr[@"description"]);
                    if (desc.length) d[@"description"] = desc;
                    NSDictionary *own = dict(path(secr, @"owner.videoOwnerRenderer"));
                    NSString *name = text(own[@"title"]);
                    NSString *cid = str(path(own, @"navigationEndpoint.browseEndpoint.browseId"));
                    NSString *avatar = lastURL(path(own, @"thumbnail.thumbnails"));
                    if (name.length) d[@"channel"] = name;
                    if ([cid hasPrefix:@"UC"]) d[@"channelID"] = cid;
                    if (avatar.length) d[@"avatar"] = avatar;
                }
            }
        }
        SFMain(^{ done(related, d); });
    }];
}

+ (void)relatedFor:(NSString *)vid done:(void (^)(NSArray *))done {
    [self watchPageFor:vid done:^(NSArray *related, NSDictionary *details) { done(related); }];
}

+ (void)upNextFor:(NSString *)vid done:(void (^)(SFItem *))done {
    [self relatedFor:vid done:^(NSArray *items) {
        SFItem *pick = nil;
        for (SFItem *i in items) if (![[SFStore shared] watched:i.identifier]) { pick = i; break; }   // already watched
        done(pick);
    }];
}

+ (void)resolveChannelURL:(NSString *)url done:(void (^)(NSString *))done {
    [self call:@"navigation/resolve_url" body:@{@"url": url} cache:86400 done:^(id j, NSError *e) {
        id be = [j isKindOfClass:[NSDictionary class]] ? j[@"endpoint"][@"browseEndpoint"][@"browseId"] : nil;
        SFMain(^{ done([be isKindOfClass:[NSString class]] && [be hasPrefix:@"UC"] ? be : nil); });
    }];
}

#pragma mark Playback paths (static: the protocol methods below use them)


// YouTube concept (docs/youtube.md): the sofa-yt sidecar is the one way to YouTube (playback,
// lives, downloads, preloads, PO tokens); yt-dlp (SFYTResolver) is the fallback when the sidecar
// could not serve a video - never after a bot check (SFYTBreaker). Every decision is counted
// (SFCount, "yt.<what>.<path>[.<reason>]") so unused fallbacks can be retired on data.
//
// While the bot-check breaker is open, no path falls back to yt-dlp - not only when the sidecar's
// own answer was the bot check, but also when the sidecar is restarting, timed out or skipped
// (review 2026-11-05): a fallback player request from the flagged IP only prolongs the flag.
static NSString *const kBotMsg = @"YouTube lässt gerade keine Wiedergabe zu – bitte in ein paar Minuten noch einmal versuchen.";
static BOOL botPaused(SFURLDone done) {
    if (![SFYTBreaker shared].blockedUntil) return NO;
    SFLog(@"yt: bot-check pause - no yt-dlp fallback");
    SFCount(@"yt.ytdlp.skipped-bot-pause");
    done(nil, SFError(kBotMsg));
    return YES;
}
// yt-dlp: HLS (+ DASH for mpv) via the resolver process
static void ytdlp(NSString *vid, SFURLDone done) {
    if (botPaused(done)) return;
    [[SFYTResolver shared] resolve:vid live:NO done:^(NSDictionary *r, NSError *e) {
        NSURL *u = r ? [NSURL URLWithString:r[@"url"]] : nil;
        if (u) SFSetAlternateURLs(u, r[@"alt"]);
        if (u) {   // VP9/AV1 (DASH) for the mpv engine, plus audio/subtitle tracks
            NSMutableDictionary *d = [r[@"dash"] isKindOfClass:[NSDictionary class]] ? [r[@"dash"] mutableCopy] : [NSMutableDictionary new];
            if (r[@"height"]) d[@"hlsHeight"] = r[@"height"];
            if (r[@"fps"]) d[@"hlsFps"] = r[@"fps"];
            if ([r[@"subs"] isKindOfClass:[NSArray class]]) d[@"subs"] = r[@"subs"];
            SFSetMPVSource(u, d);
        }
        done(u, e);
    }];
}
// Result of the sofa-yt sidecar -> what the player opens. VOD: the DASH pair of local tracks;
// lives and post-live DVR recordings: the sidecar's local HLS playlist (muxed, opened as is).
// The sidecar's end screen elements (res/sofa-yt/lib/youtube.ts endscreenElements) as generic end
// cards (SFApp.h "endCards")
static NSArray *endCards(NSArray *elements) {
    NSMutableArray *out = [NSMutableArray new];
    for (NSDictionary *e in [elements isKindOfClass:[NSArray class]] ? elements : @[]) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *st = str(e[@"style"]), *vid = str(e[@"videoId"]), *pid = str(e[@"playlistId"]), *cid = str(e[@"browseId"]);
        NSMutableDictionary *c = [NSMutableDictionary new];
        if ([st isEqualToString:@"VIDEO"] && vid.length == 11) { c[@"kind"] = @"video"; c[@"ref"] = [@"yt:" stringByAppendingString:vid]; }
        else if ([st isEqualToString:@"PLAYLIST"] && pid) {
            c[@"kind"] = @"playlist"; c[@"ref"] = [@"ytplaylist:" stringByAppendingString:pid];
            if (vid.length == 11) c[@"firstRef"] = [@"yt:" stringByAppendingString:vid];
        } else if (([st isEqualToString:@"CHANNEL"] || [st isEqualToString:@"SUBSCRIBE"]) && [cid hasPrefix:@"UC"]) {
            c[@"kind"] = [st isEqualToString:@"SUBSCRIBE"] ? @"follow" : @"channel"; c[@"ref"] = [@"ytchannel:" stringByAppendingString:cid];
        } else continue;
        for (NSString *k in @[@"title", @"image", @"left", @"top", @"width", @"aspectRatio", @"startMs", @"endMs"]) if (e[k]) c[k] = e[k];
        [out addObject:c];
    }
    return out;
}

static void sabrPlay(NSString *vid, NSDictionary *r, SFURLDone done) {
    NSMutableDictionary *d = [r mutableCopy];
    d[@"endCards"] = endCards(r[@"endscreen"]);
    [d removeObjectForKey:@"endscreen"];
    d[@"sabr"] = @YES; d[@"vid"] = vid;
    NSURL *u;
    if ([r[@"hls"] isKindOfClass:[NSString class]]) {
        u = [NSURL URLWithString:r[@"hls"]];
        [d removeObjectsForKeys:@[@"video", @"audio", @"audios"]];   // no DASH pair: playURL opens `u` itself
        d[@"hls"] = @YES;   // flag (the URL is `u`): SFPlayerScreen asks the sidecar whether a live really ended
    } else {
        u = [NSURL URLWithString:r[@"video"]];
    }
    SFSetMPVSource(u, d);
    done(u, nil);
}
// A sidecar error that needs no fallback request: bot check (yt-dlp from the same IP would only
// prolong the flag, review 2026-11-05) and streams that are not on air (yt-dlp can't play them
// either). Returns the message for the user, nil = fall back to yt-dlp.
static NSString *sabrFinal(NSError *e) {
    if ([e.userInfo[@"bot"] boolValue])   // SFYTSabr took the pause into SFYTBreaker
        return kBotMsg;
    if ([e.userInfo[@"upcoming"] boolValue]) {
        double t = [e.userInfo[@"startTime"] doubleValue];
        if (!(t > 0)) return @"Dieser Livestream hat noch nicht begonnen.";
        NSDate *at = [NSDate dateWithTimeIntervalSince1970:t];
        NSDateFormatter *f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"de_AT"];
        NSCalendar *cal = [NSCalendar currentCalendar];
        BOOL today = [cal isDateInToday:at];
        f.dateFormat = today ? @"'heute um' HH:mm 'Uhr'" : [cal isDateInTomorrow:at] ? @"'morgen um' HH:mm 'Uhr'" : @"'am' d. MMMM 'um' HH:mm 'Uhr'";
        return [NSString stringWithFormat:@"Dieser Livestream beginnt %@.", [f stringFromDate:at]];
    }
    if ([e.userInfo[@"live"] boolValue] && [e.localizedDescription isEqualToString:@"offline"])
        return @"Dieser Livestream ist gerade nicht auf Sendung.";
    return nil;
}
// First choice: SABR via the sofa-yt sidecar (looks like the web player: one request per video,
// passes where yt-dlp gets bot checks). Needs mpv (local WebM/MP4 tracks). Any failure -> yt-dlp.
static void playOnline(NSString *vid, SFURLDone done) {
    SFYTSabr *sabr = [SFYTSabr shared];
    if (![sabr usableFor:vid]) {
        SFCount(!sabr.available ? @"yt.play.ytdlp.no-sidecar" : [sabr failedFor:vid] ? @"yt.play.ytdlp.marked-failed" : @"yt.play.ytdlp.no-mpv");
        ytdlp(vid, done); return;
    }
    [sabr open:vid background:NO done:^(NSDictionary *r, NSError *e) {
        if (!r) {
            NSString *msg = sabrFinal(e);
            if (msg) { SFCount([e.userInfo[@"bot"] boolValue] ? @"yt.play.bot-check" : @"yt.play.not-on-air"); done(nil, SFError(msg)); return; }
            if ([e.userInfo[@"live"] boolValue]) [sabr markFailed:vid];   // live the sidecar can't play: yt-dlp directly next time
            SFLog(@"yt: SABR unavailable for %@ (%@) -> yt-dlp", vid, e.localizedDescription);
            SFCount(@"yt.play.ytdlp.sidecar-error");
            ytdlp(vid, done); return;
        }
        SFCount(r[@"hls"] ? @"yt.play.sabr-hls" : @"yt.play.sabr");
        sabrPlay(vid, r, done);   // a video that turned out to be live comes back as HLS
    }];
}

// Lives: the sidecar first (the web player's HLS manifest from its own session - yt-dlp's live
// requests got the bot check on this IP), yt-dlp as fallback. The local playlist is plain HLS:
// mpv and AVFoundation both play it, so no mpv requirement here.
static void ytdlpLive(NSString *vid, SFURLDone done) {
    if (botPaused(done)) return;
    [[SFYTResolver shared] resolve:vid live:YES done:^(NSDictionary *r, NSError *e) {
        done(r ? [NSURL URLWithString:r[@"url"]] : nil, e);
    }];
}


#pragma mark SFApp

+ (NSString *)appIdentifier { return @"youtube"; }
+ (NSString *)appName { return @"YouTube"; }
+ (NSString *)appSummary { return @"Deine Kanäle, neue Videos, Suche"; }
+ (NSArray *)refPrefixes { return @[@"yt", @"ytlive", @"ytchannel", @"ytplaylist", @"ytfollow", @"ytautodl"]; }
+ (NSArray *)showRefPrefixes { return @[@"ytchannel"]; }
+ (NSColor *)homeTileColor { return SFHex(0xffffff); }
+ (NSInteger)homeTileLogoVariant { return 0; }
+ (NSString *)searchPlaceholder { return @"Videos und Kanäle suchen"; }
+ (BOOL)homeIncludesFollows { return YES; }
+ (BOOL)showsAreChannels { return YES; }   // channels, new videos and downloads are part of homeLoader
+ (void)configureTheme:(SFTheme *)t {
    // Dark, red accents, rounded 16:9 tiles.
    t.wordmark = @"YouTube"; t.logo = @"youtube"; t.logoVariant = 1;
    t.background = SFHex(0x0f0f0f);
    t.backgroundTop = SFHex(0x181818);
    t.surface = SFHex(0x272727);
    t.text = SFHex(0xf1f1f1);
    t.textDim = SFHex(0xaaaaaa);
    t.accent = SFHex(0xff0033);
    t.accentText = SFHex(0xffffff);
    t.focus = SFHex(0xffffff);
    t.corner = 14;
    t.wordmarkColor = t.text; t.progressColor = t.accent;
    t.focusText = SFHex(0x111111);   // white focus
    t.headerMark = SFHeaderMarkPlayPill;
}

+ (void)start {
    [[SFYTResolver shared] start];   // housekeeping + update schedule; the process starts on demand
    if (!SFDevMode) [[SFYTSabr shared] start];   // warm session + BotGuard before the first click
}

// yt:<id> plays a local download when there is one; ytlive:<id> = live/DVR via the sidecar
+ (void)resolve:(NSString *)ref done:(SFURLDone)done {
    NSString *p = SFRefPrefix(ref), *vid = SFRefID(ref);
    if ([p isEqualToString:@"ytlive"]) { [self resolveLive:vid done:done]; return; }
    if (![p isEqualToString:@"yt"]) { done(nil, SFError(@"Quelle nicht verfügbar")); return; }
    SFItem *local = downloadedVideo(vid);
    if (local.localPath && [[NSFileManager defaultManager] fileExistsAtPath:local.localPath]) { done([NSURL fileURLWithPath:local.localPath], nil); return; }
    playOnline(vid, done);
}

// "Online abspielen": skip downloads
+ (void)resolveOnline:(NSString *)ref done:(SFURLDone)done {
    if ([SFRefPrefix(ref) isEqualToString:@"yt"]) playOnline(SFRefID(ref), done);
    else [self resolve:ref done:done];
}

+ (void)resolveLive:(NSString *)vid done:(SFURLDone)done {
    SFYTSabr *sabr = [SFYTSabr shared];
    if (!sabr.available || [sabr failedFor:vid]) {
        SFCount(!sabr.available ? @"yt.live.ytdlp.no-sidecar" : @"yt.live.ytdlp.marked-failed");
        ytdlpLive(vid, done); return;
    }
    [sabr open:vid background:NO done:^(NSDictionary *r, NSError *e) {
        if (!r) {
            NSString *msg = sabrFinal(e);
            if (msg) { SFCount([e.userInfo[@"bot"] boolValue] ? @"yt.live.bot-check" : @"yt.live.not-on-air"); done(nil, SFError(msg)); return; }
            SFLog(@"yt: SABR live unavailable for %@ (%@) -> yt-dlp", vid, e.localizedDescription);
            SFCount(@"yt.live.ytdlp.sidecar-error");
            ytdlpLive(vid, done); return;
        }
        // a former live that is a processed video by now comes back as a DASH pair: needs mpv
        if (!r[@"hls"] && (!SFMPVAvailable() || SFPreferAVFoundation())) { SFCount(@"yt.live.ytdlp.no-mpv"); ytdlpLive(vid, done); return; }
        SFCount(@"yt.live.sabr");
        sabrPlay(vid, r, done);
    }];
}

#pragma mark Player hooks (SABR sessions of the sofa-yt sidecar)

+ (BOOL)playbackIsSession:(NSDictionary *)source { return [source[@"sabr"] boolValue]; }

// SABR (sofa-yt sidecar) failed: first reopen via SABR (a crashed sidecar restarts and has the
// player response cached on disk - no new YouTube request), then yt-dlp takes over (the
// resolver skips SABR for this video from now on)
+ (void)playbackSessionFailed:(NSDictionary *)source item:(SFItem *)item retried:(BOOL)retried reason:(NSString *)why {
    SFLog(@"player: SABR stream failed (%@) -> %@", why, retried ? @"yt-dlp" : @"reopening via SABR");
    SFCount(retried ? @"player.sabr-to-ytdlp" : @"player.sabr-reopen");
    if (retried) [[SFYTSabr shared] markFailed:source[@"vid"]];
    else [[SFYTSabr shared] closeSession:source[@"sid"]];   // the retry gets a fresh session, not the broken one
}

// the SABR sidecar died: its local URLs are gone - the player reopens right away instead of waiting
// for mpv's reconnects and the stall watchdog
+ (NSString *)playbackSessionLostNotification { return SFYTSabrDidExitNotification; }

// live via the sidecar: the end of the playlist is either the end of the broadcast (upstream
// EXT-X-ENDLIST, reported in the session status) or a lost playlist - only the sidecar knows
+ (BOOL)playbackLiveEnded:(NSDictionary *)source done:(void (^)(BOOL))done {
    if (!([source[@"sabr"] boolValue] && [source[@"hls"] boolValue] && [source[@"live"] boolValue])) return NO;
    [[SFYTSabr shared] sessionStatus:source[@"sid"] done:^(NSDictionary *st) { done([st[@"ended"] boolValue]); }];
    return YES;
}

// YouTube URLs are sporadically rejected entirely (403/-1102): resolve afresh once
+ (BOOL)playbackPrepareReResolve:(SFItem *)item {
    NSString *ref = item.resolverRef ?: item.identifier;
    if (![SFRefPrefix(ref) isEqualToString:@"yt"]) return NO;
    [[SFYTResolver shared] forget:SFRefID(ref)];
    return YES;
}

// description, channel and recommendations in ONE cached request (the same "next" call autoplay
// uses) - only for an online-capable video
+ (void)watchDetailsForItem:(SFItem *)item done:(void (^)(NSArray *, NSDictionary *))done {
    if (item.externalID.length != 11 || ![SFNet isOnline]) return;
    [self watchPageFor:item.externalID done:^(NSArray *related, NSDictionary *details) {
        NSMutableDictionary *d = [details mutableCopy];
        NSString *cid = details[@"channelID"];
        if ([cid hasPrefix:@"UC"]) d[@"showRef"] = [@"ytchannel:" stringByAppendingString:cid];
        done(related, d);
    }];
}

+ (SFItem *)itemForRef:(NSString *)ref title:(NSString *)title image:(NSString *)image {
    NSString *vid = SFRefID(ref);
    if (![SFRefPrefix(ref) isEqualToString:@"yt"] || vid.length != 11) return nil;
    return [self itemForVideoID:vid title:title thumb:image];
}

+ (SFPageLoader)listLoader:(NSString *)ref title:(NSString *)title {
    return [SFRefPrefix(ref) isEqualToString:@"ytplaylist"] ? [self playlistLoader:SFRefID(ref) title:title] : nil;
}

+ (void)upNextForItem:(SFItem *)item done:(void (^)(SFItem *))done {
    if (item.externalID.length != 11) { done(nil); return; }
    [self upNextFor:item.externalID done:done];
}

// channel page (ytchannel:UC…)
+ (SFPageLoader)showPageLoader:(NSString *)ref title:(NSString *)title {
    return [SFRefPrefix(ref) isEqualToString:@"ytchannel"] ? [self channelLoader:SFRefID(ref) title:title] : nil;
}

// channel of a video without a stored channel ID (older watch-later/continue watching/downloads): player -> videoDetails.channelId
+ (void)showRefForItem:(SFItem *)item done:(void (^)(NSString *))done {
    NSString *vid = item.externalID ?: ([item.identifier hasPrefix:@"yt:"] ? restOfID(item.identifier) : nil);
    if (vid.length != 11) { done(nil); return; }
    [self call:@"player" body:@{@"videoId": vid} cache:86400 done:^(id j, NSError *e) {
        NSString *cid = str(path(j, @"videoDetails.channelId"));
        SFMain(^{ done([cid hasPrefix:@"UC"] ? [@"ytchannel:" stringByAppendingString:cid] : nil); });
    }];
}

// Exact publication times of a channel's latest long videos: YouTube's RSS feed of the UULF
// playlist (no Shorts) - 15 entries with <published> to the second, one light request outside
// InnerTube. InnerTube lists only say "vor 11 Tagen" (relativeDate: approximate, fallback only).
// Synchronous (call off main); nil when unavailable.
// RSS of the channel's long videos: exact publication time per video id, and (out) its view count
// (media:statistics - the raw number YouTube shows, used for "Highlights": videos far above the channel's usual)
static NSDictionary *rssPublished(NSString *cid, NSDictionary **viewsOut) {
    NSInteger st = 0;
    NSString *u = [@"https://www.youtube.com/feeds/videos.xml?playlist_id=UULF" stringByAppendingString:[cid substringFromIndex:2]];
    NSData *d = SFCurlFetch(u, @"GET", nil, nil, &st, NULL);
    NSString *xml = st == 200 && d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
    if (!xml) return nil;
    static NSRegularExpression *re, *vre;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"<entry>.*?<yt:videoId>([^<]+)</yt:videoId>.*?<published>([^<]+)</published>.*?</entry>"
                                                       options:NSRegularExpressionDotMatchesLineSeparators error:nil];
        vre = [NSRegularExpression regularExpressionWithPattern:@"<media:statistics views=\"([0-9]+)\"" options:0 error:nil];
    });
    NSMutableDictionary *r = [NSMutableDictionary new], *views = [NSMutableDictionary new];
    for (NSTextCheckingResult *m in [re matchesInString:xml options:0 range:NSMakeRange(0, xml.length)]) {
        NSString *vid = [xml substringWithRange:[m rangeAtIndex:1]];
        NSDate *when = SFDateFromISO8601([xml substringWithRange:[m rangeAtIndex:2]]);
        if (when) r[vid] = when;
        NSTextCheckingResult *v = [vre firstMatchInString:xml options:0 range:m.range];
        if (v) views[vid] = @([[xml substringWithRange:[v rangeAtIndex:1]] longLongValue]);
    }
    if (viewsOut) *viewsOut = views;
    return r.count ? r : nil;
}

// Subscription feed: a channel's long videos, newest first (always as online items). Background
// work (SFFollows, every 30 min for every followed channel) - so it has to be cheap and polite:
// - the RSS feed (one small request) is the change detector, the date and the views source;
// - while its video list is unchanged, the channel's last parsed list (stored, a few KB) is the
//   answer - no InnerTube request at all;
// - during a bot-check pause (SFYTBreaker) nothing is requested: every request while flagged
//   prolongs the flag (2026-11-05: feeds kept browsing through a pause).
+ (void)feed:(NSString *)ref done:(void (^)(NSArray *, NSError *))done {
    NSString *cid = SFRefID(ref);
    if (![cid hasPrefix:@"UC"]) { done(nil, SFError(@"Unbekannter Kanal")); return; }
    if ([SFYTBreaker shared].blockedUntil) {   // follows keep what they have
        NSArray *last = [self storedFeed:cid];
        done(last.count ? last : nil, last.count ? nil : SFError(@"YouTube pausiert gerade (Bot-Prüfung)."));
        return;
    }
    SFBackground(^{
        NSDictionary *views = nil, *published = rssPublished(cid, &views);
        [self feed:cid published:published done:^(NSArray *items, NSError *e) {
            for (SFItem *i in items) { NSNumber *v = views[restOfID(i.identifier)]; if (v) i.viewCount = v.longLongValue; }
            done(items, e);
        }];
    });
}

static NSString *feedKey(NSString *cid) { return [@"yt.feed." stringByAppendingString:cid]; }

+ (NSArray *)storedFeed:(NSString *)cid {
    NSMutableArray *a = [NSMutableArray new];
    id list = [[SFStore shared] cachedJSON:feedKey(cid) maxAge:30 * 86400];
    for (NSDictionary *d in ([list isKindOfClass:[NSArray class]] ? list : @[]))
        if ([d isKindOfClass:[NSDictionary class]]) { SFItem *i = [SFItem itemWithDictionary:d]; if (i.identifier) [a addObject:i]; }
    return a;
}

+ (void)feed:(NSString *)cid published:(NSDictionary *)published done:(void (^)(NSArray *, NSError *))done {
    NSString *sigKey = [@"yt.feedsig." stringByAppendingString:cid];
    NSString *sig = published ? [[published.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","] : nil;
    void (^finish)(NSArray *, NSError *) = ^(NSArray *items, NSError *err) {
        NSDate *oldest = nil;
        for (SFItem *i in items) {
            NSDate *exact = published[restOfID(i.identifier)];
            if (exact) { i.date = exact; oldest = oldest ? [oldest earlierDate:exact] : exact; }
        }
        // beyond the 15 RSS entries only the approximation exists (relative to a possibly week-old
        // answer): never newer than the oldest exact entry, so the order stays right
        for (SFItem *i in items)
            if (oldest && !published[restOfID(i.identifier)] && (!i.date || [i.date compare:oldest] != NSOrderedAscending))
                i.date = [oldest dateByAddingTimeInterval:-60];
        done(items, err);
    };
    // Stored signature: "<sig>" = the stored list holds every RSS video; "<sig>@<epoch>" = it did not
    // (InnerTube lagging behind RSS, a premiere not aired yet) - then reused for 2 h only, so the
    // new upload shows up soon without asking InnerTube on every refresh.
    NSString *stored = [[SFStore shared] setting:sigKey];
    NSArray *parts = [stored componentsSeparatedByString:@"@"];
    BOOL unchanged = sig && [parts.firstObject isEqualToString:sig] &&
                     (parts.count == 1 || [NSDate date].timeIntervalSince1970 - [parts.lastObject doubleValue] < 2 * 3600);
    if (unchanged) {
        NSArray *last = [self storedFeed:cid];
        if (last.count) { finish(last, nil); return; }
    }
    [self feedItems:cid done:^(NSArray *online, NSError *e) {
        if (!online) {   // failed: the last known list
            NSArray *last = [self storedFeed:cid];
            finish(last.count ? last : nil, last.count ? nil : e);
            return;
        }
        NSMutableArray *dicts = [NSMutableArray new];
        for (SFItem *i in online) [dicts addObject:[i dictionaryRepresentation]];
        [[SFStore shared] cacheJSON:dicts forKey:feedKey(cid)];
        if (sig) {
            NSMutableSet *ids = [NSMutableSet new];
            for (SFItem *i in online) [ids addObject:restOfID(i.identifier)];
            BOOL complete = [[NSSet setWithArray:published.allKeys] isSubsetOfSet:ids];
            [[SFStore shared] setSetting:complete ? sig : [NSString stringWithFormat:@"%@@%.0f", sig, [NSDate date].timeIntervalSince1970] forKey:sigKey];
        }
        finish(online, nil);
    }];
}

// the channel's long videos as online items (InnerTube browse of the UULF playlist). Not kept in
// the response cache: the answer is ~1 MB, the parsed list (storedFeed) is what is reused.
+ (void)feedItems:(NSString *)cid done:(void (^)(NSArray *, NSError *))done {
    [self call:@"browse" body:@{@"browseId": [@"VLUULF" stringByAppendingString:[cid substringFromIndex:2]]} cache:0 done:^(id j, NSError *e) {
        NSMutableArray *online = [NSMutableArray new];
        for (SFItem *i in (j ? [self videosIn:j cont:NULL channels:nil] : @[])) {
            if (i.kind != SFItemVideo) continue;
            if (i.localPath) {   // local copy substituted: restore the online identity
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
}

// still online? oEmbed answers without a player request (bot-flagged IP): 200 = public or
// unlisted -> online; 400/404 = gone (deleted, bad id). 401/403 is ambiguous (embedding off, but
// also private videos) -> unknown: never deletable in bulk, the copy may be the only one
// (review 2026-11-05). Used by "Platz schaffen" (SFDownloads+Storage.m).
+ (void)availabilityOfItem:(SFItem *)item done:(SFAvailabilityDone)done {
    NSString *vid = item.externalID ?: restOfID(item.identifier);
    if (vid.length != 11) { done(-1); return; }
    SFBackground(^{
        NSInteger st = 0;
        NSString *u = [NSString stringWithFormat:@"https://www.youtube.com/oembed?format=json&url=https%%3A%%2F%%2Fwww.youtube.com%%2Fwatch%%3Fv%%3D%@", vid];
        NSData *d = SFCurlFetch(u, @"GET", nil, nil, &st, NULL);
        done(st == 200 ? 1 : (st == 400 || st == 404) ? 0 : -1);
        (void)d;
    });
}

// YouTube downloads wait during a bot-check pause (no request, no attempt used up)
+ (NSTimeInterval)downloadsPausedUntil { return [SFYTBreaker shared].blockedUntil; }

// exact publication time from the sidecar (microformat) or yt-dlp (timestamp), epoch seconds
static NSDictionary *publishedInfo(NSDictionary *r) {
    NSNumber *p = [r[@"published"] isKindOfClass:[NSNumber class]] ? r[@"published"] : nil;
    return p.doubleValue > 0 ? @{@"published": [NSDate dateWithTimeIntervalSince1970:p.doubleValue]} : nil;
}

+ (void)downloadSourceForItem:(SFItem *)item done:(SFDownloadURLDone)done {
    NSString *vid = item.externalID ?: restOfID(item.identifier);
    void (^viaYTDLP)(void) = ^{
    [[SFYTResolver shared] prefetch:vid done:^(NSDictionary *r, NSError *e) {
        // the playback format, as with SABR: DASH video + the original audio track (mweb, the
        // first client, has no HLS any more); otherwise the muxed/HLS stream as before
        NSDictionary *d = [r[@"dash"] isKindOfClass:[NSDictionary class]] ? r[@"dash"] : nil;
        if ([d[@"video"] isKindOfClass:[NSString class]] && [d[@"audio"] isKindOfClass:[NSString class]]) {
            done([NSURL URLWithString:d[@"video"]], [NSURL URLWithString:d[@"audio"]], publishedInfo(r), nil); return;
        }
        NSString *u = r[@"url"];
        for (NSString *a in r[@"alt"]) if ([a rangeOfString:@"/itag/95/"].location != NSNotFound) { u = a; break; }
        // several audio tracks: original audio separately (the muxed stream has YouTube's default track)
        NSString *au = r[@"dlaudio"];
        done(u ? [NSURL URLWithString:u] : nil, au ? [NSURL URLWithString:au] : nil, publishedInfo(r), e);
    }];
    };
    // first choice SABR: the playback format (up to 1080p60 VP9/AV1 + Opus, original audio track)
    // as two local streams, muxed by ffmpeg into MP4 without re-encoding (ffmpeg's -readrate 3
    // also paces what SABR pulls). yt-dlp stays the fallback (2026-11-05: yt-dlp's stream address
    // of _4O-me6dWfc answered 404 for hours; the SABR repair worked at once).
    SFYTSabr *sabr = [SFYTSabr shared];
    if (!sabr.available) { SFCount(@"yt.download.ytdlp.no-sidecar"); viaYTDLP(); return; }
    [sabr openForDownload:vid done:^(NSDictionary *r, NSError *e) {
        if (!r) {
            // a bot check pauses both paths alike (SFYTSabr noted it in SFYTBreaker): no yt-dlp
            // request; the download is deferred without using up an attempt
            if ([e.userInfo[@"bot"] boolValue]) { SFCount(@"yt.download.bot-check"); done(nil, nil, nil, e); return; }
            SFLog(@"yt: SABR download of %@ unavailable (%@) -> yt-dlp", vid, e.localizedDescription);
            SFCount(@"yt.download.ytdlp.sidecar-error");
            viaYTDLP(); return;
        }
        SFCount(@"yt.download.sabr");
        // the verifier needs the real length to catch a truncated file (cut-off local stream)
        if ([r[@"duration"] doubleValue] > 0) item.duration = [r[@"duration"] doubleValue];
        done([NSURL URLWithString:r[@"video"]], [NSURL URLWithString:r[@"audio"]], publishedInfo(r), nil);
    }];
}

#pragma mark - Phone remote ("Mit TV verbinden")

// YouTube → Mehr: phone status + settings
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
        SFNavigator *nav = [SFNavigator main];
        if (!nav) return;
        SFLounge *ll = [SFLounge shared];
        if (ll.paused || ll.remoteNames.count) [SFPairScreen showConnectionMenuOn:nav];
        else [nav push:[[SFPairScreen alloc] initWithTheme:[SFTheme themeNamed:@"youtube"]]];
    };
    return i;
}


#pragma mark - Dev commands (sofa-dev FIFO)

+ (BOOL)handleDevCommand:(NSString *)cmd arg:(NSString *)arg host:(id<SFPlayerHost>)host {
    SFNavigator *nav = [host nav];
    if ([cmd isEqualToString:@"open"] && [arg isEqualToString:@"pair"]) {   // pairing code screen
        [nav push:[[SFPairScreen alloc] initWithTheme:[SFTheme themeNamed:@"youtube"]]];
    } else if ([cmd isEqualToString:@"open"] && [arg hasPrefix:@"ytchannel:"]) {   // any channel page: ytchannel:<ID>[|<title>]
        SFItem *f = [SFItem new]; f.kind = SFItemFolder; f.themeName = @"youtube"; f.source = @"youtube";
        NSArray *pt = [[arg substringFromIndex:10] componentsSeparatedByString:@"|"];
        f.pageLoader = [self channelLoader:pt[0] title:pt.count > 1 ? pt[1] : @"Kanal"];
        SFOpenItem(nav, f, nil, 0);
    } else if ([cmd isEqualToString:@"open"] && [arg hasPrefix:@"yt:"]) {   // play a video from the start (startup tests)
        SFItem *it = [self itemForVideoID:[arg substringFromIndex:3]];
        [self fillDetails:it done:^{
            SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:it queue:nil index:0];
            ps.startFromBeginning = YES;
            [host presentPlayer:ps];
        }];
    } else if ([cmd isEqualToString:@"play"] && [arg hasPrefix:@"ytlive:"]) {   // like a "Jetzt live" tile (no resume, live end handling)
        SFItem *it = [SFItem new];
        it.kind = SFItemLive; it.identifier = arg; it.title = arg; it.resolverRef = arg;
        SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:it queue:nil index:0];
        ps.startFromBeginning = YES;
        [host presentPlayer:ps];
    } else if ([cmd isEqualToString:@"lounge"] && arg) {   // simulate a phone command: lounge <cmd> <json>
        NSRange sp = [arg rangeOfString:@" "];
        NSString *lc = sp.location == NSNotFound ? arg : [arg substringToIndex:sp.location];
        id j = sp.location == NSNotFound ? @{} : [NSJSONSerialization JSONObjectWithData:[[arg substringFromIndex:sp.location + 1] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        SFYTRemoteCommand(host, lc, [j isKindOfClass:[NSDictionary class]] ? j : @{});
    } else if ([cmd isEqualToString:@"ytfeed"] && [arg hasPrefix:@"UC"]) {   // feed of a channel with its dates (RSS exact vs relative)
        SFBackground(^{
            NSDictionary *pub = rssPublished(arg, NULL);
            SFLog(@"dev: ytfeed %@: rss %lu dates", arg, (unsigned long)pub.count);
            [self feed:arg published:pub done:^(NSArray *items, NSError *e) {
                for (SFItem *i in items)
                    SFLog(@"dev: ytfeed %@ %@ %@ %@", restOfID(i.identifier), i.date, pub[restOfID(i.identifier)] ? @"rss" : @"relative", i.title);
                SFLog(@"dev: ytfeed end (%lu items%@)", (unsigned long)items.count, e ? [@", " stringByAppendingString:e.localizedDescription] : @"");
            }];
        });
    } else if ([cmd isEqualToString:@"ytblock"] && arg) {   // simulate a bot-check pause for <secs> (this instance only)
        [[SFYTBreaker shared] simulateBlockForTesting:arg.doubleValue];
    } else return NO;
    return YES;
}

#pragma mark - Remote control service (SFApp)

+ (void)startRemoteWithHost:(id<SFPlayerHost>)host {
    __weak id<SFPlayerHost> wh = host;
    [SFLounge shared].commandHandler = ^(NSString *cmd, NSDictionary *args) { SFYTRemoteCommand(wh, cmd, args); };
    [SFLounge shared].playerProvider = ^id { return [wh topPlayer]; };
    [[SFLounge shared] start];
}
// Home: followed channels as round avatars, after Sofa's own sections
// Home "Highlights": the standout new videos of the followed channels - no request: the feeds are
// loaded anyway and their RSS carries each video's views. Standout = far above the channel's usual
// (views / median of its recent videos), so a small channel's hit counts like a big one's;
// at most one per channel, from the last 7 days.
+ (void)homeFeatures:(void (^)(NSDictionary *))done {
    NSMutableDictionary *byChannel = [NSMutableDictionary new];
    for (SFItem *i in [[SFFollows shared] latest:2000 source:[self appIdentifier]]) {
        NSString *k = i.showRef ?: i.channel;
        if (k) byChannel[k] = [(byChannel[k] ?: @[]) arrayByAddingObject:i];
    }
    NSMutableArray *picks = [NSMutableArray new];   // @[score, item]
    NSDate *week = [NSDate dateWithTimeIntervalSinceNow:-7 * 86400];
    for (NSArray *items in byChannel.allValues) {
        NSMutableArray *views = [NSMutableArray new];
        for (SFItem *i in items) if (i.viewCount > 0) [views addObject:@(i.viewCount)];
        if (views.count < 5) continue;   // too little history to say what is usual
        [views sortUsingSelector:@selector(compare:)];
        double median = [views[views.count / 2] doubleValue];
        SFItem *best = nil; double bestScore = 0;
        for (SFItem *i in items) {
            if (i.viewCount <= 0 || !i.date || [i.date compare:week] == NSOrderedAscending) continue;
            // plain ratio: a young video has had less time, so one that already beats the median is a clear signal
            double score = i.viewCount / median;
            if (score > bestScore) { bestScore = score; best = i; }
        }
        if (best && bestScore >= 1.5) [picks addObject:@[@(bestScore), best]];
    }
    [picks sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    NSMutableArray *top = [NSMutableArray new];
    for (NSArray *p in picks) if (top.count < 8) [top addObject:p[1]];
    SFLog(@"home features: youtube %lu standout of %lu channels", (unsigned long)top.count, (unsigned long)byChannel.count);
    done(@{SFHomeTopicHighlights: top});
}

+ (NSArray *)homeSections {
    return @[[SFHomeSection section:@"youtube.channels" title:@"Meine Kanäle" priority:SFHomePriorityApp style:SFTileStyleCircle items:^NSArray *{
        NSArray *f = [[SFFollows shared] follows:[self appIdentifier]];
        for (SFItem *i in f) i.style = SFTileStyleCircle;
        return f;
    }]];
}
+ (void)updateStoredItem:(SFItem *)i {
    NSString *vid = [SFRefPrefix(i.identifier) isEqualToString:@"yt"] ? SFRefID(i.identifier) : nil;
    if (!vid.length) return;
    if (!i.image) i.image = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", vid];
    // stored entries carry the small tile picture as backdrop -> TV resolution; a local picture (download) stays
    if (!i.backdrop || [i.backdrop hasPrefix:@"https://i.ytimg.com/vi/"]) i.backdrop = SFYouTubeBackdrop(vid);
}
+ (void)preloadOnFocus:(SFItem *)item {
    NSString *ref = item.resolverRef ?: item.identifier;
    if ([ref hasPrefix:@"yt:"]) [[SFYTSabr shared] preloadOnFocus:[ref substringFromIndex:3]];
}
+ (void)prepareForRelaunch { [[SFYTResolver shared] saveCache]; }
+ (void)stopRemote { [[SFLounge shared] stop]; }
+ (NSString *)remoteStatus:(BOOL *)paused {
    SFLounge *l = [SFLounge shared];
    if (paused) *paused = l.paused;
    NSArray *n = l.remoteNames;
    return l.paused ? @"Handy pausiert" : n.count ? [@"Handy: " stringByAppendingString:[n componentsJoinedByString:@", "]] : nil;
}
+ (NSString *)remoteStatusNotification { return SFLoungeRemotesDidChangeNotification; }

@end
