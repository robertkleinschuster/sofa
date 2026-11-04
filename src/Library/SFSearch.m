#import "SFSearch.h"
#import "SFIconArt.h"
#import "SFKeyboardScreen.h"
#import "SFBrowseScreen.h"
#import "SFStore.h"
#import "SFYouTube.h"
#import "SFProviderZDF.h"
#import "SFProviderARD.h"
#import "SFProviderORF.h"
#import "SFProviderCCC.h"

static const NSUInteger kMaxRecent = 12;

static SFPageLoader searchLoader(NSString *source, NSString *q) {
    if ([source isEqualToString:@"youtube"]) return [SFYouTube searchLoader:q];
    if ([source isEqualToString:@"zdf"]) return [SFProviderZDF searchLoader:q];
    if ([source isEqualToString:@"ard"]) return [SFProviderARD searchLoader:q];
    if ([source isEqualToString:@"orf"]) return [SFProviderORF searchLoader:q];
    if ([source isEqualToString:@"ccc"]) return [SFProviderCCC searchLoader:q];
    return nil;
}

static NSString *placeholder(NSString *source) {
    if ([source isEqualToString:@"youtube"]) return @"Videos und Kanäle suchen";
    if ([source isEqualToString:@"ccc"]) return @"Vorträge suchen";
    return @"Sendungen und Videos suchen";
}

#pragma mark Zuletzt gesucht

static NSString *recentKey(NSString *source) { return [@"search.recent." stringByAppendingString:source ?: @"all"]; }

NSArray *SFRecentSearches(NSString *source) {
    NSString *s = [[SFStore shared] setting:recentKey(source)];
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    id a = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}

void SFAddRecentSearch(NSString *source, NSString *query) {
    if (!query.length) return;
    NSMutableArray *a = [NSMutableArray arrayWithObject:query];
    for (NSString *r in SFRecentSearches(source)) {
        if (![r isKindOfClass:[NSString class]] || [r caseInsensitiveCompare:query] == NSOrderedSame) continue;
        if (a.count >= kMaxRecent) break;
        [a addObject:r];
    }
    NSData *d = [NSJSONSerialization dataWithJSONObject:a options:0 error:nil];
    [[SFStore shared] setSetting:[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] forKey:recentKey(source)];
}

#pragma mark Vorschläge

// Leer: zuletzt gesucht. Mit Text: passende frühere Suchen, bei YouTube + Autovervollständigung.
static SFSuggestProvider suggestions(NSString *source) {
    return ^(NSString *text, SFSuggestDone done) {
        NSArray *recent = SFRecentSearches(source);
        NSString *q = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!q.length) { done(@"Zuletzt gesucht", recent); return; }
        NSMutableArray *mine = [NSMutableArray new];
        for (NSString *r in recent)
            if ([r rangeOfString:q options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound && ![r isEqualToString:q]) [mine addObject:r];
        if (![source isEqualToString:@"youtube"]) {
            // Mediatheken: Titel der ersten Treffer als Vorschläge (Sendungen zuerst) – man sieht beim
            // Tippen, wann es reicht. Ab 2 Zeichen; die Suchanfragen sind gecacht.
            if (q.length < 2) { done(@"Zuletzt gesucht", mine); return; }
            SFPageLoader l = searchLoader(source, q);
            if (!l) { done(@"Zuletzt gesucht", mine); return; }
            l(^(SFPage *page, NSError *e) {
                NSMutableArray *all = [[mine subarrayWithRange:NSMakeRange(0, MIN(mine.count, (NSUInteger)2))] mutableCopy];
                NSMutableArray *folders = [NSMutableArray new], *videos = [NSMutableArray new];
                for (SFShelf *sh in page.shelves) for (SFItem *i in sh.items) {
                    if (!i.title.length || [i.identifier hasPrefix:@"search:"]) continue;
                    [(i.kind == SFItemFolder ? folders : videos) addObject:i.title];
                }
                for (NSString *s in [folders arrayByAddingObjectsFromArray:videos]) {
                    BOOL dup = NO;
                    for (NSString *x in all) if ([x caseInsensitiveCompare:s] == NSOrderedSame) dup = YES;
                    if (!dup) [all addObject:s];
                    if (all.count >= 6) break;
                }
                NSUInteger fromRecent = MIN(mine.count, (NSUInteger)2);
                if (all.count == fromRecent) { done(@"Zuletzt gesucht", mine); return; }   // keine Treffer (z. B. offline): alle eigenen
                done(@"Vorschläge", all);
            });
            return;
        }
        [SFYouTube suggestions:q done:^(NSArray *list) {
            NSMutableArray *all = [[mine subarrayWithRange:NSMakeRange(0, MIN(mine.count, (NSUInteger)2))] mutableCopy];
            for (NSString *s in list) {
                BOOL dup = NO;
                for (NSString *x in all) if ([x caseInsensitiveCompare:s] == NSOrderedSame) dup = YES;
                if (!dup && [s caseInsensitiveCompare:q] != NSOrderedSame) [all addObject:s];
            }
            done(@"Vorschläge", all);
        }];
    };
}

