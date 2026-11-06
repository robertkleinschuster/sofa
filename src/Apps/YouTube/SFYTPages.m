#import "SFYTPages.h"
#import "SFFollowAction.h"
#import "SFApp.h"
#import "SFYTInnerTube.h"
#import "SFYTParser.h"
#import "SFMenuScreen.h"
#import "SFPairScreen.h"
#import "SFLounge.h"
#import "SFLibraryPages.h"
#import "SFIconArt.h"
#import "SFLibrary.h"
#import "SFDownloads.h"
#import "SFFollows.h"
#import "SFStore.h"

@implementation SFYTPages

#pragma mark Parsed -> shown

+ (SFItem *)shownItem:(SFItem *)i {
    NSString *p = SFRefPrefix(i.identifier);
    if (i.kind == SFItemFolder) {
        if ([p isEqualToString:@"ytplaylist"]) i.pageLoader = [self playlistLoader:SFRefID(i.identifier) title:i.title];
        else if ([p isEqualToString:@"ytchannel"]) i.pageLoader = [self channelLoader:SFRefID(i.identifier) title:i.title];
        return i;
    }
    // already downloaded: the local file (quality, offline, shared progress)
    SFItem *local = [p isEqualToString:@"yt"] ? [[SFDownloads shared] itemFor:i.identifier] : nil;
    if (!local) return i;
    SFItem *c = [local copy];
    c.subtitle = i.subtitle.length ? [NSString stringWithFormat:@"%@ · auf diesem Mac", i.subtitle] : @"Auf diesem Mac";
    if (!c.showRef) c.showRef = i.showRef;
    return c;
}

+ (NSArray *)shown:(NSArray *)parsed {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:parsed.count];
    for (SFItem *i in parsed) [out addObject:[self shownItem:i]];
    return out;
}

+ (SFItem *)itemForVideoID:(NSString *)vid title:(NSString *)title thumb:(NSString *)thumb {
    SFItem *i = [SFYTParser videoItem:vid title:title.length ? title : @"YouTube" channel:nil channelID:nil meta:nil
                                thumb:thumb.length ? thumb : nil duration:0 live:NO];
    return i ? [self shownItem:i] : nil;
}

#pragma mark Lists

