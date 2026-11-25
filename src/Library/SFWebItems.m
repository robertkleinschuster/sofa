#import "SFWebItems.h"
#import "SFWebImages.h"
#import "SFStore.h"
#import "SFWatchLater.h"
#import "SFFollows.h"
#import "SFTileStatus.h"
#import "SFApp.h"
#import "SFJSON.h"

static const NSUInteger kMaxHandles = 4000;   // a few hundred pages of browsing; older handles answer 410

static NSString *StyleName(SFTileStyle s) {
    switch (s) {
        case SFTileStyleCircle: return @"circle";
        case SFTileStylePoster: return @"poster";
        case SFTileStyleApp: return @"app";
        case SFTileStyleWide: return @"wide";
        case SFTileStyleButton: return @"button";
        default: return @"landscape";
    }
}

static NSString *KindName(SFItemKind k) {
    switch (k) {
        case SFItemLive: return @"live";
        case SFItemFolder: return @"folder";
        case SFItemAction: return @"action";
        default: return @"video";
    }
}

static NSString *HexOf(NSColor *c) {
    NSColor *x = [c colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    if (!x) return nil;
    return [NSString stringWithFormat:@"#%02x%02x%02x", (int)round(x.redComponent * 255), (int)round(x.greenComponent * 255), (int)round(x.blueComponent * 255)];
}

@implementation SFWebItems

#pragma mark Handles

static NSMutableDictionary *gHandles;   // handle -> block
static NSMutableArray *gOrder;          // oldest first

static NSString *Remember(id block) {
    if (!block) return nil;
    if (!gHandles) { gHandles = [NSMutableDictionary new]; gOrder = [NSMutableArray new]; }
    NSString *h = [[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString;
    gHandles[h] = [block copy];
    [gOrder addObject:h];
    while (gOrder.count > kMaxHandles) { [gHandles removeObjectForKey:gOrder[0]]; [gOrder removeObjectAtIndex:0]; }
    return h;
}

+ (NSString *)handleForPageLoader:(SFPageLoader)loader { return Remember(loader); }
+ (SFPageLoader)pageLoaderForHandle:(NSString *)h { return h ? gHandles[h] : nil; }
+ (void (^)(void (^)(NSArray *, BOOL)))moreLoaderForHandle:(NSString *)h { return h ? gHandles[h] : nil; }

#pragma mark Serialization

+ (NSDictionary *)page:(SFPage *)page {
    NSMutableDictionary *p = [NSMutableDictionary new];
    if (page.title) p[@"title"] = page.title;
    if (page.subtitle) p[@"subtitle"] = page.subtitle;
    if (page.themeName) p[@"theme"] = page.themeName;
    if (page.backdrop) p[@"backdrop"] = [SFWebImages pathFor:page.backdrop];
    if (page.emptyText) p[@"empty"] = page.emptyText;
    NSMutableArray *shelves = [NSMutableArray new];
    for (SFShelf *s in page.shelves) {
        NSArray *items = [self items:s.items];
        if (!items.count && !s.moreLoader) continue;
        NSMutableDictionary *d = [@{@"layout": s.layout == SFShelfGrid ? @"grid" : @"rail", @"style": StyleName(s.style), @"items": items} mutableCopy];
        if (s.title) d[@"title"] = s.title;
        if (s.moreLoader) d[@"more"] = Remember(s.moreLoader);
        if (s.focusIndex) d[@"focus"] = @(s.focusIndex);
        [shelves addObject:d];
    }
    p[@"shelves"] = shelves;
    return p;
}

+ (NSArray *)items:(NSArray *)items {
    NSMutableArray *out = [NSMutableArray new];
    for (SFItem *i in items) { NSDictionary *d = [self item:i]; if (d) [out addObject:d]; }
    return out;
}

// What the browser can do with an action tile: open an app's start page, an app's search. Every
// other action runs something on the TV (settings, the keyboard) and is left out.
static NSString *ActionKind(SFItem *i, NSString **arg) {
    NSString *ident = i.identifier ?: @"";
    if ([ident hasPrefix:@"app:"]) { *arg = [ident substringFromIndex:4]; return @"app"; }
    if ([ident hasPrefix:@"search:"] && i.source) { *arg = i.source; return @"search"; }
    return nil;
}

+ (NSDictionary *)item:(SFItem *)i {
    NSMutableDictionary *d = [NSMutableDictionary new];
    NSString *arg = nil;
    if (i.kind == SFItemAction) {
        NSString *what = ActionKind(i, &arg);
        if (!what) return nil;
        d[@"open"] = what; d[@"arg"] = arg;
    }
    if (i.kind == SFItemFolder) {
        if (i.pageLoader) d[@"page"] = Remember(i.pageLoader);
        else if (!(i.identifier && [SFAppRegistry isShowRef:i.identifier])) return nil;   // nothing to open
        if (i.identifier && [[SFFollows shared] canFollow:i]) d[@"following"] = @([[SFFollows shared] isFollowing:i.identifier]);
    }
    d[@"kind"] = KindName(i.kind);
    if (i.identifier) d[@"id"] = i.identifier;
    if (i.title) d[@"title"] = i.title;
    if (i.subtitle) d[@"sub"] = i.subtitle;
    if (i.plot) d[@"plot"] = i.plot;
    if (i.channel) d[@"channel"] = i.channel;
    if (i.source) d[@"source"] = i.source;
    if (i.themeName) d[@"theme"] = i.themeName;
    if (i.badge) d[@"badge"] = i.badge;
    if (i.drm) d[@"drm"] = @YES;
    if (i.duration > 0) d[@"duration"] = @(i.duration);
    if (i.date) d[@"date"] = @(i.date.timeIntervalSince1970);
    if (i.logo) { d[@"logo"] = i.logo; d[@"logoVariant"] = @(i.logoVariant); }
    if (i.tint) d[@"tint"] = HexOf(i.tint);
    if (i.imageFit) d[@"fit"] = @YES;
    if (i.heroTitle) d[@"heroTitle"] = i.heroTitle;
    if (i.heroMeta) d[@"heroMeta"] = i.heroMeta;
    if (i.showRef) d[@"showRef"] = i.showRef;
    if (i.style != SFTileStyleLandscape) d[@"style"] = StyleName(i.style);
    if (i.showsSourceMark) d[@"mark"] = @YES;
    NSString *img = [SFWebImages pathFor:i.image], *back = [SFWebImages pathFor:i.backdrop],
             *fallback = [SFWebImages pathFor:i.imageFallback], *chan = [SFWebImages pathFor:i.channelImage];
    if (img) d[@"img"] = img;
    if (back) d[@"backdrop"] = back;
    if (fallback) d[@"imgFallback"] = fallback;
    if (chan) d[@"channelImg"] = chan;
    if (i.kind == SFItemVideo && i.identifier) {
        static SFTileStatus *status;
        if (!status) status = [SFTileStatus new];
        double p = [status progressForItem:i];
        if (p > 0) d[@"progress"] = @(MIN(1, p));
        if ([[SFStore shared] watched:i.identifier]) d[@"watched"] = @YES;
        d[@"later"] = @([[SFWatchLater shared] contains:i.identifier]);
        NSString *chip = [status chipTextForItem:i];
        if (chip) d[@"chip"] = chip;
    }
    if (i.kind == SFItemLive) {
        SFBroadcast *now = [i broadcastAt:[NSDate date]];
        if (now) {
            d[@"now"] = [now dictionaryRepresentation];
            SFBroadcast *next = [i broadcastAfter:now];
            if (next) d[@"next"] = [next dictionaryRepresentation];
        }
    }
    if (i.kind == SFItemVideo || i.kind == SFItemLive || i.kind == SFItemFolder) d[@"d"] = [i dictionaryRepresentation];
    return d;
}

+ (SFItem *)itemFromBrowser:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]] || !str(d[@"id"]).length) return nil;
    NSMutableDictionary *m = [d mutableCopy];
    [m removeObjectForKey:@"localPath"];
    // a source's own URL only: never a file, never this machine's own services
    NSString *url = str(m[@"url"]);
    NSString *host = url ? [[[NSURL URLWithString:url] host] lowercaseString] : nil;
    BOOL local = !host.length || [host hasPrefix:@"127."] || [host isEqualToString:@"localhost"] || [host isEqualToString:@"::1"]
              || [host isEqualToString:@"0.0.0.0"] || [host hasSuffix:@".local"];
    if (url && (local || !([url hasPrefix:@"https://"] || [url hasPrefix:@"http://"]))) [m removeObjectForKey:@"url"];
    SFItem *i = [SFItem itemWithDictionary:m];
    if (i.kind == SFItemAction) return nil;
    return i;
}
@end
