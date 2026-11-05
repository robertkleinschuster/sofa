#import "SFCore.h"
#import "SFScreen.h"
#import "SFHome.h"
#import "SFMenuScreen.h"
#import "SFRemote.h"
#import "SFStore.h"
#import "SFDevServer.h"
#import "SFMigration.h"
#import "SFMPVEngine.h"
#import "SFNet.h"
#import "SFFollows.h"
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
#import "SFApp.h"

@implementation SFAppDelegate (Update)

static id gHandover;   // activity token of the update handover (released = activity ends)

#pragma mark Update (helper swaps the app; state survives)

- (NSString *)resumePath { return [SFAppSupportDir() stringByAppendingPathComponent:@"resume.json"]; }

- (void)prepareForUpdate {
    SFLog(@"update: saving state and quitting");
    SFClearRunningMarker();   // planned exit, not a crash
    NSMutableDictionary *st = [NSMutableDictionary new];
    st[@"t"] = @([NSDate date].timeIntervalSince1970);
    NSMutableArray *keys = [NSMutableArray new];
    for (SFScreen *s in self.nav.stack) if (s.restoreKey) [keys addObject:s.restoreKey];
    st[@"screens"] = keys;
    for (SFScreen *s in self.nav.stack.reverseObjectEnumerator) {
        if (![s isKindOfClass:[SFPlayerScreen class]]) continue;
        SFPlayerScreen *p = (SFPlayerScreen *)s;
        if (p.item) {
            st[@"item"] = [p.item dictionaryRepresentation];
            if (p.remoteListID) {   // phone session: list + queue survive the update
                st[@"remoteList"] = p.remoteListID;
                NSMutableArray *q = [NSMutableArray new];
                for (SFItem *it in p.queue) [q addObject:[it dictionaryRepresentation]];
                st[@"queue"] = q; st[@"queueIndex"] = @(p.queueIndex);
            }
            if ([p currentTime] > 2) st[@"pos"] = @([p currentTime]);
            st[@"paused"] = @([p isPaused]);
        }
        break;
    }
    [[NSJSONSerialization dataWithJSONObject:st options:0 error:nil] writeToFile:[self resumePath] atomically:YES];
    // "updating" screen above everything
    CALayer *ov = [CALayer layer];
    ov.frame = self.nav.layer.bounds;
    ov.backgroundColor = [NSColor colorWithDeviceWhite:0.04 alpha:0.94].CGColor;
    ov.zPosition = 5000;
    SFLabel *l = [SFLabel labelWithFont:[NSFont fontWithName:@"AvenirNext-DemiBold" size:U(44)] color:[NSColor whiteColor]];
    l.text = @"Sofa wird aktualisiert …";
    l.alignment = NSCenterTextAlignment;
    CGFloat h = [l sizeToFitWidth:ov.bounds.size.width];
    l.position = CGPointMake(0, (ov.bounds.size.height - h) / 2);
    [ov addSublayer:l];
    SFNoAnimate(^{ [self.nav.layer addSublayer:ov]; });
    [CATransaction flush];
    for (SFScreen *s in self.nav.stack.reverseObjectEnumerator) [s willDisappear];   // save positions
    [[SFDownloads shared] stopForExit];   // _exit below skips cleanup: ffmpeg would survive as an orphan
    [[SFStore shared] flush];
    [SFAppRegistry prepareAllForRelaunch];   // apps persist caches (a resumed video starts without a new resolve)
    SFLog(@"update: saved, quitting");
    // _exit instead of exit: everything is saved; exit() used to hang in framework cleanup handlers.
    // On its own thread: a main-queue block didn't run while the main run loop was stuck in
    // another mode. The later "forcing" on every update (2026-11-05) was App Nap stretching the
    // delay (see main.m, _noNap); the latency-critical activity keeps this last sleep exact.
    gHandover = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityLatencyCritical | NSActivityUserInitiated reason:@"Sofa: update handover"];
    [NSThread detachNewThreadSelector:@selector(exitAfterUpdateSave) toTarget:[SFAppDelegate class] withObject:nil];
}

+ (void)exitAfterUpdateSave {
    usleep(500 * 1000);   // the "updating" overlay is on screen, files are written
    SFLogFlush();
    _exit(0);
}

- (void)restoreAfterUpdate {
    NSData *d = [NSData dataWithContentsOfFile:[self resumePath]];
    [[NSFileManager defaultManager] removeItemAtPath:[self resumePath] error:nil];
    NSDictionary *st = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![st isKindOfClass:[NSDictionary class]] || [NSDate date].timeIntervalSince1970 - [st[@"t"] doubleValue] > 300) return;
    SFLog(@"update: restoring %@", st[@"screens"]);
    for (NSString *k in st[@"screens"]) {
        if ([k hasPrefix:@"app:"]) [self.nav push:[SFHome appScreen:[k substringFromIndex:4]]];
    }
    if ([st[@"item"] isKindOfClass:[NSDictionary class]]) {
        SFItem *it = [SFItem itemWithDictionary:st[@"item"]];
        // Don't reuse the old process's stream address (local proxy) (failed with -1102)
        // -> go through the resolver, which took over its results from the old process
        if (it.playURL && !it.playURL.isFileURL && it.resolverRef.length) it.playURL = nil;
        NSMutableArray *queue = [NSMutableArray new];
        for (NSDictionary *d in ([st[@"queue"] isKindOfClass:[NSArray class]] ? st[@"queue"] : @[])) {
            SFItem *q = [d isKindOfClass:[NSDictionary class]] ? [SFItem itemWithDictionary:d] : nil;
            if (q.playURL && !q.playURL.isFileURL && q.resolverRef.length) q.playURL = nil;
            if (q) [queue addObject:q];
        }
        NSUInteger qi = [st[@"queueIndex"] unsignedIntegerValue];
        BOOL lounge = [st[@"remoteList"] isKindOfClass:[NSString class]] && qi < queue.count;
        if (lounge) queue[qi] = it;   // current video = queue entry (without the old stream address)
        SFPlayerScreen *p = [[SFPlayerScreen alloc] initWithItem:it queue:lounge ? queue : nil index:lounge ? qi : 0];
        if (lounge) p.remoteListID = st[@"remoteList"];
        if ([st[@"pos"] doubleValue] > 2) p.startPosition = [st[@"pos"] doubleValue] - 2;
        p.startPaused = [st[@"paused"] boolValue];
        [self.nav push:p];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.nav toast:[@"Sofa wurde aktualisiert – Version " stringByAppendingString:[[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"]]];
    });
}

@end