// A list with its continuation pages (up to max entries)
+ (void)collect:(NSString *)endpoint body:(NSDictionary *)body cache:(NSTimeInterval)age max:(NSUInteger)max
           into:(NSMutableArray *)acc json:(void (^)(id first))first done:(void (^)(NSArray *items, NSError *e))done {
    SFYTCall(endpoint, body, age, ^(id j, NSError *e) {
        if (!j) { done(acc.count ? acc : nil, e); return; }
        if (first) first(j);
        NSString *cont = nil;
        NSArray *items = [self shown:[SFYTParser itemsIn:j continuation:&cont channels:nil]];
        NSMutableSet *have = [NSMutableSet new];
        for (SFItem *i in acc) [have addObject:i.identifier];
        for (SFItem *i in items) if (![have containsObject:i.identifier]) [acc addObject:i];
        if (cont && acc.count < max && items.count)
            [self collect:endpoint body:@{@"continuation": cont} cache:age max:max into:acc json:nil done:done];
        else done(acc, nil);
    });
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

+ (SFPageLoader)searchLoader:(NSString *)q {
    return ^(SFPageDone done) {
        // the first page also returns the channels; continuation pages up to ~60 hits
        NSMutableArray *channels = [NSMutableArray new];
        [self collect:@"search" body:@{@"query": q ?: @""} cache:600 max:60 into:[NSMutableArray new]
                 json:^(id first) { [SFYTParser itemsIn:first continuation:NULL channels:channels]; }
                 done:^(NSArray *all, NSError *e) {
            if (!all) { done(nil, e); return; }
            // keep YouTube's order (relevance); mixes (RD...) are not real playlists
            NSMutableArray *results = [NSMutableArray new];
            for (SFItem *i in all) if (![i.identifier hasPrefix:@"ytplaylist:RD"]) [results addObject:i];
            NSMutableArray *shelves = [NSMutableArray new];
            if (channels.count) [shelves addObject:[SFShelf shelf:@"Kanäle" style:SFTileStyleCircle items:[self shown:channels]]];
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

#pragma mark Channel

// Like YouTube's: banner, name and compact buttons, then live, continue watching, newest, popular,
// playlists, past streams, all videos. Header and tabs load in parallel to the uploads.
+ (SFPageLoader)channelLoader:(NSString *)cid title:(NSString *)title {
    return ^(SFPageDone done) {
        // all uploads, newest first: playlist "UU" + channel ID without "UC"
        // "UULF" = long videos only (no Shorts); fallback "UU" = all uploads
        NSString *uploads = [cid hasPrefix:@"UC"] ? [@"UULF" stringByAppendingString:[cid substringFromIndex:2]] : nil;
        __block NSDictionary *header = nil;
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
            [shelves addObject:[SFShelf shelf:nil style:SFTileStyleButton items:[self channelButtons:cid title:title header:header]]];
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
            p.backdrop = header[@"banner"];
            if (!shelves.count) p.emptyText = @"Dieser Kanal hat keine Videos.";
            done(p, nil);
        };
        if (!uploads) { build(nil, SFError(@"Unbekannter Kanal.")); return; }
        dispatch_group_t g = dispatch_group_create();
        // channel header (banner, avatar, subscribers, description)
        dispatch_group_enter(g);
        SFYTCall(@"browse", @{@"browseId": cid}, 86400, ^(id j, NSError *he) {
            header = [SFYTParser channelHeaderIn:j];
            dispatch_group_leave(g);
        });
        // the channel's playlists tab (like YouTube)
        dispatch_group_enter(g);
        SFYTCall(@"browse", @{@"browseId": cid, @"params": @"EglwbGF5bGlzdHPyBgQKAkIA"}, 3600, ^(id j, NSError *pe) {
            NSMutableArray *pl = [NSMutableArray new];
            NSArray *found = [SFYTParser isTab:@"/playlists" in:j] ? [self shown:[SFYTParser itemsIn:j continuation:NULL channels:nil]] : @[];
            for (SFItem *i in found) if (i.kind == SFItemFolder && ![i.identifier hasPrefix:@"ytplaylist:RD"]) { i.style = SFTileStyleLandscape; [pl addObject:i]; }   // mixes (RD...) are not channel playlists
            playlists = pl;
            dispatch_group_leave(g);
        });
        // "Beliebt" (popular) like in YouTube's videos tab: the tab's sort chip -> its continuation
        // returns the videos sorted by views
        dispatch_group_enter(g);
        SFYTCall(@"browse", @{@"browseId": cid, @"params": @"EgZ2aWRlb3PyBgQKAjoA"}, 86400, ^(id j, NSError *ve) {
            NSString *tok = [SFYTParser popularTokenIn:j];
            if (!tok) { dispatch_group_leave(g); return; }
            SFYTCall(@"browse", @{@"continuation": tok}, 86400, ^(id pj, NSError *pe) {
                NSMutableArray *pv = [NSMutableArray new];
                for (SFItem *i in (pj ? [self shown:[SFYTParser itemsIn:pj continuation:NULL channels:nil]] : @[])) if (i.kind != SFItemFolder && i.kind != SFItemLive) [pv addObject:i];   // downloaded ones too (local copy)
                popular = pv;
                dispatch_group_leave(g);
            });
        });
        // live tab (like YouTube): running + past streams; cached briefly, live status changes
        dispatch_group_enter(g);
        SFYTCall(@"browse", @{@"browseId": cid, @"params": @"EgdzdHJlYW1z8gYECgJ6AA=="}, 600, ^(id j, NSError *le) {
            streams = [SFYTParser isTab:@"/streams" in:j] ? [self shown:[SFYTParser itemsIn:j continuation:NULL channels:nil]] : nil;
            dispatch_group_leave(g);
        });
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

// [Folgen] (red while not followed) · [Automatisch laden: An/Aus] (only when followed)
+ (NSArray *)channelButtons:(NSString *)cid title:(NSString *)title header:(NSDictionary *)header {
    SFDownloads *dl = [SFDownloads shared];
    SFFollows *fo = [SFFollows shared];
    NSString *fid = [@"ytchannel:" stringByAppendingString:cid];
    SFItem *folder = [SFItem new];
    folder.kind = SFItemFolder; folder.identifier = fid; folder.title = title; folder.source = @"youtube"; folder.image = header[@"avatar"];
    BOOL following = [fo isFollowing:fid], autoDL = [dl isSubscribed:fid];
    SFNavigator *(^navi)(void) = ^SFNavigator *{ return [SFNavigator main]; };
    NSMutableArray *buttons = [NSMutableArray new];
    SFItem *fb = [SFItem new];
    fb.kind = SFItemAction; fb.style = SFTileStyleButton; fb.source = @"youtube"; fb.themeName = @"youtube";
    fb.identifier = [@"ytfollow:" stringByAppendingString:cid];
    fb.title = following ? @"✓  Gefolgt" : @"Folgen";
    if (!following) fb.tint = [SFTheme themeNamed:@"youtube"].accent;
    fb.backdrop = header[@"banner"]; fb.heroTitle = title; fb.heroMeta = header[@"meta"]; fb.plot = header[@"description"];
    fb.action = ^{ SFToggleFollow(navi(), folder, [SFTheme themeNamed:@"youtube"], YES); };
    [buttons addObject:fb];
    if (following) {
        SFItem *db = [SFItem new];
        db.kind = SFItemAction; db.style = SFTileStyleButton; db.source = @"youtube"; db.themeName = @"youtube";
        db.identifier = [@"ytautodl:" stringByAppendingString:cid];
        db.title = autoDL ? @"Automatisch laden: An" : @"Automatisch laden: Aus";
        db.backdrop = header[@"banner"]; db.heroTitle = title; db.heroMeta = header[@"meta"];
        db.plot = @"Neue Videos dieses Kanals automatisch herunterladen – dann laufen sie auch ohne Internet.";
        db.action = ^{
            if ([dl isSubscribed:fid]) { [dl unsubscribe:fid]; [navi() toast:@"Automatisch laden aus – vorhandene Videos bleiben"]; }
            else { [dl subscribe:folder]; [navi() toast:[NSString stringWithFormat:@"Neue Videos von „%@“ werden heruntergeladen", title]]; }
            [[NSNotificationCenter defaultCenter] postNotificationName:SFLibraryDidChangeNotification object:nil];
        };
        [buttons addObject:db];
    }
    return buttons;
}

#pragma mark Start page

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

// One tile that adapts to the situation (YouTube → Mehr):
//  no phone connected    -> "Mit Handy verbinden" opens the code directly (OK there = settings)
//  connected / paused    -> "Handy: Name" / "Handy pausiert" opens the settings
+ (SFItem *)phoneTile {
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
@end
