#import "SFCCCApp.h"
#import "SFJSON.h"
#import "SFNet.h"
#import "SFStore.h"

static NSString *const kAPI = @"https://api.media.ccc.de/public";

@implementation SFCCCApp

static NSDate *parseDate(NSString *s) { return SFDateFromISO8601(s); }   // offset honoured (SFCore)


+ (SFItem *)eventItem:(NSDictionary *)e {
    SFItem *i = [SFItem new];
    i.kind = SFItemVideo;
    i.identifier = [@"ccc:" stringByAppendingString:e[@"guid"]];
    i.resolverRef = i.identifier;
    i.title = nn(e[@"title"]);
    i.channel = nn(e[@"conference_title"]);
    NSArray *persons = nn(e[@"persons"]);
    NSString *who = [persons isKindOfClass:[NSArray class]] ? [persons componentsJoinedByString:@", "] : nil;
    i.date = parseDate(nn(e[@"date"]) ?: nn(e[@"release_date"]));
    i.subtitle = who.length ? who : SFFormatDateShort(i.date);
    NSString *sub = nn(e[@"subtitle"]);
    NSString *desc = nn(e[@"description"]);
    i.plot = sub.length ? [NSString stringWithFormat:@"%@\n%@", sub, desc ?: @""] : desc;
    i.image = nn(e[@"poster_url"]) ?: nn(e[@"thumb_url"]);
    i.backdrop = i.image;
    i.duration = [nn(e[@"length"]) doubleValue];
    i.source = @"ccc";
    i.style = SFTileStyleLandscape;
    return i;
}

+ (NSArray *)eventItems:(NSArray *)events {
    NSMutableArray *a = [NSMutableArray new];
    for (NSDictionary *e in arr(events)) if (dict(e) && str(e[@"guid"])) [a addObject:[self eventItem:e]];
    return a;
}

+ (SFItem *)conferenceItem:(NSDictionary *)c {
    SFItem *i = [SFItem new];
    i.kind = SFItemFolder;
    i.identifier = [@"cccconf:" stringByAppendingString:c[@"acronym"]];
    i.title = nn(c[@"title"]);
    NSString *logo = nn(c[@"logo_url"]);
    i.image = logo;   // SVG logos are rasterized by the image cache via rsvg-convert
    i.imageFit = YES;
    i.date = parseDate(nn(c[@"event_last_released_at"]));
    i.subtitle = SFFormatDateShort(i.date);
    i.themeName = @"ccc";
    i.source = @"ccc";
    NSString *acr = c[@"acronym"];
    NSString *title = i.title;
    i.pageLoader = ^(SFPageDone done) {
        [SFNet getJSON:[NSString stringWithFormat:@"%@/conferences/%@", kAPI, acr] headers:nil cacheAge:3600 done:^(id j, NSError *e) {
            if (!j) { done(nil, e); return; }
            NSArray *evs = [[self eventItems:dict(j)[@"events"]] sortedArrayUsingComparator:^NSComparisonResult(SFItem *a, SFItem *b) {
                return [b.date ?: [NSDate distantPast] compare:a.date ?: [NSDate distantPast]];
            }];
            NSString *d = nn(j[@"description"]);
            SFPage *p = [SFPage page:title theme:@"ccc" shelves:@[[SFShelf grid:[NSString stringWithFormat:@"%lu Vorträge", (unsigned long)evs.count] style:SFTileStyleLandscape items:evs]]];
            p.subtitle = d;
            done(p, nil);
        }];
    };
    return i;
}

#pragma mark SFApp

