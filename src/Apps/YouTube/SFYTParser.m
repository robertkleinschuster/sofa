#import "SFYTParser.h"
#import "SFYTInnerTube.h"

NSString *SFYTBackdrop(NSString *videoID) {
    return videoID.length ? [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/maxresdefault.jpg", videoID] : nil;
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
// nothing better; feeds take exact times from RSS (SFYTFeeds), the info panel from the watch page.
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

// A list entry's views as YouTube writes them for hl=de (the only language Sofa asks in):
// "313.544 Aufrufe", "1 Aufruf", "1,4 Mio. Aufrufe" (lists), "1 Million Aufrufe" / "1,6 Millionen
// Aufrufe" (watch-page suggestions), the same with "Mrd." / "Milliarde(n)", "Keine Aufrufe" -> 0.
// Exact below a million, two significant digits above - lists carry no number field
// (lockupViewModel/videoRenderer checked 2026-11-06); enough to compare a video with its
// channel's usual views (Home highlights). -1 = not a view count (date, live "Zuschauer", ...).
long long SFYTViewCount(NSString *s) {
    NSString *t = [[s stringByReplacingOccurrencesOfString:@"\u00a0" withString:@" "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (![t hasSuffix:@" Aufrufe"] && ![t hasSuffix:@" Aufruf"]) return -1;
    NSArray *w = [t componentsSeparatedByString:@" "];
    if ([w.firstObject isEqualToString:@"Keine"]) return 0;
    NSDictionary *units = @{@"Mio.": @1e6, @"Million": @1e6, @"Millionen": @1e6, @"Mrd.": @1e9, @"Milliarde": @1e9, @"Milliarden": @1e9};
    double scale = w.count == 2 ? 1 : w.count == 3 ? [units[w[1]] doubleValue] : 0;
    NSString *num = [[w.firstObject stringByReplacingOccurrencesOfString:@"." withString:@""] stringByReplacingOccurrencesOfString:@"," withString:@"."];
    if (!scale || !num.length || [num rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet]].location != NSNotFound) return -1;
    if (scale == 1 && [num rangeOfString:@"."].location != NSNotFound) return -1;   // a decimal without unit: not YouTube's format
    return llround(num.doubleValue * scale);
}

// A channel avatar in TV size: its size is freely selectable (=s88-... -> =s400-...).
static NSString *tvAvatar(NSString *avatar) {
    NSRange r = [avatar rangeOfString:@"=s" options:NSBackwardsSearch];
    if (r.location == NSNotFound) return avatar;
    NSRange dash = [avatar rangeOfString:@"-" options:0 range:NSMakeRange(NSMaxRange(r), avatar.length - NSMaxRange(r))];
    return dash.location == NSNotFound ? avatar : [avatar stringByReplacingCharactersInRange:NSMakeRange(NSMaxRange(r), dash.location - NSMaxRange(r)) withString:@"400"];
}

@implementation SFYTParser

#pragma mark Items

+ (SFItem *)videoItem:(NSString *)vid title:(NSString *)title channel:(NSString *)channel channelID:(NSString *)cid
                 meta:(NSString *)meta thumb:(NSString *)thumb duration:(NSTimeInterval)dur live:(BOOL)live {
    if (vid.length != 11) return nil;
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
    i.backdrop = SFYTBackdrop(vid);
    i.duration = dur;
    i.source = @"youtube"; i.themeName = @"youtube";
    i.style = SFTileStyleLandscape;
    if (live) i.badge = @"LIVE";
    return i;
}

+ (SFItem *)channelItem:(NSString *)cid title:(NSString *)title avatar:(NSString *)avatar meta:(NSString *)meta {
    if (!cid.length || !title.length) return nil;
    SFItem *f = [SFItem new];
    f.kind = SFItemFolder;
    f.identifier = [@"ytchannel:" stringByAppendingString:cid];
    f.title = title; f.subtitle = meta;
    f.image = tvAvatar(avatar);
    f.style = SFTileStyleCircle;
    f.source = @"youtube"; f.themeName = @"youtube";
    return f;
}

+ (SFItem *)fromLockup:(NSDictionary *)l {
    NSString *type = str(l[@"contentType"]), *cid = str(l[@"contentId"]);
    NSDictionary *md = dict(SFYTPath(l, @"metadata.lockupMetadataViewModel"));
    NSString *title = SFYTText(md[@"title"]);
    // Metadata rows: [channel] and [views, age]. A part's text can lean on an icon (the views'
    // play arrow: "77.272") or abbreviate ("vor 2 Std."); its accessibilityLabel says it in full
    // ("77.272 Aufrufe", "vor 2 Stunden") - shown where an icon stands in, parsed for the age.
    // The channel part links to the channel (commandRuns -> browseEndpoint); where it is plain
    // text (related videos), the channel is the byline row above the stats row.
    NSArray *rows = arr(SFYTPath(md, @"metadata.contentMetadataViewModel.metadataRows"));
    NSMutableArray *rowTexts = [NSMutableArray new], *labels = [NSMutableArray new];
    NSString *linkedChannel = nil, *linkedID = nil;
    for (NSDictionary *row in rows) {
        NSMutableArray *parts = [NSMutableArray new];
        for (NSDictionary *p in arr(dict(row)[@"metadataParts"])) {
            NSString *t = SFYTText(dict(p)[@"text"]), *label = str(dict(p)[@"accessibilityLabel"]);
            NSString *cid = str(SFYTPath(dict(p)[@"text"], @"commandRuns.0.onTap.innertubeCommand.browseEndpoint.browseId"));
            if ([cid hasPrefix:@"UC"] && t.length) { linkedChannel = t; linkedID = cid; }
            if (label.length) [labels addObject:label];
            NSString *shown = dict(p)[@"leadingIcon"] && label.length ? label : t;
            if (shown.length) [parts addObject:shown];
        }
        if (parts.count) [rowTexts addObject:parts];
    }
    if ([type isEqualToString:@"LOCKUP_CONTENT_TYPE_VIDEO"]) {
        // a Short opens the Shorts player (reelWatchEndpoint): not a video for Sofa's lists
        if (SFYTPath(l, @"rendererContext.commandContext.onTap.innertubeCommand.reelWatchEndpoint")) return nil;
        NSString *channel = linkedChannel ?: (rowTexts.count >= 2 ? [rowTexts[0] firstObject] : nil);
        if (linkedChannel && rowTexts.count >= 2) [rowTexts removeObjectAtIndex:0];
        NSString *meta = [rowTexts.lastObject componentsJoinedByString:@" · "];
        NSString *chID = linkedID ?: str(SFYTPath(md, @"image.decoratedAvatarViewModel.rendererContext.commandContext.onTap.innertubeCommand.browseEndpoint.browseId"));
        NSDictionary *tv = dict(SFYTPath(l, @"contentImage.thumbnailViewModel"));
        NSString *thumb = SFYTLastURL(SFYTPath(tv, @"image.sources"));
        NSTimeInterval dur = 0; BOOL live = NO, upcoming = NO;
        for (NSDictionary *ov in arr(tv[@"overlays"])) {
            for (NSDictionary *b in arr(SFYTPath(ov, @"thumbnailBottomOverlayViewModel.badges"))) {
                NSDictionary *bv = dict(dict(b)[@"thumbnailBadgeViewModel"]);
                NSString *t = str(bv[@"text"]), *style = str(bv[@"badgeStyle"]);
                if ([style hasSuffix:@"_LIVE"]) live = YES;
                // no recorded answer with an upcoming video yet: its badge is known by text only
                else if ([t isEqualToString:@"Anstehend"] || [t.uppercaseString isEqualToString:@"UPCOMING"]) upcoming = YES;
                else if (parseDuration(t) > 0) dur = parseDuration(t);
            }
        }
        if (upcoming) return nil;   // not playable yet
        if (channel && meta) meta = [NSString stringWithFormat:@"%@ · %@", channel, meta];
        SFItem *vi = [self videoItem:cid title:title channel:channel channelID:chID meta:meta ?: channel thumb:thumb duration:dur live:live];
        for (NSString *part in [labels arrayByAddingObjectsFromArray:rowTexts.lastObject ?: @[]]) if ((vi.date = relativeDate(part))) break;
        for (NSString *part in rowTexts.lastObject) { long long n = SFYTViewCount(part); if (n >= 0) { vi.viewCount = n; break; } }
        return vi;
    }
    if ([type isEqualToString:@"LOCKUP_CONTENT_TYPE_PLAYLIST"]) {
        NSDictionary *pt = dict(SFYTPath(l, @"contentImage.collectionThumbnailViewModel.primaryThumbnail.thumbnailViewModel"));
        NSString *count = nil;
        for (NSDictionary *ov in arr(pt[@"overlays"]))
            for (NSDictionary *b in arr(SFYTPath(ov, @"thumbnailOverlayBadgeViewModel.thumbnailBadges")))
                count = SFYTText(SFYTPath(b, @"thumbnailBadgeViewModel.text")) ?: count;
        if (!cid) return nil;
        SFItem *f = [SFItem new];
        f.kind = SFItemFolder;
        f.identifier = [@"ytplaylist:" stringByAppendingString:cid];
        f.title = title;
        f.subtitle = count;
        f.image = SFYTLastURL(SFYTPath(pt, @"image.sources"));
        f.backdrop = f.image;
        f.style = SFTileStyleLandscape;
        f.source = @"youtube"; f.themeName = @"youtube";
        return f;
    }
    return nil;   // Shorts, channel lockups etc.
}

+ (SFItem *)fromVideoRenderer:(NSDictionary *)v legacyPlaylist:(BOOL)pl {
    NSString *vid = str(v[@"videoId"]);
    NSString *title = SFYTText(v[@"title"]);
    NSDictionary *own = dict(arr(SFYTPath(v, pl ? @"shortBylineText.runs" : @"ownerText.runs")).firstObject);
    NSString *channel = str(own[@"text"]);
    NSString *chID = str(SFYTPath(own, @"navigationEndpoint.browseEndpoint.browseId"));
    BOOL live = NO;
    for (NSDictionary *b in arr(v[@"badges"])) if ([str(SFYTPath(b, @"metadataBadgeRenderer.style")) isEqualToString:@"BADGE_STYLE_TYPE_LIVE_NOW"]) live = YES;
    for (NSDictionary *o in arr(v[@"thumbnailOverlays"])) if ([str(SFYTPath(o, @"thumbnailOverlayTimeStatusRenderer.style")) isEqualToString:@"LIVE"]) live = YES;
    NSTimeInterval dur = [str(v[@"lengthSeconds"]) doubleValue] ?: parseDuration(SFYTText(v[@"lengthText"]));
    NSMutableArray *meta = [NSMutableArray new];
    if (channel) [meta addObject:channel];
    NSString *views = SFYTText(v[@"viewCountText"]), *when = SFYTText(v[@"publishedTimeText"]);
    if (live && views) [meta addObject:views];
    if (when) [meta addObject:when];
    if ([v[@"isPlayable"] isKindOfClass:[NSNumber class]] && ![v[@"isPlayable"] boolValue]) return nil;
    SFItem *vi = [self videoItem:vid title:title channel:channel channelID:chID meta:[meta componentsJoinedByString:@" · "]
                           thumb:SFYTLastURL(SFYTPath(v, @"thumbnail.thumbnails")) duration:dur live:live];
    vi.date = relativeDate(when);
    if (!live && SFYTViewCount(views) >= 0) vi.viewCount = SFYTViewCount(views);
    return vi;
}

#pragma mark Walker (docs/youtube.md §3.0)

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
            NSString *sub = SFYTText(c[@"subscriberCountText"]);
            if ([sub hasPrefix:@"@"]) sub = SFYTText(c[@"videoCountText"]);
            SFItem *ch = [self channelItem:str(c[@"channelId"]) title:SFYTText(c[@"title"]) avatar:SFYTLastURL(SFYTPath(c, @"thumbnail.thumbnails")) meta:sub];
            if (ch) [channels addObject:ch];
            continue;
        }
        else if ([k isEqualToString:@"continuationItemRenderer"]) {
            NSString *t = str(SFYTPath(v, @"continuationEndpoint.continuationCommand.token"));
            if (t && cont) *cont = t;
            continue;
        }
        else if ([k isEqualToString:@"continuationItemViewModel"]) {
            NSString *t = str(SFYTPath(v, @"continuationCommand.innertubeCommand.continuationCommand.token"));
            if (t && cont) *cont = t;
            continue;
        }
        else { [self walk:v items:items channels:channels cont:cont]; continue; }
        if (it) [items addObject:it];
    }
}

