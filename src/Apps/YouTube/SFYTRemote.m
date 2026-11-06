// Phone remote (YouTube "Mit TV verbinden"): commands from SFLounge -> the shell's player host.
#import "SFYouTubeApp.h"
#import "SFYTPages.h"
#import "SFYTWatch.h"
#import "SFPlayerScreen.h"
#import "SFLounge.h"

static NSUInteger gen_;   // later setPlaylist wins

// Titles/channels of a phone queue come from each video's watch page ("next"). Only the playing
// entry and the one after it, never the whole list: a 100-video playlist used to fetch 100 watch
// pages within a minute (3 bursts on 2026-11-06, bot checks 50 min later) - a browser opens one
// page per video watched. The rest follows as playback reaches it (SFYTRemoteFillAhead).
static void fillAround(NSArray *items, NSUInteger idx) {
    if (idx + 1 < items.count) [SFYTWatch fillDetails:items[idx + 1] done:nil];
}

void SFYTRemoteFillAhead(SFPlayerScreen *p) {
    if (!p.remoteListID) return;   // only queues the phone sent
    NSUInteger idx = [p.queue indexOfObjectIdenticalTo:p.item];
    if (idx != NSNotFound) fillAround(p.queue, idx);
}

void SFYTRemoteCommand(id<SFPlayerHost> host, NSString *cmd, NSDictionary *args) {
    if (!host) return;
    SFNavigator *nav = [host nav];
    SFPlayerScreen *p = [host topPlayer];
    if ([cmd isEqualToString:@"remoteConnected"]) {
        [nav toast:[NSString stringWithFormat:@"„%@“ verbunden", args[@"name"] ?: @"Handy"]];
    } else if ([cmd isEqualToString:@"setPlaylist"] || [cmd isEqualToString:@"setVideo"]) {
        NSString *ids = args[@"videoIds"] ?: args[@"videoId"] ?: @"";
        NSMutableArray *vids = [NSMutableArray new];
        for (NSString *v in [ids componentsSeparatedByString:@","]) if (v.length == 11) [vids addObject:v];
        if (!vids.count) return;
        NSUInteger idx = MIN((NSUInteger)MAX(0, [args[@"currentIndex"] integerValue]), vids.count - 1);
        NSString *want = args[@"videoId"];
        if (want && ![vids[idx] isEqualToString:want] && [vids indexOfObject:want] != NSNotFound) idx = [vids indexOfObject:want];
        NSTimeInterval t = [args[@"currentTime"] doubleValue];
        NSString *list = args[@"listId"] ?: @"";
        NSMutableArray *items = [NSMutableArray new];
        for (NSString *v in vids) [items addObject:[SFYTPages itemForVideoID:v title:nil thumb:nil]];
        // If exactly this video is already playing (phone reconnected, e.g. after a Sofa update):
        // never reload. Adopt list/queue; only seek if the phone knows a real, different
        // position (after a restart it often reports 0 -> Sofa's position wins).
        // Failed or finished (idle/ended): sending again means "try again" -> load.
        SFPlaybackState ps = p.playbackState;
        if (p && [p.item.externalID isEqualToString:vids[idx]] && ps != SFPlaybackIdle && ps != SFPlaybackEnded) {
            NSMutableArray *curIDs = [NSMutableArray new];
            for (SFItem *q in p.queue) [curIDs addObject:q.externalID ?: @""];
            if (![p.remoteListID isEqualToString:list] || ![curIDs isEqualToArray:vids]) {
                p.remoteListID = list;
                [p adoptQueue:items index:idx];
                fillAround(items, idx);
            }
            if (t > 1 && fabs([p currentTime] - t) > 3) [p remoteSeekTo:t];
            [p remotePlay];
            SFLog(@"lounge: video already playing - resumed instead of reloaded (phone %.0f s, Sofa %.0f s)", t, [p currentTime]);
            return;
        }
        [host wakeAndFront];
        NSUInteger gen = ++gen_;   // later setPlaylist wins
        [SFYTWatch fillDetails:items[idx] done:^{
            if (gen != gen_) return;
            SFPlayerScreen *cur = [host topPlayer];
            if (cur.remoteListID) { cur.remoteListID = list; [cur replaceQueue:items index:idx at:t]; }
            else {
                SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:items[idx] queue:items index:idx];
                ps.remoteListID = list;
                if (t > 1) ps.startPosition = t; else ps.startFromBeginning = YES;
                [host presentPlayer:ps];
            }
            fillAround(items, idx);
        }];
    } else if (!p) {
        return;
    } else if ([cmd isEqualToString:@"play"]) { [p remotePlay];
    } else if ([cmd isEqualToString:@"pause"]) { [p remotePause];
    } else if ([cmd isEqualToString:@"seekTo"]) { [p remoteSeekTo:[args[@"newTime"] doubleValue]];
    } else if ([cmd isEqualToString:@"next"]) { [p remoteNext];
    } else if ([cmd isEqualToString:@"previous"]) { [p remotePrevious];
    } else if ([cmd isEqualToString:@"stopVideo"]) { [p close];
    } else if ([cmd isEqualToString:@"setSubtitlesTrack"]) {
        // phone picks subtitles: languageCode ("" = off), vss_id ".de" = real, "a.de" = auto-generated
        NSString *vid = args[@"videoId"], *lang = args[@"languageCode"] ?: @"";
        if (vid.length && p.item.externalID && ![vid isEqualToString:p.item.externalID]) return;   // meant for another video
        NSString *vss = args[@"vss_id"] ?: args[@"vssId"] ?: @"";
        NSString *t = [p remoteSelectSubtitles:lang autoGenerated:[vss hasPrefix:@"a."]];
        if (t) [nav toast:lang.length ? [NSString stringWithFormat:@"Untertitel: %@", t] : @"Untertitel aus"];
        else if (lang.length) {
            NSString *name = [[NSLocale localeWithLocaleIdentifier:@"de"] displayNameForKey:NSLocaleIdentifier value:lang] ?: lang;
            [nav toast:[NSString stringWithFormat:@"Keine Untertitel auf %@ für dieses Video", name]];
        }
    }
}

