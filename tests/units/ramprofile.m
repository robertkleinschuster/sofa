// sources: src/Apps/YouTube/SFYTRamProfile.m src/Core/SFRuntime.m
// flags: -lsqlite3 -I/opt/local/include -L/opt/local/lib
// SFYTRamProfile (no RAM disk here: a directory stands in): the fill leaves caches out and keeps
// times; a sync writes back only what changed, a database consistently while another connection
// writes it (WAL, shared locking), removes a stale WAL next to the new copy, mirrors deletions,
// never touches the disk profile's caches, and does nothing for a RAM profile without prefs.js.
#import "../../src/Apps/YouTube/SFYTRamProfile.h"
#import "SFCore.h"
#include <sqlite3.h>
BOOL SFDevMode = NO;

static int fails;
static void expect(BOOL ok, NSString *what) { if (!ok) { fails++; printf("FAIL %s\n", what.UTF8String); } }
static NSString *root;
static NSString *P(NSString *rel) { return [root stringByAppendingPathComponent:rel]; }
static void put(NSString *rel, NSString *text) {
    [[NSFileManager defaultManager] createDirectoryAtPath:[P(rel) stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToFile:P(rel) atomically:NO encoding:NSUTF8StringEncoding error:nil];
}
static NSString *get(NSString *rel) { return [NSString stringWithContentsOfFile:P(rel) encoding:NSUTF8StringEncoding error:nil]; }
static BOOL exists(NSString *rel) { return [[NSFileManager defaultManager] fileExistsAtPath:P(rel)]; }
static int countRows(NSString *rel) {
    sqlite3 *db; int n = -1; sqlite3_stmt *st;
    if (sqlite3_open_v2(P(rel).fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return -1;
    if (sqlite3_prepare_v2(db, "SELECT count(*) FROM c", -1, &st, NULL) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int(st, 0);
    sqlite3_finalize(st); sqlite3_close(db);
    return n;
}

int main(void) {
    @autoreleasepool {
        root = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ramprofile-%d", getpid()]];
        put(@"disk/prefs.js", @"user_pref(1);");
        put(@"disk/storage/default/site/ls/data.json", @"local");
        put(@"disk/cache2/entries/AAA", @"media");
        put(@"disk/startupCache/x", @"cache");
        put(@"disk/old.txt", @"to be removed");
        put(@"disk/storage/default/site/cache/caches.sqlite", @"old cache db");
        put(@"disk/storage/default/site/cache/caches.sqlite-wal", @"its wal");
        put(@"disk/storage/default/site/cache/morgue/1/body.final", @"a body");
        sqlite3 *w;   // "Firefox": a database in WAL mode, open the whole time
        sqlite3_open(P(@"disk/cookies.sqlite").fileSystemRepresentation, &w);
        sqlite3_exec(w, "PRAGMA journal_mode=WAL; CREATE TABLE c(v); INSERT INTO c VALUES(1);", NULL, NULL, NULL);
        sqlite3_close(w);
        SFYTRamProfile *r = [[SFYTRamProfile alloc] initWithDiskProfile:P(@"disk") mountPoint:P(@"ram") sizeMB:16];
        r.testWithoutDisk = YES;
        expect([r existing] == nil, @"nothing mounted: no RAM profile");
        NSString *ram = [r attach];
        expect([ram isEqualToString:P(@"ram/profile")] && [[r existing] isEqualToString:ram], @"attached");
        expect([get(@"ram/profile/prefs.js") isEqual:@"user_pref(1);"] && exists(@"ram/profile/storage/default/site/ls/data.json"), @"filled");
        expect(!exists(@"ram/profile/cache2") && !exists(@"ram/profile/startupCache"), @"caches stay out of RAM");
        expect(!exists(@"ram/profile/storage/default/site/cache"), @"the Cache API store is not filled into RAM");
        expect([r syncToDisk] == 1 && !exists(@"disk/storage/default/site/cache") && exists(@"disk/storage/default/site/ls/data.json"),
               @"the stale Cache API store removed from the disk profile once (with its WAL), the rest kept");
        [r syncToDisk];   // files from the same second as that sync: compared by content once (HFS+ seconds)
        expect([r syncToDisk] == 0, @"nothing changed: nothing written");
        sleep(2);   // HFS+ keeps whole seconds: the changes below fall after the sync's second

        // "Firefox" runs on the RAM profile: writes, deletes, keeps its database open in WAL mode
        put(@"ram/profile/prefs.js", @"user_pref(2);");
        [[NSFileManager defaultManager] removeItemAtPath:P(@"ram/profile/old.txt") error:nil];
        sqlite3_open(P(@"ram/profile/cookies.sqlite").fileSystemRepresentation, &w);
        sqlite3_exec(w, "PRAGMA journal_mode=WAL; INSERT INTO c VALUES(2); INSERT INTO c VALUES(3);", NULL, NULL, NULL);
        put(@"disk/cookies.sqlite-wal", @"stale wal of the old disk copy");
        sleep(2);
        NSUInteger n = [r syncToDisk];
        expect(n >= 3, @"changed files and the removal synced");
        expect([get(@"disk/prefs.js") isEqual:@"user_pref(2);"], @"a changed file back on disk");
        expect(!exists(@"disk/old.txt"), @"removed from RAM: removed from disk");
        expect(!exists(@"disk/cookies.sqlite-wal"), @"the stale WAL removed before the new copy");
        expect(countRows(@"disk/cookies.sqlite") == 3, @"the database copied consistently while open (3 rows)");
        expect(exists(@"disk/cache2/entries/AAA") && exists(@"disk/startupCache/x"), @"the disk profile's caches untouched");
        sleep(2);
        expect([r syncToDisk] == 0, @"synced again without changes: nothing written");
        sleep(2);
        sqlite3_exec(w, "INSERT INTO c VALUES(4);", NULL, NULL, NULL);   // a change only in the WAL
        expect([r syncToDisk] == 1 && countRows(@"disk/cookies.sqlite") == 4, @"a change only in the WAL is seen");
        sqlite3_close(w);

        // a sync that ends half way (Sofa quit or crashed): prefs.js is replaced last, so the RAM profile
        // stays the one to use - its unchanged mark still matches the disk profile
        sleep(2);
        put(@"ram/profile/aaa.txt", @"new a");
        put(@"ram/profile/prefs.js", @"user_pref(9);");
        r.testStopAfter = 1;
        [r syncToDisk];
        r.testStopAfter = -1;
        expect([get(@"disk/prefs.js") isEqual:@"user_pref(2);"] && [r existing] != nil, @"half a sync: prefs.js not yet replaced, the RAM profile still valid");
        [r syncToDisk];
        expect([get(@"disk/prefs.js") isEqual:@"user_pref(9);"] && [get(@"disk/aaa.txt") isEqual:@"new a"] && [r existing] != nil, @"the next sync completes it");
        expect(SFYTRamOrphans(@"", @"x\n================================================\nimage-path      : ram://1048576\n/dev/disk3\t\t\n", 1048576).count == 1,
               @"orphan: our size, not mounted, new");
        expect(SFYTRamOrphans(@"", @"================================================\nimage-path      : ram://10485760\n/dev/disk3\t\t\n", 1048576).count == 0,
               @"another size (a longer number) is not ours");
        expect(SFYTRamOrphans(@"", @"================================================\nimage-path      : ram://1048576\n/dev/disk3\tApple_HFS\t/Volumes/X\n", 1048576).count == 0,
               @"a mounted one is not an orphan");
        NSString *pre = @"================================================\nimage-path      : ram://1048576\n/dev/disk2\t\t\n";
        expect(SFYTRamOrphans(pre, pre, 1048576).count == 0, @"one that was there before the attach is not ours");

        // ended after prefs.js was replaced, before the mark: the disk profile is complete (prefs.js comes
        // last), the next start fills RAM anew from it - nothing is lost or destroyed
        sleep(2);
        put(@"ram/profile/bbb.txt", @"new b");
        put(@"ram/profile/prefs.js", @"user_pref(10);");
        r.testStopAfter = 2;   // both replaced, then "Sofa ended"
        [r syncToDisk];
        r.testStopAfter = -1;
        expect([get(@"disk/prefs.js") isEqual:@"user_pref(10);"] && [get(@"disk/bbb.txt") isEqual:@"new b"], @"ended before the mark: everything already on disk");
        expect([r existing] == nil && [r attach] != nil && [get(@"ram/profile/bbb.txt") isEqual:@"new b"] && [get(@"ram/profile/prefs.js") isEqual:@"user_pref(10);"],
               @"the next start fills RAM from the complete disk profile: nothing lost");

        // a browser runs on the disk profile while the RAM disk is mounted with a valid mark (RAM disk full):
        // its sync tick must never write over the living disk profile
        sleep(2);
        put(@"ram/profile/prefs.js", @"user_pref(11); /* stale RAM side */");
        expect([r syncForBrowserOn:P(@"disk")] == 0 && [get(@"disk/prefs.js") isEqual:@"user_pref(10);"], @"browser on the disk profile: nothing synced over it");
        expect([r syncForBrowserOn:[r mountedProfile]] >= 1 && [get(@"disk/prefs.js") hasPrefix:@"user_pref(11)"], @"browser on the RAM profile: synced");

        // something on disk the RAM profile never had (not in its manifest): never deleted
        put(@"disk/written-elsewhere.txt", @"x");
        sleep(2);
        [r syncToDisk];
        expect(exists(@"disk/written-elsewhere.txt"), @"a file the RAM profile never had stays on disk");

        // the disk profile changed behind Sofa's back (a browser ran on it - rollback): the RAM profile
        // is older and must not be synced over it; attach fills it anew
        sleep(2);
        put(@"disk/prefs.js", @"user_pref(3); /* written by a browser on the disk profile */");
        expect([r existing] == nil, @"disk profile newer: the RAM profile is not used");
        // (sync is the caller's: SFYTBrowser syncs only a browser running on the RAM profile - onRam)
        expect([r attach] != nil && [get(@"ram/profile/prefs.js") hasPrefix:@"user_pref(3)"], @"attach fills it anew from the newer disk profile");

        // a fill that cannot read everything (a sector error, permissions): fails - and nothing is lost
        put(@"disk2/prefs.js", @"p");
        put(@"disk2/storage/idb/a.sqlite", @"data");
        chmod(P(@"disk2/storage").fileSystemRepresentation, 0);
        SFYTRamProfile *r2 = [[SFYTRamProfile alloc] initWithDiskProfile:P(@"disk2") mountPoint:P(@"ram2") sizeMB:16];
        r2.testWithoutDisk = YES;
        expect([r2 attach] == nil, @"an unreadable entry: the fill fails (stay on the disk profile)");
        chmod(P(@"disk2/storage").fileSystemRepresentation, 0755);
        expect([get(@"disk2/storage/idb/a.sqlite") isEqual:@"data"], @"and the disk profile keeps it");

        // the RAM side cannot take the files (stands in for ENOSPC): fails, the disk profile is used
        put(@"disk3/prefs.js", @"p");
        [[NSFileManager defaultManager] createDirectoryAtPath:P(@"ram3") withIntermediateDirectories:YES attributes:nil error:nil];
        chmod(P(@"ram3").fileSystemRepresentation, 0555);
        SFYTRamProfile *r3 = [[SFYTRamProfile alloc] initWithDiskProfile:P(@"disk3") mountPoint:P(@"ram3") sizeMB:16];
        r3.testWithoutDisk = YES;
        expect([r3 attach] == nil, @"cannot write the RAM side: no RAM profile");
        chmod(P(@"ram3").fileSystemRepresentation, 0755);

        // a RAM profile without prefs.js (damaged, half filled): never mirrored
        [[NSFileManager defaultManager] removeItemAtPath:P(@"ram/profile/prefs.js") error:nil];
        expect([r syncToDisk] == 0 && exists(@"disk/prefs.js"), @"no prefs.js in RAM: the disk profile stays as it is");
        expect(SFYTRamProfileSkips(@"storage/default/https+++www.youtube.com/cache/caches.sqlite")
               && SFYTRamProfileSkips(@"storage/default/https+++www.youtube.com/cache/morgue/12/x.final")
               && SFYTRamProfileSkips(@"storage/default/https+++www.youtube.com/cache")
               && !SFYTRamProfileSkips(@"storage/default/https+++www.youtube.com/idb/a.sqlite")
               && !SFYTRamProfileSkips(@"storage/default/https+++www.youtube.com/ls/data.sqlite"), @"a site's Cache API store stays out, its other storage not");
        expect(SFYTRamProfileSkips(@"storage/permanent/chrome/cache/caches.sqlite") && SFYTRamProfileSkips(@"storage/temporary/x/cache/y")
               && !SFYTRamProfileSkips(@"storage/permanent/chrome/idb/a.sqlite"), @"the same in the other storage classes");
        expect(SFYTRamProfileSkips(@"cache2/x") && SFYTRamProfileSkips(@".parentlock") && SFYTRamProfileSkips(@"a/b.tmp")
               && !SFYTRamProfileSkips(@"storage/default") && !SFYTRamProfileSkips(@"cookies.sqlite"), @"what stays out");
        [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
    }
    if (!fails) printf("ramprofile ok\n");
    return fails ? 1 : 0;
}