+ (NSString *)appIdentifier { return @"ccc"; }
+ (NSString *)appName { return @"media.ccc.de"; }
+ (NSString *)appSummary { return @"Vorträge vom Chaos Computer Club"; }
+ (NSArray *)refPrefixes { return @[@"ccc", @"cccconf"]; }
+ (NSColor *)homeTileColor { return SFHex(0x0b0d0b); }
+ (NSInteger)homeTileLogoVariant { return 1; }
+ (NSString *)searchPlaceholder { return @"Vorträge suchen"; }
+ (void)configureTheme:(SFTheme *)t {
    // Terminal aesthetic: black, mono headings, green.
    t.wordmark = @"media.ccc.de"; t.logo = @"ccc"; t.logoVariant = 1;
    t.background = SFHex(0x0a0b0a);
    t.backgroundTop = SFHex(0x141a14);
    t.surface = SFHex(0x1b211b);
    t.text = SFHex(0xe8f0e8);
    t.textDim = SFHexA(0xb8d8b8, 0.65);
    t.accent = SFHex(0x36d66b);
    t.accentText = SFHex(0x041004);
    t.focus = SFHex(0x36d66b);
    t.fontWordmark = @"Menlo-Bold";
    t.fontBold = @"Menlo-Bold";
    t.corner = 2;
    t.uppercaseHeaders = NO;
}

+ (void)resolve:(NSString *)ref done:(SFURLDone)done {
    NSString *guid = SFRefID(ref);
    [SFNet getJSON:[NSString stringWithFormat:@"%@/events/%@", kAPI, guid] headers:nil cacheAge:600 done:^(id j, NSError *e) {
        if (!dict(j)) { done(nil, e ?: SFError(@"Vortrag nicht gefunden.")); return; }
        NSString *orig = nn(j[@"original_language"]);
        NSDictionary *best = nil; int bestScore = -1;
        for (NSDictionary *r in arr(dict(j)[@"recordings"])) {
            if (!dict(r)) continue;
            if (![nn(r[@"mime_type"]) isEqualToString:@"video/mp4"]) continue;
            int sc = 0;
            if ([nn(r[@"high_quality"]) boolValue]) sc += 4;
            NSString *lang = nn(r[@"language"]);
            if (orig && [lang isEqualToString:orig]) sc += 2;      // original audio, one language
            else if (orig && [lang hasPrefix:orig]) sc += 1;
            if (sc > bestScore) { bestScore = sc; best = r; }
        }
        NSString *u = nn(best[@"recording_url"]);
        done(u ? [NSURL URLWithString:u] : nil, u ? nil : SFError(@"Keine abspielbare Aufzeichnung."));
    }];
}

// /events/search?q= (relevance, 25 per page): two pages
+ (SFPageLoader)searchLoader:(NSString *)query {
    return ^(SFPageDone done) {
        NSString *base = [NSString stringWithFormat:@"%@/events/search?q=%@", kAPI, [SFNet escape:query]];
        __block id p1 = nil, p2 = nil;
        __block NSError *err = nil;
        dispatch_group_t g = dispatch_group_create();
        dispatch_group_enter(g);
        [SFNet getJSON:base headers:nil cacheAge:1800 done:^(id j, NSError *e) { p1 = j; err = e; dispatch_group_leave(g); }];
        dispatch_group_enter(g);
        [SFNet getJSON:[base stringByAppendingString:@"&page=2"] headers:nil cacheAge:1800 done:^(id j, NSError *e) { p2 = j; dispatch_group_leave(g); }];
        dispatch_group_notify(g, dispatch_get_main_queue(), ^{
            if (!p1) { done(nil, err ?: SFError(@"media.ccc.de ist nicht erreichbar.")); return; }
            NSMutableArray *items = [NSMutableArray new];
            NSMutableSet *seen = [NSMutableSet new];
            for (SFItem *i in [[self eventItems:dict(p1)[@"events"]] arrayByAddingObjectsFromArray:[self eventItems:dict(p2)[@"events"]]])
                if (![seen containsObject:i.identifier]) { [seen addObject:i.identifier]; i.themeName = @"ccc"; [items addObject:i]; }
            // The API searches fuzzily (gpn -> GPU, GPS, GPL): whole-word hits first, otherwise API order
            NSString *pat = [NSString stringWithFormat:@"(^|[^\\p{L}\\p{N}])%@($|[^\\p{L}\\p{N}])", [NSRegularExpression escapedPatternForString:query]];
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:NSRegularExpressionCaseInsensitive error:nil];
            NSInteger (^score)(SFItem *) = ^NSInteger(SFItem *i) {
                BOOL (^hit)(NSString *) = ^BOOL(NSString *s) { return s.length && [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] != nil; };
                if (hit(i.title)) return 3;
                if (hit(i.channel) || hit(i.subtitle)) return 2;
                if (hit(i.plot)) return 1;
                return 0;
            };
            NSMutableArray *ranked = [NSMutableArray new];
            for (NSInteger s = 3; s >= 0; s--) for (SFItem *i in items) if (score(i) == s) [ranked addObject:i];
            items = ranked;
            SFPage *p = [SFPage page:[NSString stringWithFormat:@"„%@“", query] theme:@"ccc"
                             shelves:items.count ? @[[SFShelf grid:@"Vorträge" style:SFTileStyleLandscape items:items]] : @[]];
            if (!items.count) p.emptyText = [NSString stringWithFormat:@"Keine Treffer für „%@“.", query];
            done(p, nil);
        });
    };
}