+ (NSArray *)itemsIn:(id)json continuation:(NSString **)cont channels:(NSMutableArray *)channels {
    NSMutableArray *items = [NSMutableArray new];
    [self walk:json items:items channels:channels ?: [NSMutableArray new] cont:cont];
    NSMutableSet *seen = [NSMutableSet new];
    NSMutableArray *out = [NSMutableArray new];
    for (SFItem *i in items) if (![seen containsObject:i.identifier]) { [seen addObject:i.identifier]; [out addObject:i]; }
    return out;
}

#pragma mark Channel

+ (NSDictionary *)channelHeaderIn:(id)j {
    NSDictionary *vm = dict(SFYTPath(j, @"header.pageHeaderRenderer.content.pageHeaderViewModel"));
    NSMutableDictionary *h = [NSMutableDictionary new];
    // banner template is 2560x1440; without the fcrop crop = full TV image (16:9)
    NSString *bu = str(dict(arr(SFYTPath(vm, @"banner.imageBannerViewModel.image.sources")).lastObject)[@"url"]);
    NSRange eq = [bu rangeOfString:@"=" options:NSBackwardsSearch];
    if (eq.location != NSNotFound) h[@"banner"] = [[bu substringToIndex:eq.location] stringByAppendingString:@"=w1920-fcrop64=1,00000000ffffffff-k-c0xffffffff-no-nd-rj"];
    NSString *avatar = tvAvatar(str(dict(arr(SFYTPath(vm, @"image.decoratedAvatarViewModel.avatar.avatarViewModel.image.sources")).lastObject)[@"url"]));
    if (avatar.length) h[@"avatar"] = avatar;
    NSMutableArray *parts = [NSMutableArray new];
    for (NSDictionary *row in arr(SFYTPath(vm, @"metadata.contentMetadataViewModel.metadataRows")))
        for (NSDictionary *pt in arr(dict(row)[@"metadataParts"])) { NSString *t = str(SFYTPath(pt, @"text.content")); if (t.length) [parts addObject:t]; }
    if (parts.count) h[@"meta"] = [parts componentsJoinedByString:@" · "];
    NSString *desc = str(SFYTPath(vm, @"description.descriptionPreviewViewModel.description.content"));
    if (desc.length) h[@"description"] = desc;
    return h;
}

