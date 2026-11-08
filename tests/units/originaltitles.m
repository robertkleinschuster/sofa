// sources: src/Core/SFStore.m src/Core/SFStore+Schema.m src/Core/SFModel.m
// flags: -I/opt/local/include -L/opt/local/lib -lsqlite3
// Original titles (SFStore): the uploader's title, once known, wins over the localized one YouTube's
// lists carry - in every item write (progress, downloads, follows write list snapshots), in the item
// already stored, and across a relaunch (2026-11-08: English videos showed German list titles).
#import "../../src/Core/SFStore.h"
#import "../../src/Core/SFStore+Private.h"
#import "SFCore.h"
BOOL SFDevMode = YES;
// SFModel references the app registry (item -> app) - not on the paths tested here
@interface SFAppRegistry : NSObject @end
@implementation SFAppRegistry @end
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }

static SFItem *video(NSString *title) {
    SFItem *i = [SFItem new];
    i.kind = SFItemVideo; i.identifier = @"yt:84ne8PrfFMY"; i.title = title; i.source = @"youtube";
    return i;
}
static NSString *storedTitle(SFStore *s) {
    NSDictionary *r = [s rows:@"SELECT json_extract(json, '$.title') AS t FROM items WHERE id = 'yt:84ne8PrfFMY'" args:nil].firstObject;
    return r[@"t"];
}

int main(void) {
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sofa-unit-titles-%d", getpid()]];
        setenv("SOFA_DATA_DIR", dir.fileSystemRepresentation, 1);
        SFSetDevInstance(@"unit-titles");
        SFStore *s = [SFStore shared];
        NSString *localized = @"Einblicke in ein Haus aus reinem Beton an einer mexikanischen Klippe";
        NSString *original = @"This Is What $4,900,000 Gets You in Mexico";

        [s saveItem:video(localized)];
        expect([storedTitle(s) isEqualToString:localized], "unknown original: the list title is stored");
        expect([s originalTitleFor:@"yt:84ne8PrfFMY"] == nil, "no original before the watch page");

        [s setOriginalTitle:original forID:@"yt:84ne8PrfFMY"];
        expect([[s originalTitleFor:@"yt:84ne8PrfFMY"] isEqualToString:original], "original known at once");
        expect([storedTitle(s) isEqualToString:original], "the stored item takes the original");

        [s saveItem:video(localized)];   // e.g. a follow refresh or progress save with the list snapshot
        expect([storedTitle(s) isEqualToString:original], "a later write with the list title keeps the original");
        NSArray *w = [s itemWrite:video(localized)];
        expect([w[1][1] rangeOfString:@"$4,900,000"].location != NSNotFound, "itemWrite (runAll batches) writes the original too");

        NSDictionary *row = [s rows:@"SELECT title FROM original_titles WHERE id = 'yt:84ne8PrfFMY'" args:nil].firstObject;
        expect([row[@"title"] isEqualToString:original], "persisted (original_titles, read again at launch)");
        [s setOriginalTitle:@"" forID:@"yt:84ne8PrfFMY"];
        expect([[s originalTitleFor:@"yt:84ne8PrfFMY"] isEqualToString:original], "an empty title never replaces a known one");

        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    return bad ? 1 : 0;
}
