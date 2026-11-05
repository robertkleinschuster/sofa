#import "SFCore.h"
#import "SFScreen.h"
#import "SFHome.h"
#import "SFMenuScreen.h"
#import "SFRemote.h"
#import "SFStore.h"
#import "SFDevServer.h"
#import "SFMigration.h"
#import "SFPairScreen.h"
#import "SFMPVEngine.h"
#import "SFNet.h"
#import "SFFollows.h"
#import "SFCCCApp.h"
#import "SFARDApp.h"
#import "SFZDFApp.h"
#import "SFORFApp.h"
#import "SFYouTubeApp.h"
#import "SFYTResolver.h"
#import "SFLounge.h"
#import "SFPower.h"
#import "SFDownloads.h"
#import "SFPlayerScreen.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "SFPlayerScreen.h"
#import "SFLayers.h"
#import "SFRuntime.h"
#import "SFSettings.h"
#import "SFUpdater.h"
#import <ImageIO/ImageIO.h>
#include <sys/stat.h>
#import "SFAppDelegate.h"

@implementation SFAppDelegate (Lounge)

#pragma mark Phone pairing

// The visible player: the top screen, or the one right below overlays (menu, info panel) - the
// video keeps playing under them and stays controllable from the phone
- (SFPlayerScreen *)topPlayer {
    for (SFScreen *s in [self.nav.stack reverseObjectEnumerator]) {
        if ([s isKindOfClass:[SFPlayerScreen class]]) return (SFPlayerScreen *)s;
        if (s.isOpaque) return nil;
    }
    return nil;
}

// Show a new player in place of the visible one (overlays above it go away) or on top
- (void)presentPlayer:(SFPlayerScreen *)ps {
    SFPlayerScreen *cur = [self topPlayer];
    if (cur) { [self.nav popAbove:cur]; [self.nav replaceTop:ps]; }
    else [self.nav push:ps];
}

- (void)wakeAndFront {
    if (SFDevMode) return;
    IOPMAssertionID a = 0;
    IOPMAssertionDeclareUserActivity(CFSTR("Sofa: Handy"), kIOPMUserActiveLocal, &a);   // wakes the display
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)loungeCommand:(NSString *)cmd args:(NSDictionary *)args {
    SFPlayerScreen *p = [self topPlayer];
    if ([cmd isEqualToString:@"remoteConnected"]) {
        [self.nav toast:[NSString stringWithFormat:@"„%@“ verbunden", args[@"name"] ?: @"Handy"]];
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
        for (NSString *v in vids) [items addObject:[SFYouTubeApp itemForVideoID:v]];
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
                for (NSUInteger k = 0; k < items.count; k++) if (k != idx) [SFYouTubeApp fillDetails:items[k] done:nil];
            }
            if (t > 1 && fabs([p currentTime] - t) > 3) [p remoteSeekTo:t];
            [p remotePlay];
            SFLog(@"lounge: video already playing - resumed instead of reloaded (phone %.0f s, Sofa %.0f s)", t, [p currentTime]);
            return;
        }
        [self wakeAndFront];
        NSUInteger gen = ++self.loungeGen;   // later setPlaylist wins
        [SFYouTubeApp fillDetails:items[idx] done:^{
            if (gen != self.loungeGen) return;
            SFPlayerScreen *cur = [self topPlayer];
            if (cur.remoteListID) { cur.remoteListID = list; [cur replaceQueue:items index:idx at:t]; }
            else {
                SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:items[idx] queue:items index:idx];
                ps.remoteListID = list;
                if (t > 1) ps.startPosition = t; else ps.startFromBeginning = YES;
                [self presentPlayer:ps];
            }
            for (NSUInteger k = 0; k < items.count; k++) if (k != idx) [SFYouTubeApp fillDetails:items[k] done:nil];
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
        if (t) [self.nav toast:lang.length ? [NSString stringWithFormat:@"Untertitel: %@", t] : @"Untertitel aus"];
        else if (lang.length) {
            NSString *name = [[NSLocale localeWithLocaleIdentifier:@"de"] displayNameForKey:NSLocaleIdentifier value:lang] ?: lang;
            [self.nav toast:[NSString stringWithFormat:@"Keine Untertitel auf %@ für dieses Video", name]];
        }
    }
}

@end
