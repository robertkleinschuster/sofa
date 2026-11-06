#import "SFDownloads+Private.h"
#import "SFLibraryPages.h"
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
#import "SFStats.h"
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
#import <ImageIO/ImageIO.h>

@implementation SFAppDelegate (Dev)

#pragma mark Dev FIFO

static NSString *fifoPath(void) {
    NSString *own = SFDevPrivateDir();   // tests: inside their temporary data directory
    return own ? [own stringByAppendingPathComponent:@"dev.fifo"]
               : [SFSharedCacheDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"dev-%@.fifo", gInstance]];
}

- (void)startFifo {
    NSString *p = fifoPath();
    unlink(p.fileSystemRepresentation);
    mkfifo(p.fileSystemRepresentation, 0600);
    int fd = open(p.fileSystemRepresentation, O_RDWR | O_NONBLOCK);
    if (fd < 0) { SFLog(@"dev: fifo open failed"); return; }
    self.fifoBuf = [NSMutableString new];
    self.fifoSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.fifoSrc, ^{
        char buf[4096];
        ssize_t r = read(fd, buf, sizeof buf);
        if (r <= 0) return;
        [self.fifoBuf appendString:[[NSString alloc] initWithBytes:buf length:r encoding:NSUTF8StringEncoding] ?: @""];
        NSRange nl;
        while ((nl = [self.fifoBuf rangeOfString:@"\n"]).location != NSNotFound) {
            NSString *line = [self.fifoBuf substringToIndex:nl.location];
            [self.fifoBuf deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
            [self devCommand:[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        }
    });
    dispatch_resume(self.fifoSrc);
    SFLog(@"dev: fifo ready at %@", p);
}

// on quit: the control pipe goes with the instance (the shared cache dir holds only live ones)
- (void)stopFifo {
    if (!self.fifoSrc) return;
    dispatch_source_cancel(self.fifoSrc);
    unlink(fifoPath().fileSystemRepresentation);
}

- (void)devCommand:(NSString *)line {
    if (!line.length) return;
    NSArray *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts[0];
    NSString *arg = parts.count > 1 ? [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" "] : nil;
    SFLog(@"dev: %@", line);
    if ([SFAppRegistry handleDevCommand:cmd arg:arg host:self]) return;   // app-specific commands (docs: each app's handleDevCommand)
    if ([cmd isEqualToString:@"parse"] && arg) {   // parser golden test: parse <app> <kind> <in.json> <out.txt>
        NSArray *a = [arg componentsSeparatedByString:@" "];
        Class<SFApp> app = a.count == 4 ? [SFAppRegistry appNamed:a[0]] : nil;
        NSData *data = app ? [NSData dataWithContentsOfFile:a[2]] : nil;
        id j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSArray *lines = j && [app respondsToSelector:@selector(parseFixture:kind:)] ? [app parseFixture:j kind:a[1]] : nil;
        if (!lines) { SFLog(@"dev: parse failed: %@", arg); return; }
        NSString *out = lines.count ? [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] : @"";
        [out writeToFile:a[3] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        SFLog(@"dev: parse written %@", a[3]);
    } else if ([cmd isEqualToString:@"key"]) {
        NSDictionary *m = @{@"up": @(SFKeyUp), @"down": @(SFKeyDown), @"left": @(SFKeyLeft), @"right": @(SFKeyRight),
                            @"select": @(SFKeySelect), @"menu": @(SFKeyMenu), @"play": @(SFKeyPlayPause),
                            @"selecthold": @(SFKeySelectHold), @"menuhold": @(SFKeyMenuHold),
                            @"next": @(SFKeyNext), @"prev": @(SFKeyPrev), @"uphold": @(SFKeyUpHold), @"downhold": @(SFKeyDownHold)};
        NSNumber *k = m[arg.lowercaseString];
        if (k) [self.nav sendKey:k.integerValue];
        else SFLog(@"dev: unknown key %@ (one of: %@)", arg, [m.allKeys componentsJoinedByString:@", "]);
    } else if ([cmd isEqualToString:@"shot"] && arg) {
        [self screenshot:arg];
    } else if ([cmd isEqualToString:@"mpvset"] && arg) {   // dev: set an mpv property, e.g. "mpvset vid no" (tests self-healing)
        id eng = [self topPlayer].engineForDiagnostics;
        NSArray *kv = [arg componentsSeparatedByString:@" "];
        if ([eng isKindOfClass:[SFMPVEngine class]] && kv.count == 2) [(SFMPVEngine *)eng setProp:kv[0] value:kv[1]];
    } else if ([cmd isEqualToString:@"mpvprop"] && arg) {   // Dev: log mpv properties, e.g. mpvprop time-pos,sub-start,sub-text
        id eng = [self topPlayer].engineForDiagnostics;
        if ([eng isKindOfClass:[SFMPVEngine class]])
            for (NSString *k in [arg componentsSeparatedByString:@","]) SFLog(@"dev: mpv %@ = %@", k, [(SFMPVEngine *)eng prop:k]);
    } else if ([cmd isEqualToString:@"endscreen"] && arg) {   // Dev: fake YouTube end screen on the running video: endscreen <json array>|off
        id j = [arg isEqualToString:@"off"] ? nil : [NSJSONSerialization JSONObjectWithData:[arg dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (j && ![j isKindOfClass:[NSArray class]]) { SFLog(@"dev: endscreen needs a JSON array"); return; }
        [[self topPlayer] devSetEndscreen:j];
    } else if ([cmd isEqualToString:@"frameshot"] && arg) {   // Dev: real mpv frame from the GL framebuffer
        SFMPVDevFrameShot(arg);
    } else if ([cmd isEqualToString:@"home"]) {
        [self.nav popToRoot];
    } else if ([cmd isEqualToString:@"play"] && [arg rangeOfString:@":"].location != NSNotFound) {   // Dev: Mediathek video by resolver ref (orf:…, ard:…, zdf:…)
        SFItem *it = [SFItem new];
        it.kind = SFItemVideo; it.identifier = arg; it.title = arg;
        if ([arg hasPrefix:@"http"]) it.playURL = [NSURL URLWithString:arg];   // direct URL: test the fallback chain
        else if ([arg hasPrefix:@"/"]) {   // "/file.mp4|orf:…": like a download with an online counterpart
            NSArray *pt = [arg componentsSeparatedByString:@"|"];
            it.localPath = pt[0]; it.playURL = [NSURL fileURLWithPath:pt[0]];
            if (pt.count > 1) { it.resolverRef = pt[1]; it.identifier = pt[1]; }
        } else {
            it.resolverRef = arg;
            SFItem *dl = [[SFDownloads shared] itemFor:arg];   // downloaded: with its metadata, as from the Downloads page
            if (dl) it = dl;
        }
        SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:it queue:nil index:0];
        ps.startFromBeginning = YES;
        [self presentPlayer:ps];
    } else if ([cmd isEqualToString:@"playlist"] && arg) {   // Dev: local files as a playlist ("/a.mp4,/b.mp4,…"), starts at the 2nd
        NSMutableArray *q = [NSMutableArray new];
        for (NSString *path in [arg componentsSeparatedByString:@","]) {
            SFItem *it = [SFItem new];
            it.kind = SFItemVideo; it.localPath = path; it.playURL = [NSURL fileURLWithPath:path];
            it.identifier = [@"devlist:" stringByAppendingString:path];
            it.title = [NSString stringWithFormat:@"Testvideo %lu", (unsigned long)q.count + 1];
            it.channel = @"Sofa Dev"; it.playlistID = @"devlist"; it.style = SFTileStyleLandscape;
            [q addObject:it];
        }
        if (!q.count) return;
        NSUInteger start = MIN((NSUInteger)1, q.count - 1);
        SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:q[start] queue:q index:start];
        ps.startFromBeginning = YES;
        [self presentPlayer:ps];
    } else if ([cmd isEqualToString:@"open"] && [arg isEqualToString:@"room"]) {      // Dev: "Platz schaffen"
        SFOpenItem(self.nav, [SFLibraryPages roomTile], nil, 0);
    } else if ([cmd isEqualToString:@"open"] && [arg isEqualToString:@"downloads"]) {
        SFOpenItem(self.nav, [SFLibraryPages downloadsTile:nil], nil, 0);
    } else if ([cmd isEqualToString:@"dlreserve"] && arg) {   // Dev: disk reserve in GB (provoke a full disk)
        [[SFDownloads shared] setStorageReserveForTesting:(unsigned long long)(arg.doubleValue * 1e9)];
    } else if ([cmd isEqualToString:@"open"] && [arg isEqualToString:@"history"]) {
        SFItem *h = [SFLibraryPages historyTile]; SFOpenItem(self.nav, h, nil, 0);
    } else if ([cmd isEqualToString:@"open"] && [arg hasPrefix:@"app:"]) {   // Dev/screenshots: app page
        [self.nav push:[SFHome appScreen:[arg substringFromIndex:4]]];
    } else if ([cmd isEqualToString:@"open"] && [arg isEqualToString:@"settings"]) {
        [SFHome showSettingsOn:self.nav];
    } else if ([cmd isEqualToString:@"open"] && [arg isEqualToString:@"welcome"]) {   // first-run setup from the welcome screen
        setenv("SOFA_WELCOME", "1", 1); [self welcomeIfFirstRun];
    } else if ([cmd isEqualToString:@"dlverify"] && arg) {   // Dev: run the download verifier on a file
        NSString *path = arg;
        SFBackground(^{
            NSString *p = [SFDownloads problemWithFile:path expectedDuration:0 ffmpeg:[SFDownloads ffmpegToolPath]];
            SFLog(@"dev: dlverify %@ -> %@", path.lastPathComponent, p ?: @"ok");
        });
    } else if ([cmd isEqualToString:@"proctest"]) {          // Dev: SFRunProcess timeout path (sleep 30 with 1 s limit)
        SFBackground(^{
            NSDate *t0 = [NSDate date];
            int st = SFRunProcess(@"/bin/sleep", @[@"30"], 1, NO, NULL);
            SFLog(@"dev: proctest status %d after %.1f s", st, -[t0 timeIntervalSinceNow]);
        });
    } else if ([cmd isEqualToString:@"dlget"] && arg) {     // Dev: download a resolver ref (orf:…) like the context menu
        SFItem *it = [SFItem new];
        it.kind = SFItemVideo; it.identifier = arg; it.resolverRef = arg; it.title = arg; it.source = @"dev"; it.channel = @"Dev";
        [[SFDownloads shared] download:it];
    } else if ([cmd isEqualToString:@"stats"]) {            // Dev: usage counters of the last <days> days (default 30)
        NSInteger days = arg.integerValue > 0 ? arg.integerValue : 30;
        [SFStatsTotals(days) enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSNumber *n, BOOL *stop) { SFLog(@"stats: %@ = %@", k, n); }];
        SFLog(@"stats: end (%ld days)", (long)days);
    } else if ([cmd isEqualToString:@"dlretry"]) {          // Dev: let every pending repair's backoff expire, retry now
        [[SFDownloads shared] expireRepairBackoffForTesting];
        [[SFDownloads shared] retryDueRepairs];
    } else if ([cmd isEqualToString:@"homerows"]) {          // Dev: the mixed Home rows as Home shows them (ids per topic)
        for (NSString *t in [SFHomeFeatures topics]) {
            NSMutableArray *ids = [NSMutableArray new];
            for (SFItem *i in [[SFHomeFeatures shared] itemsForTopic:t]) [ids addObject:[NSString stringWithFormat:@"%@/%@/%@", i.identifier ?: @"?", i.badge ?: @"-", [i broadcastAt:[NSDate date]].title ?: @"-"]];
            SFLog(@"dev: homerows %@ = %@", t, [ids componentsJoinedByString:@" "]);
        }
    } else if ([cmd isEqualToString:@"screens"] && arg) {    // Dev: "screens sleep|wake" - as if the display slept / woke up
        [[[NSWorkspace sharedWorkspace] notificationCenter] postNotificationName:[arg isEqualToString:@"sleep"]
            ? NSWorkspaceScreensDidSleepNotification : NSWorkspaceScreensDidWakeNotification object:nil];
    } else if ([cmd isEqualToString:@"follows"]) {           // Dev: each follow's tile picture and whether it needs a new one
        for (SFItem *f in [[SFFollows shared] follows:nil])
            SFLog(@"dev: follows %@ image=%@ needs=%d", f.identifier, f.image ?: @"-", [[SFFollows shared] needsImage:f.identifier]);
        SFLog(@"dev: follows end");
    } else if ([cmd isEqualToString:@"region"] && arg) {     // Dev: "region XX 0|1|-" - pretend a geo check found the device outside/inside XX; - = forget
        NSArray *a = [arg componentsSeparatedByString:@" "];
        if (a.count == 2 && [a[1] isEqualToString:@"-"]) [[SFStore shared] setSetting:nil forKey:[@"geo.region." stringByAppendingString:a[0]]];
        else if (a.count == 2) [SFNet noteRegion:a[0] inside:[a[1] boolValue]];
        SFLog(@"dev: region %@ done", arg);
    } else if ([cmd isEqualToString:@"shelves"] && arg) {   // Dev: an app's start page shelves (title, count, kinds) - content survey
        Class<SFApp> app = [SFAppRegistry appNamed:arg];
        if (!app) { SFLog(@"dev: shelves: no app %@", arg); return; }
        [app homeLoader](^(SFPage *p, NSError *e) {
            for (SFShelf *sh in p.shelves) {
                NSCountedSet *kinds = [NSCountedSet new];
                for (SFItem *i in sh.items) [kinds addObject:@(i.kind)];
                SFItem *f = sh.items.firstObject;
                SFLog(@"dev: shelves %@ | %@ | %lu items | kinds video=%lu live=%lu folder=%lu action=%lu | first: %@ (%@)", arg, sh.title ?: @"-", (unsigned long)sh.items.count,
                      (unsigned long)[kinds countForObject:@(SFItemVideo)], (unsigned long)[kinds countForObject:@(SFItemLive)],
                      (unsigned long)[kinds countForObject:@(SFItemFolder)], (unsigned long)[kinds countForObject:@(SFItemAction)], f.title, f.identifier);
            }
            SFLog(@"dev: shelves %@ end%@", arg, e ? [@" " stringByAppendingString:e.localizedDescription] : @"");
        });
    } else if ([cmd isEqualToString:@"quit"]) {
        [NSApp terminate:nil];
    }
}

- (void)screenshot:(NSString *)path {
    // Wait briefly so running animations/image loads have finished.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Render the layer tree straight into a bitmap (independent of the window server,
        // works for the offscreen window; video layers stay black).
        CALayer *root = self.nav.layer;
        CGSize sz = root.bounds.size;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)sz.width, (size_t)sz.height, 8, 0, cs,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
        CGColorSpaceRelease(cs);
        CGContextTranslateCTM(ctx, 0, sz.height);
        CGContextScaleCTM(ctx, 1, -1);
        SFRenderLayerTree(root, ctx);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        if (!img) { SFLog(@"dev: screenshot failed"); return; }
        CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
        if (!d) { SFLog(@"dev: shot path invalid %@", path); CGImageRelease(img); return; }
        CGImageDestinationAddImage(d, img, NULL);
        CGImageDestinationFinalize(d);
        CFRelease(d); CGImageRelease(img);
        SFLog(@"dev: shot written %@", path);
    });
}

@end