+ (BOOL)isTab:(NSString *)suffix in:(id)j {
    for (id t in arr(SFYTPath(j, @"contents.twoColumnBrowseResultsRenderer.tabs"))) {
        NSDictionary *tr = dict(dict(t)[@"tabRenderer"]);
        if (![tr[@"selected"] boolValue]) continue;
        return [str(SFYTPath(tr, @"endpoint.commandMetadata.webCommandMetadata.url")) hasSuffix:suffix];
    }
    return NO;
}

// The sort chips carry nothing but their label and a continuation token: the label is the only
// identification - "Beliebt" for the hl=de our requests ask for (SFYTCall).
+ (NSString *)popularTokenIn:(id)j {
    for (NSDictionary *tab in arr(SFYTPath(j, @"contents.twoColumnBrowseResultsRenderer.tabs")))
        for (NSDictionary *chip in arr(SFYTPath(tab, @"tabRenderer.content.richGridRenderer.header.chipBarViewModel.chips"))) {
            NSDictionary *c = dict(dict(chip)[@"chipViewModel"]);
            if ([str(c[@"accessibilityLabel"]) ?: str(c[@"text"]) isEqualToString:@"Beliebt"])
                return str(SFYTPath(c, @"tapCommand.innertubeCommand.continuationCommand.token"));
        }
    return nil;
}

