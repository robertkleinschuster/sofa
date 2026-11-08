// sources: src/Library/SFMediaStore.m src/Library/SFExtentSet.m
// flags: -Isrc/Library -I/opt/local/include -L/opt/local/lib -lsqlite3
// SFMediaStore in a directory of its own: bytes back as written (also across a block boundary),
// nothing for a range with a gap, the gapless part from a position, the index after a reopen, a block file deleted from outside
// (dropped from the index, not served; on open: checked against the files), eviction least recently used first while space is short -
// a pinned item never - and removing an item (its ranges cascade; schema version 2), manifests
// (kept with the item's bytes, gone with it), completeness, and eviction of whole items.
#import <Foundation/Foundation.h>
#import "SFMediaStore.h"
BOOL SFDevMode = NO;
static int bad = 0;
#define CHECK(c, m) do { if (!(c)) { fprintf(stderr, "FAIL %s (%s:%d)\n", m, __FILE__, __LINE__); bad++; } } while (0)
static NSData *Bytes(NSUInteger n, uint8_t seed) {
    NSMutableData *d = [NSMutableData dataWithLength:n];
    uint8_t *p = d.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) p[i] = (uint8_t)(seed + i * 7);
    return d;
}
int main(void) { @autoreleasepool {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sofa-mediastore-%d", getpid()]];
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    const long long block = 4LL << 20;

    SFMediaStore *s = [[SFMediaStore alloc] initWithDirectory:dir];
    s.freeSpace = ^long long { return 1LL << 40; };   // plenty: no eviction while writing
    NSData *a = Bytes(100000, 1);
    [s write:a key:@"yt:v1:137:9000000" item:@"yt:v1" kind:@"video" total:9000000 at:0];
    NSData *edge = Bytes(300000, 2);   // across the first block boundary
    [s write:edge key:@"yt:v1:137:9000000" item:@"yt:v1" kind:@"video" total:9000000 at:block - 100000];
    [s sync];
    CHECK([[s read:@"yt:v1:137:9000000" start:0 length:100000] isEqual:a], "bytes back as written");
    CHECK([[s read:@"yt:v1:137:9000000" start:block - 100000 length:300000] isEqual:edge], "across a block boundary");
    CHECK([[s read:@"yt:v1:137:9000000" start:50000 length:10000] isEqual:[a subdataWithRange:NSMakeRange(50000, 10000)]], "a part of a piece");
    CHECK([s read:@"yt:v1:137:9000000" start:0 length:100001] == nil, "a range with a gap: nothing");
    CHECK([s read:@"yt:nope" start:0 length:1] == nil, "an unknown track: nothing");
    CHECK([[s readAvailable:@"yt:v1:137:9000000" start:40000 max:1 << 20] isEqual:[a subdataWithRange:NSMakeRange(40000, 60000)]], "available: up to the gap");
    CHECK([[s readAvailable:@"yt:v1:137:9000000" start:0 max:500] isEqual:[a subdataWithRange:NSMakeRange(0, 500)]], "available: at most max");
    CHECK([s readAvailable:@"yt:v1:137:9000000" start:100000 max:10] == nil, "available: nothing at a gap");
    CHECK([s bytesOfItem:@"yt:v1"] == 400000 && s.bytes == 400000, "stored bytes counted once");

    SFMediaStore *again = [[SFMediaStore alloc] initWithDirectory:dir];
    CHECK([[again read:@"yt:v1:137:9000000" start:block - 100000 length:300000] isEqual:edge] && again.bytes == 400000, "the index after a reopen");

    // a block file gone from outside: not served, dropped from the index
    NSString *trackDir = nil;
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) if (![f hasPrefix:@"store.db"]) trackDir = [dir stringByAppendingPathComponent:f];
    [[NSFileManager defaultManager] removeItemAtPath:[trackDir stringByAppendingPathComponent:@"1"] error:nil];
    CHECK([again read:@"yt:v1:137:9000000" start:block length:1000] == nil, "a missing block file is not served");
    CHECK(![[again extentsOf:@"yt:v1:137:9000000"] coversStart:block end:block + 1000], "...and leaves the index");
    CHECK([[again read:@"yt:v1:137:9000000" start:0 length:100000] isEqual:a], "the rest stays");
    [[NSFileManager defaultManager] removeItemAtPath:[trackDir stringByAppendingPathComponent:@"0"] error:nil];
    SFMediaStore *third = [[SFMediaStore alloc] initWithDirectory:dir];
    CHECK([third extentsOf:@"yt:v1:137:9000000"].bytes == 0 && third.bytes == 0, "on open: ranges whose block files are gone leave the index");

    // eviction on a 3 MB "disk": free space = 3 MB minus the block files on it (the function runs on
    // the store's queue - it reads the files, never the store)
    NSString *dir2 = [dir stringByAppendingString:@"-evict"];
    [[NSFileManager defaultManager] removeItemAtPath:dir2 error:nil];
    SFMediaStore *e = [[SFMediaStore alloc] initWithDirectory:dir2];
    e.freeSpace = ^long long {
        long long used = 0;
        NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:dir2];
        for (NSString *f in en) if (![f hasPrefix:@"store.db"]) used += [en.fileAttributes[NSFileType] isEqual:NSFileTypeRegular] ? [en.fileAttributes fileSize] : 0;
        return 3000000 - used;
    };
    e.reserve = 0;
    [e write:Bytes(1000000, 3) key:@"old" item:@"item:old" kind:@"video" total:0 at:0];
    [e sync]; usleep(20000);
    [e write:Bytes(1000000, 4) key:@"pinned" item:@"item:pinned" kind:@"video" total:0 at:0];
    [e sync]; usleep(20000);
    [e write:Bytes(1000000, 5) key:@"new" item:@"item:new" kind:@"video" total:0 at:0];
    [e sync];
    [e read:@"new" start:0 length:10];   // used last
    e.isPinned = ^BOOL(NSString *item) { return [item isEqualToString:@"item:pinned"]; };
    e.reserve = 1500000;   // free is 0: two tracks would have to go - the pinned one may not
    [e evictNow];
    CHECK([e extentsOf:@"old"].bytes == 0, "the least recently used goes first");
    CHECK([e extentsOf:@"pinned"].bytes == 1000000, "a pinned item never goes");
    CHECK([e extentsOf:@"new"].bytes == 0, "then the next one, until there is room");
    [e write:Bytes(1000, 6) key:@"x" item:@"item:x" kind:@"audio" total:0 at:0];
    [e sync];
    [e removeItem:@"item:x"];
    CHECK([e extentsOf:@"x"].bytes == 0 && [e read:@"x" start:0 length:10] == nil, "removing an item");
    [e sync];
    NSString *q = [NSString stringWithFormat:@"/opt/local/bin/sqlite3 '%@/store.db' 'PRAGMA user_version; PRAGMA foreign_key_check; "
                   "SELECT count(*) FROM extents WHERE track NOT IN (SELECT id FROM tracks);'", dir2];
    FILE *f = popen(q.UTF8String, "r"); char buf[256] = {0}; size_t n = f ? fread(buf, 1, sizeof buf - 1, f) : 0; if (f) pclose(f);
    CHECK(n && strcmp(buf, "2\n0\n") == 0, "schema version 2, no orphan ranges after removals");

    // manifests and completeness
    NSString *dir3 = [dir stringByAppendingString:@"-manifest"];
    [[NSFileManager defaultManager] removeItemAtPath:dir3 error:nil];
    SFMediaStore *m = [[SFMediaStore alloc] initWithDirectory:dir3];
    m.freeSpace = ^long long { return 1LL << 40; };
    NSDictionary *man = @{@"required": @[@"yt:v2:v", @"yt:v2:a"], @"duration": @12};
    [m setManifest:man forItem:@"yt:v2"];
    [m setManifest:@{@"x": @1} forItem:@"yt:nobytes"];
    [m write:Bytes(1000, 7) key:@"yt:v2:v" item:@"yt:v2" kind:@"video" total:1000 at:0];
    [m write:Bytes(500, 8) key:@"yt:v2:a" item:@"yt:v2" kind:@"audio" total:600 at:0];
    [m sync];
    CHECK([[m manifestOf:@"yt:v2"] isEqual:man], "a manifest back as written");
    NSArray *both = @[@"yt:v2:v", @"yt:v2:a"], *withUnknown = @[@"yt:v2:v", @"yt:nope"];
    CHECK(![m hasComplete:both] && [m hasComplete:@[@"yt:v2:v"]] && ![m itemIsComplete:@"yt:v2"], "complete only when every track is whole");
    [m write:Bytes(100, 9) key:@"yt:v2:a" item:@"yt:v2" kind:@"audio" total:600 at:500];
    [m sync];
    CHECK([m hasComplete:both] && ![m hasComplete:withUnknown] && ![m hasComplete:@[]], "...and then complete");
    CHECK([m itemIsComplete:@"yt:v2"] && ![m itemIsComplete:@"yt:nobytes"] && ![m itemIsComplete:@"yt:none"], "an item complete by its manifest's required tracks");
    SFMediaStore *m2 = [[SFMediaStore alloc] initWithDirectory:dir3];
    CHECK([[m2 manifestOf:@"yt:v2"] isEqual:man] && [m2 manifestOf:@"yt:nobytes"] == nil, "after a reopen: kept with bytes, dropped without");
    // whole items go: v2 (two tracks, used long ago) before v3 (used now)
    [m2 write:Bytes(1000, 10) key:@"yt:v3:v" item:@"yt:v3" kind:@"video" total:0 at:0];
    [m2 sync]; usleep(20000);
    [m2 read:@"yt:v3:v" start:0 length:10];
    m2.reserve = 1;   // free 0 at first: one item has to go
    __block int calls = 0;
    m2.freeSpace = ^long long { return calls++ < 2 ? 0 : 10; };   // room after the first item went
    [m2 evictNow];
    CHECK([m2 extentsOf:@"yt:v2:v"].bytes == 0 && [m2 extentsOf:@"yt:v2:a"].bytes == 0 && [m2 manifestOf:@"yt:v2"] == nil,
          "the least recently used item goes whole, with its manifest");
    CHECK([m2 extentsOf:@"yt:v3:v"].bytes == 1000, "the recent one stays");

    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:dir2 error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:dir3 error:nil];
    return bad ? 1 : 0;
} }
