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

@implementation SFAppDelegate (Update)

#pragma mark Update (Helper tauscht die App; Zustand überlebt)

- (NSString *)resumePath { return [SFAppSupportDir() stringByAppendingPathComponent:@"resume.json"]; }

- (void)prepareForUpdate {
    SFLog(@"update: Zustand sichern und beenden");
    SFClearRunningMarker();   // geplantes Ende, kein Absturz
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
            if (p.remoteListID) {   // Handy-Sitzung: Liste + Queue überleben das Update
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
    // "Wird aktualisiert"-Bildschirm über allem
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
    for (SFScreen *s in self.nav.stack.reverseObjectEnumerator) [s willDisappear];   // Positionen speichern
    [[SFStore shared] flush];
    [[SFYTResolver shared] saveCache];   // fortgesetztes YouTube-Video startet ohne neue Auflösung
    SFLog(@"update: gesichert, beende");
    // _exit statt exit: alles ist gespeichert; exit() blieb in Framework-Aufräumhandlern hängen.
    // Auf einer Hintergrund-Queue: ein Main-Queue-Block lief nicht, solange der Main-Runloop
    // in einem anderen Modus steckte -> Helper musste nach 5 s hart beenden (Log „erzwinge“).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{ _exit(0); });
}

- (void)restoreAfterUpdate {
    NSData *d = [NSData dataWithContentsOfFile:[self resumePath]];
    [[NSFileManager defaultManager] removeItemAtPath:[self resumePath] error:nil];
    NSDictionary *st = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![st isKindOfClass:[NSDictionary class]] || [NSDate date].timeIntervalSince1970 - [st[@"t"] doubleValue] > 300) return;
    SFLog(@"update: Wiederherstellung %@", st[@"screens"]);
    for (NSString *k in st[@"screens"]) {
        if ([k hasPrefix:@"app:"]) [self.nav push:[SFHome appScreen:[k substringFromIndex:4]]];
    }
    if ([st[@"item"] isKindOfClass:[NSDictionary class]]) {
        SFItem *it = [SFItem itemWithDictionary:st[@"item"]];
        // Stream-Adresse des alten Prozesses (lokaler Proxy) nicht wiederverwenden (scheiterte mit -1102)
        // -> über den Resolver, der seine Ergebnisse aus dem alten Prozess übernommen hat
        if (it.playURL && !it.playURL.isFileURL && it.resolverRef.length) it.playURL = nil;
        NSMutableArray *queue = [NSMutableArray new];
        for (NSDictionary *d in ([st[@"queue"] isKindOfClass:[NSArray class]] ? st[@"queue"] : @[])) {
            SFItem *q = [d isKindOfClass:[NSDictionary class]] ? [SFItem itemWithDictionary:d] : nil;
            if (q.playURL && !q.playURL.isFileURL && q.resolverRef.length) q.playURL = nil;
            if (q) [queue addObject:q];
        }
        NSUInteger qi = [st[@"queueIndex"] unsignedIntegerValue];
        BOOL lounge = [st[@"remoteList"] isKindOfClass:[NSString class]] && qi < queue.count;
        if (lounge) queue[qi] = it;   // laufendes Video = Queue-Eintrag (ohne alte Stream-Adresse)
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