#pragma mark Ablauf

void SFOpenSearch(SFNavigator *nav, NSString *source, NSString *initialText) {
    if (!nav) return;
    SFTheme *t = [SFTheme themeNamed:source];
    __weak SFNavigator *wnav = nav;
    SFKeyboardScreen *kb = [[SFKeyboardScreen alloc] initWithTitle:@"Suche" theme:t initialText:initialText completion:^(NSString *q) {
        SFPageLoader l = searchLoader(source, q);
        if (!l) return;
        SFAddRecentSearch(source, q);
        SFLog(@"search: %@ „%@“", source, q);
        // Ergebnisse über die Tastatur legen: MENU kehrt zum Suchbegriff zurück
        SFBrowseScreen *b = [[SFBrowseScreen alloc] initWithLoader:l theme:t];
        [wnav push:b];
    }];
    kb.placeholder = placeholder(source);
    kb.suggestionProvider = suggestions(source);
    [nav push:kb];
}

static SFNavigator *appNavigator(void) {
    id d = [NSApp delegate];
    return [d respondsToSelector:@selector(nav)] ? [d performSelector:@selector(nav)] : nil;
}

BOOL SFHasSearch(NSString *source) { return searchLoader(source, @"") != nil; }

SFItem *SFSearchTile(NSString *source) {
    SFTheme *t = [SFTheme themeNamed:source];
    SFItem *i = [SFItem new];
    i.kind = SFItemAction;
    i.identifier = [@"search:" stringByAppendingString:source];
    i.title = @"Suche";
    i.subtitle = placeholder(source);
    i.plot = @"Mit der Bildschirmtastatur suchen. Zuletzt gesuchte Begriffe stehen gleich rechts daneben.";
    i.tint = t.accent;
    i.image = SFIconArt(@"search", source);
    i.style = SFTileStyleWide;
    i.source = source; i.themeName = source;
    i.action = ^{ SFOpenSearch(appNavigator(), source, nil); };
    return i;
}

SFPageLoader SFWithSearchTile(SFPageLoader loader, NSString *source) {
    if (!searchLoader(source, @"")) return loader;
    return ^(SFPageDone done) {
        loader(^(SFPage *page, NSError *err) {
            if (!page) { done(page, err); return; }
            NSMutableArray *shelves = [page.shelves mutableCopy] ?: [NSMutableArray new];
            SFItem *tile = SFSearchTile(source);
            for (NSString *title in @[@"Mehr", @"Entdecken", @"Kategorien"]) {
                for (NSUInteger k = 0; k < shelves.count; k++) {
                    SFShelf *s = shelves[k];
                    if (![s.title isEqualToString:title] || s.layout != SFShelfRail) continue;
                    tile.style = s.style;
                    s.items = [@[tile] arrayByAddingObjectsFromArray:s.items ?: @[]];
                    page.shelves = shelves;
                    done(page, err);
                    return;
                }
            }
            [shelves insertObject:[SFShelf shelf:nil style:SFTileStyleWide items:@[tile]] atIndex:MIN((NSUInteger)1, shelves.count)];
            page.shelves = shelves;
            done(page, err);
        });
    };
}
