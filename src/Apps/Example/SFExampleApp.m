#import "SFExampleApp.h"

// --- the "API client": a static catalogue (a real app maps its source's JSON to SFItems) ---

static NSArray *catalogue(void) {
    return @[@[@"1", @"Testbild", @"testsrc2"], @[@"2", @"Farbbalken", @"smptehdbars"],
             @[@"3", @"Mandelbrot", @"mandelbrot"], @[@"4", @"Leben", @"life=mold=10:ratio=0.1:death_color=#202020:life_color=#40c0ff"]];
}

static SFItem *video(NSArray *entry) {
    SFItem *i = [SFItem new];
    i.kind = SFItemVideo;
    i.identifier = [@"example:" stringByAppendingString:entry[0]];   // the ref: namespace "example" -> this app
    i.resolverRef = i.identifier;
    i.title = entry[1];
    i.channel = @"Beispielsendung";
    i.showRef = @"exampleshow:demo";        // "Zur Sendung" + follow
    i.duration = 60;
    i.source = [SFExampleApp appIdentifier];
    i.themeName = i.source;
    i.style = SFTileStyleLandscape;
    i.plot = @"Ein Video der Beispiel-App – Vorlage für neue Apps (docs/new-app.md).";
    return i;
}

static NSArray *videos(NSString *filter) {
    NSMutableArray *r = [NSMutableArray new];
    for (NSArray *e in catalogue())
        if (!filter.length || [e[1] rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound) [r addObject:video(e)];
    return r;
}

@implementation SFExampleApp

#pragma mark Identity (required)

+ (NSString *)appIdentifier { return @"example"; }
+ (NSString *)appName { return @"Beispiel"; }
+ (NSString *)appSummary { return @"Vorlage für neue Apps"; }
+ (NSArray *)refPrefixes { return @[@"example", @"exampleshow"]; }
+ (NSArray *)showRefPrefixes { return @[@"exampleshow"]; }
+ (NSColor *)homeTileColor { return SFHex(0x5b3fa8); }
+ (NSInteger)homeTileLogoVariant { return 0; }

+ (void)configureTheme:(SFTheme *)t {
    t.wordmark = @"Beispiel";   // no logo file: wordmark + header mark
    t.background = SFHex(0x120d1f);
    t.backgroundTop = SFHex(0x2a1f4a);
    t.accent = SFHex(0xa68bff);
    t.accentText = SFHex(0x120d1f);
    t.focus = SFHex(0xa68bff);
    t.headerMark = SFHeaderMarkDot;
}

#pragma mark Start page (required): only the app's own shelves; the shell adds the shared ones

+ (SFPageLoader)homeLoader {
    return ^(SFPageDone done) {
        SFItem *show = [SFItem new];
        show.kind = SFItemFolder; show.identifier = @"exampleshow:demo"; show.title = @"Beispielsendung";
        show.source = [self appIdentifier]; show.themeName = show.source; show.style = SFTileStyleWide;
        show.pageLoader = [self showPageLoader:show.identifier title:show.title];
        done([SFPage page:nil theme:[self appIdentifier] shelves:@[
            [SFShelf shelf:@"Neu" style:SFTileStyleLandscape items:videos(nil)],
            [SFShelf shelf:@"Sendungen" style:SFTileStyleWide items:@[show]]]], nil);
    };
}

#pragma mark Capabilities (optional)

+ (SFPageLoader)searchLoader:(NSString *)query {
    return ^(SFPageDone done) {
        NSArray *r = videos(query);
        SFPage *p = [SFPage page:query theme:[self appIdentifier] shelves:r.count ? @[[SFShelf grid:@"Videos" style:SFTileStyleLandscape items:r]] : @[]];
        if (!r.count) p.emptyText = @"Nichts gefunden.";
        done(p, nil);
    };
}

+ (void)resolve:(NSString *)ref done:(SFURLDone)done {
    for (NSArray *e in catalogue())
        if ([e[0] isEqualToString:SFRefID(ref)]) {   // mpv test pattern, 60 s
            NSString *u = [NSString stringWithFormat:@"av://lavfi:%@,trim=duration=60", e[2]];
            done([NSURL URLWithString:[u stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]], nil);
            return;
        }
    done(nil, SFError(@"Video nicht gefunden"));
}

+ (SFPageLoader)showPageLoader:(NSString *)ref title:(NSString *)title {
    return ^(SFPageDone done) {
        done([SFPage page:title ?: @"Beispielsendung" theme:[self appIdentifier]
                  shelves:@[[SFShelf grid:@"Folgen" style:SFTileStyleLandscape items:videos(nil)]]], nil);
    };
}

+ (void)feed:(NSString *)ref done:(void (^)(NSArray *, NSError *))done { done(videos(nil), nil); }

// Home rows mixed from all apps (SFHomeFeatures.h): items per topic. A real app reads them from its
// start page (SFHomeFeaturesFromPage) and sets `drm` / `geoRegion` from the source's raw data -
// Home then leaves out what can't play here. The three channels exercise exactly that (tools/test-home).
+ (void)homeFeatures:(void (^)(NSDictionary *))done {
    NSMutableArray *live = [NSMutableArray new];
    for (NSArray *e in @[@[@"live1", @"Testkanal", @""], @[@"live2", @"Testkanal DRM", @"drm"], @[@"live3", @"Testkanal XX", @"XX"]]) {
        SFItem *i = video(@[e[0], e[1], @""]);
        i.kind = SFItemLive; i.badge = @"LIVE"; i.duration = 0; i.showRef = nil;
        i.drm = [e[2] isEqualToString:@"drm"];
        if ([e[2] length] == 2) i.geoRegion = e[2];   // only playable in country XX
        [live addObject:i];
    }
    done(@{SFHomeTopicLive: live, SFHomeTopicHighlights: [videos(nil) subarrayWithRange:NSMakeRange(0, 2)]});
}

@end
