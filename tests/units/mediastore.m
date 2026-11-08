// sources: src/Library/SFMediaStore.m src/Library/SFExtentSet.m
// flags: -Isrc/Library -I/opt/local/include -L/opt/local/lib -lsqlite3
// SFMediaStore in a directory of its own: bytes back as written (also across a block boundary),
// nothing for a range with a gap, the gapless part from a position, the index after a reopen, a block file deleted from outside
// (dropped from the index, not served), eviction least recently used first while space is short -
// a pinned item never - and removing an item (its ranges cascade; schema version 1).
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
    CHECK(n && strcmp(buf, "1\n0\n") == 0, "schema version 1, no orphan ranges after removals");

    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:dir2 error:nil];
    return bad ? 1 : 0;
} }