+ (SFPageLoader)homeLoader {
    return ^(SFPageDone done) {
        dispatch_group_t g = dispatch_group_create();
        __block id recent, popular, confs;
        NSInteger year = [[NSCalendar currentCalendar] component:NSCalendarUnitYear fromDate:[NSDate date]];
        dispatch_group_enter(g);
        [SFNet getJSON:[kAPI stringByAppendingString:@"/events/recent"] headers:nil cacheAge:1800 done:^(id j, NSError *e) { recent = j; dispatch_group_leave(g); }];
        dispatch_group_enter(g);
        [SFNet getJSON:[NSString stringWithFormat:@"%@/events/popular?year=%ld", kAPI, (long)year] headers:nil cacheAge:6 * 3600 done:^(id j, NSError *e) { popular = j; dispatch_group_leave(g); }];
        dispatch_group_enter(g);
        [SFNet getJSON:[kAPI stringByAppendingString:@"/conferences"] headers:nil cacheAge:6 * 3600 done:^(id j, NSError *e) { confs = j; dispatch_group_leave(g); }];
        dispatch_group_notify(g, dispatch_get_main_queue(), ^{
            if (!recent && !popular && !confs) { done(nil, SFError(@"media.ccc.de ist nicht erreichbar.")); return; }
            NSMutableArray *shelves = [NSMutableArray new];
            NSArray *cont = [[SFStore shared] continueWatching:20 source:@"ccc"];
            if (cont.count) [shelves addObject:[SFShelf shelf:@"Weiterschauen" style:SFTileStyleLandscape items:cont]];
            NSArray *r = [self eventItems:dict(recent)[@"events"]];
            if (r.count) [shelves addObject:[SFShelf shelf:@"Neu veröffentlicht" style:SFTileStyleLandscape items:r]];
            NSArray *p = [self eventItems:dict(popular)[@"events"]];
            if (p.count) [shelves addObject:[SFShelf shelf:[NSString stringWithFormat:@"Beliebt %ld", (long)year] style:SFTileStyleLandscape items:p]];
            NSMutableArray *cs = [NSMutableArray new];
            NSMutableArray *valid = [NSMutableArray new];
            for (id c in arr(dict(confs)[@"conferences"])) if (dict(c) && str(c[@"acronym"])) [valid addObject:c];
            NSArray *sorted = [valid sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [str(b[@"event_last_released_at"]) ?: @"" compare:str(a[@"event_last_released_at"]) ?: @""];
            }];
            for (NSDictionary *c in sorted) [cs addObject:[self conferenceItem:c]];
            // highlight the Congress series
            NSArray *congress = [cs filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SFItem *i, NSDictionary *b) {
                return i.title && [i.identifier rangeOfString:@"c3" options:NSAnchoredSearch | NSBackwardsSearch].location != NSNotFound && [i.title rangeOfString:@"C3"].location != NSNotFound;
            }]];
            if (congress.count) [shelves addObject:[SFShelf shelf:@"Chaos Communication Congress" style:SFTileStyleWide items:congress]];
            if (cs.count) [shelves addObject:[SFShelf grid:@"Alle Konferenzen" style:SFTileStyleWide items:cs]];
            done([SFPage page:nil theme:@"ccc" shelves:shelves], nil);
        });
    };
}
@end