#pragma mark Watch page (docs/youtube.md §3.4)

+ (NSArray *)relatedIn:(id)j video:(NSString *)vid {
    NSMutableArray *related = [NSMutableArray new];
    id sec = SFYTPath(j, @"contents.twoColumnWatchNextResults.secondaryResults.secondaryResults.results");
    for (SFItem *i in (sec ? [self itemsIn:sec continuation:NULL channels:nil] : @[])) {
        if (i.kind != SFItemVideo || !i.identifier || [i.externalID isEqualToString:vid]) continue;   // Shorts are not videos (fromLockup)
        [related addObject:i];
    }
    return related;
}

+ (NSDictionary *)watchDetailsIn:(id)j {
    if (!dict(j)) return nil;
    NSMutableDictionary *d = [NSMutableDictionary new];
    for (id c in arr(SFYTPath(j, @"contents.twoColumnWatchNextResults.results.results.contents")) ?: @[]) {
        NSDictionary *pri = dict(dict(c)[@"videoPrimaryInfoRenderer"]);
        NSDictionary *secr = dict(dict(c)[@"videoSecondaryInfoRenderer"]);
        if (pri) {   // publishDate: the bare day, "dd.MM.yyyy" for the hl=de our requests ask for (SFYTCall)
            NSDateFormatter *f = [NSDateFormatter new];
            f.dateFormat = @"dd.MM.yyyy"; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            f.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
            NSDate *date = [f dateFromString:SFYTText(pri[@"publishDate"]) ?: @""];
            if (date) d[@"date"] = date;
            NSString *title = SFYTText(pri[@"title"]);
            if (title.length) d[@"title"] = title;
            if ([nn(SFYTPath(pri, @"viewCount.videoViewCountRenderer.isLive")) boolValue]) d[@"live"] = @YES;
        }
        if (secr) {
            NSString *desc = str(SFYTPath(secr, @"attributedDescription.content")) ?: SFYTText(secr[@"description"]);
            if (desc.length) d[@"description"] = desc;
            NSDictionary *own = dict(SFYTPath(secr, @"owner.videoOwnerRenderer"));
            NSString *name = SFYTText(own[@"title"]);
            NSString *cid = str(SFYTPath(own, @"navigationEndpoint.browseEndpoint.browseId"));
            NSString *avatar = SFYTLastURL(SFYTPath(own, @"thumbnail.thumbnails"));
            if (name.length) d[@"channel"] = name;
            if ([cid hasPrefix:@"UC"]) d[@"channelID"] = cid;
            if (avatar.length) d[@"avatar"] = avatar;
        }
    }
    return d;
}
@end
