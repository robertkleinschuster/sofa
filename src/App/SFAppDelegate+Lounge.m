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
#import "SFProviderCCC.h"
#import "SFProviderARD.h"
#import "SFProviderZDF.h"
#import "SFProviderORF.h"
#import "SFYouTube.h"
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

#pragma mark Handy-Koppeln

- (SFPlayerScreen *)topPlayer { return [self.nav.top isKindOfClass:[SFPlayerScreen class]] ? (SFPlayerScreen *)self.nav.top : nil; }

- (void)wakeAndFront {
    if (SFDevMode) return;
    IOPMAssertionID a = 0;
    IOPMAssertionDeclareUserActivity(CFSTR("Sofa: Handy"), kIOPMUserActiveLocal, &a);   // weckt das Display
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
        for (NSString *v in vids) [items addObject:[SFYouTube itemForVideoID:v]];
        // Läuft genau dieses Video schon (Handy hat sich neu verbunden, z.B. nach einem Sofa-Update):
        // nie neu laden. Liste/Queue übernehmen; springen nur, wenn das Handy eine echte, andere
        // Position kennt (nach einem Neustart meldet es oft 0 -> Sofas Position gilt).
        // Fehlgeschlagen oder zu Ende (Idle/Ended): erneutes Senden heißt „nochmal versuchen“ -> laden.
        SFPlaybackState ps = p.playbackState;
        if (p && [p.item.externalID isEqualToString:vids[idx]] && ps != SFPlaybackIdle && ps != SFPlaybackEnded) {
            NSMutableArray *curIDs = [NSMutableArray new];
            for (SFItem *q in p.queue) [curIDs addObject:q.externalID ?: @""];
            if (![p.remoteListID isEqualToString:list] || ![curIDs isEqualToArray:vids]) {
                p.remoteListID = list;
                [p adoptQueue:items index:idx];
                for (NSUInteger k = 0; k < items.count; k++) if (k != idx) [SFYouTube fillDetails:items[k] done:nil];
            }
            if (t > 1 && fabs([p currentTime] - t) > 3) [p remoteSeekTo:t];
            [p remotePlay];
            SFLog(@"lounge: Video läuft schon – fortgesetzt statt neu geladen (Handy %.0f s, Sofa %.0f s)", t, [p currentTime]);
            return;
        }
        [self wakeAndFront];
        NSUInteger gen = ++self.loungeGen;   // spätere setPlaylist gewinnt
        [SFYouTube fillDetails:items[idx] done:^{
            if (gen != self.loungeGen) return;
            SFPlayerScreen *cur = [self topPlayer];
            if (cur.remoteListID) { cur.remoteListID = list; [cur replaceQueue:items index:idx at:t]; }
            else {
                SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:items[idx] queue:items index:idx];
                ps.remoteListID = list;
                if (t > 1) ps.startPosition = t; else ps.startFromBeginning = YES;
                if (cur) [self.nav replaceTop:ps]; else [self.nav push:ps];
            }
            for (NSUInteger k = 0; k < items.count; k++) if (k != idx) [SFYouTube fillDetails:items[k] done:nil];
        }];
    } else if (!p) {
        return;
    } else if ([cmd isEqualToString:@"play"]) { [p remotePlay];
    } else if ([cmd isEqualToString:@"pause"]) { [p remotePause];
    } else if ([cmd isEqualToString:@"seekTo"]) { [p remoteSeekTo:[args[@"newTime"] doubleValue]];
    } else if ([cmd isEqualToString:@"next"]) { [p remoteNext];
    } else if ([cmd isEqualToString:@"previous"]) { [p remotePrevious];
    } else if ([cmd isEqualToString:@"stopVideo"]) { [self.nav pop];
    }
}

@end
