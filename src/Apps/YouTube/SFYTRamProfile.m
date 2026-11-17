#import "SFYTRamProfile.h"
#import "SFCore.h"
#import "SFRuntime.h"
#include <sqlite3.h>
#include <copyfile.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <fcntl.h>
#include <CommonCrypto/CommonDigest.h>

static NSString *const kMarker = @".sofa-engine-ram";      // plist: device, the disk profile's prefs.js as last left
static NSString *const kManifest = @".sofa-manifest";      // what the RAM profile had at the last fill/sync

BOOL SFYTRamProfileSkips(NSString *rel) {
    static NSSet *top;
    static dispatch_once_t once;
    // caches and what Firefox rebuilds or Sofa removes at every start anyway
    dispatch_once(&once, ^{ top = [NSSet setWithArray:@[@"cache2", @"startupCache", @"safebrowsing", @"shader-cache", @"crashes",
        @"minidumps", @"datareporting", @"saved-telemetry-pings", @"sessionstore-backups", @"sessionstore.jsonlz4", @"thumbnails",
        @"OfflineCache", @".parentlock", @"lock", @"Crash Reports"]]; });
    NSString *first = rel.pathComponents.firstObject;
    if (!first || [top containsObject:first]) return YES;
    NSString *name = rel.lastPathComponent;
    return [name hasSuffix:@".tmp"] || [name hasPrefix:@".sofa-sync-"];
}
static BOOL IsCompanion(NSString *path) { return [path hasSuffix:@"-wal"] || [path hasSuffix:@"-shm"] || [path hasSuffix:@"-journal"]; }

static BOOL IsSQLite(NSString *path) {
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) return NO;
    char h[16] = {0};
    size_t n = fread(h, 1, 16, f);
    fclose(f);
    return n == 16 && memcmp(h, "SQLite format 3", 16) == 0;
}
static double MTime(NSString *path, off_t *size) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) return -1;
    if (size) *size = st.st_size;
    return st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec / 1e9;
}
static void SetMTime(NSString *path, double t) {
    struct timeval tv[2] = {{(time_t)t, (suseconds_t)((t - floor(t)) * 1e6)}, {(time_t)t, (suseconds_t)((t - floor(t)) * 1e6)}};
    utimes(path.fileSystemRepresentation, tv);
}
// the content of a file and its WAL (a database), to tell a change within the same second
static NSData *Digest(NSString *path) {
    CC_SHA1_CTX c; CC_SHA1_Init(&c);
    for (NSString *p in @[path, [path stringByAppendingString:@"-wal"]]) {
        NSData *d = [NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:nil];
        if (d) CC_SHA1_Update(&c, d.bytes, (CC_LONG)d.length);
    }
    unsigned char out[CC_SHA1_DIGEST_LENGTH]; CC_SHA1_Final(out, &c);
    return [NSData dataWithBytes:out length:sizeof out];
}

// a consistent copy of a database another process writes (WAL, shared locking)
static BOOL BackupSQLite(NSString *from, NSString *to) {
    sqlite3 *src = NULL, *dst = NULL;
    BOOL ok = NO;
    unlink(to.fileSystemRepresentation);
    if (sqlite3_open_v2(from.fileSystemRepresentation, &src, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK
        && sqlite3_open_v2(to.fileSystemRepresentation, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) == SQLITE_OK) {
        sqlite3_busy_timeout(src, 3000);
        sqlite3_backup *b = sqlite3_backup_init(dst, "main", src, "main");
        if (b) { ok = sqlite3_backup_step(b, -1) == SQLITE_DONE; ok = sqlite3_backup_finish(b) == SQLITE_OK && ok; }
    }
    if (src) sqlite3_close(src);
    if (dst) sqlite3_close(dst);
    if (!ok) unlink(to.fileSystemRepresentation);
    return ok;
}

// every entry under root (relative paths; caches skipped); NO when anything could not be read - then
// nothing may be concluded from what was seen (a missing entry is not a deleted one)
static BOOL Walk(NSString *root, void (^visit)(NSString *rel, const struct stat *st)) {
    __block BOOL failed = NO;
    NSURL *base = [NSURL fileURLWithPath:root isDirectory:YES];
    NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtURL:base includingPropertiesForKeys:nil options:0
        errorHandler:^BOOL(NSURL *url, NSError *err) { SFLog(@"yt-ram: cannot read %@ (%@)", url.path, err.localizedDescription); failed = YES; return NO; }];
    // the enumerator may hand out the resolved form (/var -> /private/var)
    char real[PATH_MAX];
    NSString *prefix = [base.path stringByAppendingString:@"/"];
    NSString *realPrefix = realpath(root.fileSystemRepresentation, real) ? [@(real) stringByAppendingString:@"/"] : prefix;
    for (NSURL *u in e) {
        if (failed) break;
        NSString *path = u.path, *rel;
        if ([path hasPrefix:prefix]) rel = [path substringFromIndex:prefix.length];
        else if ([path hasPrefix:realPrefix]) rel = [path substringFromIndex:realPrefix.length];
        else continue;
        if (SFYTRamProfileSkips(rel)) { [e skipDescendants]; continue; }
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0) { SFLog(@"yt-ram: cannot stat %@ (%s)", path, strerror(errno)); failed = YES; break; }
        visit(rel, &st);
    }
    return !failed;
}

// data on the platter, not in the drive's cache: fsync every file, then one F_FULLFSYNC (a drive flush)
static void Durable(NSArray *paths, NSString *anyDir) {
    for (NSString *p in paths) { int fd = open(p.fileSystemRepresentation, O_RDONLY); if (fd >= 0) { fsync(fd); close(fd); } }
    int fd = open(anyDir.fileSystemRepresentation, O_RDONLY);
    if (fd >= 0) { fcntl(fd, F_FULLFSYNC); close(fd); }
}

@implementation SFYTRamProfile {
    NSString *_mount;
    NSUInteger _mb;
    NSInteger _testStopAfter;
    double _lastSyncAt;   // when the last sync began: a file changed since may share its second with the copy
    NSMutableDictionary *_digests;   // rel -> digest of what the last sync copied (files of that second)
}

- (instancetype)initWithDiskProfile:(NSString *)disk mountPoint:(NSString *)mount sizeMB:(NSUInteger)mb {
    if ((self = [super init])) { _diskProfile = disk; _mount = mount; _mb = mb; _testStopAfter = -1; }
    return self;
}

- (NSString *)ramProfile { return [_mount stringByAppendingPathComponent:@"profile"]; }
- (NSString *)tmpDir { return [self existing] ? [_mount stringByAppendingPathComponent:@"tmp"] : nil; }

- (BOOL)mounted {
    if (_testWithoutDisk) return [[NSFileManager defaultManager] fileExistsAtPath:_mount];
    struct statfs fs;
    char real[PATH_MAX];
    if (!realpath(_mount.fileSystemRepresentation, real) || statfs(real, &fs) != 0) return NO;
    return strcmp(fs.f_mntonname, real) == 0;
}

- (long long)freeBytes {
    struct statfs fs;
    if (![self existing] || statfs(_mount.fileSystemRepresentation, &fs) != 0) return -1;
    return (long long)fs.f_bavail * fs.f_bsize;
}

// the disk profile's prefs.js (Firefox rewrites it at every end and now and then): who ran last
- (NSString *)diskStamp {
    struct stat st;
    NSString *p = [_diskProfile stringByAppendingPathComponent:@"prefs.js"];
    return lstat(p.fileSystemRepresentation, &st) == 0 ? [NSString stringWithFormat:@"%ld.%09ld/%lld", (long)st.st_mtimespec.tv_sec, (long)st.st_mtimespec.tv_nsec, (long long)st.st_size] : @"-";
}
- (NSDictionary *)marker { NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:[_mount stringByAppendingPathComponent:kMarker]]; return [m isKindOfClass:[NSDictionary class]] ? m : nil; }
- (void)writeMarker:(NSString *)dev {
    NSMutableDictionary *m = [[self marker] mutableCopy] ?: [NSMutableDictionary new];
    if (dev) m[@"device"] = dev;
    m[@"disk"] = [self diskStamp];
    [m writeToFile:[_mount stringByAppendingPathComponent:kMarker] atomically:YES];
}

// the RAM profile as it is (mounted, Sofa's marker) - whoever ran last; for a browser known to run on it
- (NSString *)mountedProfile {
    BOOL dir = NO;
    return [self mounted] && [self marker] && [[NSFileManager defaultManager] fileExistsAtPath:[self ramProfile] isDirectory:&dir] && dir ? [self ramProfile] : nil;
}

- (NSString *)existing {
    BOOL dir = NO;
    NSDictionary *m = [self mounted] ? [self marker] : nil;
    if (!m || ![[NSFileManager defaultManager] fileExistsAtPath:[self ramProfile] isDirectory:&dir] || !dir) return nil;
    // the disk profile changed since Sofa last left it (a browser ran on it - an older Sofa, a
    // rollback): this RAM disk is older than the disk profile and must never be synced over it
    return [m[@"disk"] isEqual:[self diskStamp]] ? [self ramProfile] : nil;
}

static NSString *Run(NSString *tool, NSArray *args, NSTimeInterval timeout, int *rcOut) {
    NSData *out = nil;
    int rc = SFRunProcess(tool, args, timeout, YES, &out);
    if (rcOut) *rcOut = rc;
    NSString *s = [[NSString alloc] initWithData:out ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
    return rc == 0 ? s : [NSString stringWithFormat:@"!%d %@", rc, s];
}

// the ram:// devices of exactly our size, not mounted, that were not there before the attach
NSArray *SFYTRamOrphans(NSString *before, NSString *after, NSUInteger sectors) {
    NSString *want = [NSString stringWithFormat:@"ram://%lu", (unsigned long)sectors];
    NSMutableArray *(^devices)(NSString *, BOOL) = ^NSMutableArray *(NSString *info, BOOL onlyFree) {
        NSMutableArray *out = [NSMutableArray new];
        for (NSString *block in [info componentsSeparatedByString:@"================================================"]) {
            BOOL ours = NO; NSString *dev = nil; BOOL mounted = NO;
            for (NSString *line in [block componentsSeparatedByString:@"\n"]) {
                NSArray *kv = [line componentsSeparatedByString:@":"];
                if (kv.count == 3 && [[kv[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] isEqualToString:@"image-path"]
                    && [[[kv[1] stringByAppendingFormat:@":%@", kv[2]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] isEqualToString:want]) ours = YES;
                if ([line hasPrefix:@"/dev/disk"]) {
                    NSArray *cols = [line componentsSeparatedByString:@"\t"];
                    if (!dev) dev = cols[0];
                    for (NSString *c in cols) if ([c hasPrefix:@"/"] && ![c hasPrefix:@"/dev/"]) mounted = YES;
                }
            }
            if (ours && dev && (!onlyFree || !mounted)) [out addObject:dev];
        }
        return out;
    };
    NSMutableArray *orphans = devices(after, YES);
    [orphans removeObjectsInArray:devices(before, NO)];
    return orphans;
}

- (void)detachOrphansSince:(NSString *)before {
    for (NSString *dev in SFYTRamOrphans(before, Run(@"/usr/bin/hdiutil", @[@"info"], 20, NULL), _mb * 2048)) {
        SFLog(@"yt-ram: detaching the RAM disk %@ the timed out attach left", dev);
        Run(@"/usr/bin/hdiutil", @[@"detach", dev, @"-force"], 20, NULL);
    }
}

// fill an empty profile directory from the disk profile; the manifest of what it got; nil on any error
- (NSArray *)fill:(NSString *)to {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:to error:nil];
    if (![fm createDirectoryAtPath:to withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    NSMutableArray *have = [NSMutableArray new];
    __block BOOL failed = NO;
    BOOL read = Walk(_diskProfile, ^(NSString *rel, const struct stat *st) {
        if (failed) return;
        NSString *s = [self->_diskProfile stringByAppendingPathComponent:rel], *d = [to stringByAppendingPathComponent:rel];
        if (S_ISDIR(st->st_mode)) {
            if (![fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil]) failed = YES;
            else [have addObject:[rel stringByAppendingString:@"/"]];
        } else if (S_ISREG(st->st_mode)) {
            if (copyfile(s.fileSystemRepresentation, d.fileSystemRepresentation, NULL, COPYFILE_ALL) != 0) {
                SFLog(@"yt-ram: cannot copy %@ (%s)", rel, strerror(errno));   // ENOSPC among them
                failed = YES;
            } else if (!IsCompanion(rel)) [have addObject:rel];
        }
    });
    return read && !failed ? have : nil;
}
- (void)writeManifest:(NSArray *)have { [[have componentsJoinedByString:@"\n"] writeToFile:[_mount stringByAppendingPathComponent:kManifest] atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
- (NSSet *)manifest {
    NSString *s = [NSString stringWithContentsOfFile:[_mount stringByAppendingPathComponent:kManifest] encoding:NSUTF8StringEncoding error:nil];
    return s.length ? [NSSet setWithArray:[s componentsSeparatedByString:@"\n"]] : [NSSet set];
}

// the RAM profile filled anew (a new RAM disk, or one older than the disk profile)
- (NSString *)refill:(NSString *)dev {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDate *t0 = [NSDate date];
    NSString *filling = [_mount stringByAppendingPathComponent:@"profile.filling"];
    NSArray *have = [self fill:filling];
    [fm removeItemAtPath:[self ramProfile] error:nil];
    if (!have || ![fm moveItemAtPath:filling toPath:[self ramProfile] error:nil]) { [fm removeItemAtPath:filling error:nil]; return nil; }
    [self writeManifest:have];
    [self writeMarker:dev];
    _lastSyncAt = 0; [_digests removeAllObjects];
    SFLog(@"yt-ram: profile on the RAM disk (%lu MB, %lu entries from the disk profile in %.1f s)", (unsigned long)_mb, (unsigned long)have.count, -[t0 timeIntervalSinceNow]);
    return [self ramProfile];
}

- (NSString *)attach {
    NSString *have = [self existing];
    if (have) return have;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (_testWithoutDisk) {   // the directory stands in for a mounted RAM disk
        [fm createDirectoryAtPath:[_mount stringByAppendingPathComponent:@"tmp"] withIntermediateDirectories:YES attributes:nil error:nil];
        return [self refill:nil];
    }
    if ([self mounted]) {
        if (![self marker]) { SFLog(@"yt-ram: %@ is mounted, but not by Sofa - staying on the disk profile", _mount); return nil; }
        SFLog(@"yt-ram: the disk profile is newer than the RAM disk (a browser ran on it) - filling it anew");
        NSString *r = [self refill:nil];
        if (!r) SFLog(@"yt-ram: cannot fill the RAM disk anew - staying on the disk profile");
        return r;
    }
    int rc = 0;
    NSString *before = Run(@"/usr/bin/hdiutil", @[@"info"], 20, NULL);
    NSString *out = Run(@"/usr/bin/hdiutil", @[@"attach", @"-nomount", [NSString stringWithFormat:@"ram://%lu", (unsigned long)_mb * 2048]], 20, &rc);
    if (rc == -2) [self detachOrphansSince:before];
    NSString *dev = [[out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].firstObject;
    if (rc != 0 || ![dev hasPrefix:@"/dev/disk"]) { SFLog(@"yt-ram: no RAM disk (%@) - staying on the disk profile", out); return nil; }
    void (^fail)(NSString *) = ^(NSString *why) {
        SFLog(@"yt-ram: %@ - staying on the disk profile", why);
        Run(@"/usr/sbin/diskutil", @[@"unmount", @"force", dev], 20, NULL);
        Run(@"/usr/bin/hdiutil", @[@"detach", dev, @"-force"], 20, NULL);
    };
    NSString *r = Run(@"/sbin/newfs_hfs", @[@"-v", @"SofaEngine", dev], 30, NULL);
    if ([r hasPrefix:@"!"]) { fail([@"newfs_hfs: " stringByAppendingString:r]); return nil; }
    [fm createDirectoryAtPath:_mount withIntermediateDirectories:YES attributes:nil error:nil];
    // (10.9's diskutil mount takes no mount options - nobrowse is not available; Spotlight and
    // fseventsd are kept out by their marker files right after, and anything they write stays in RAM)
    r = Run(@"/usr/sbin/diskutil", @[@"mount", @"-mountPoint", _mount, dev], 20, NULL);
    if (![self mounted]) { fail([@"mount: " stringByAppendingString:r]); return nil; }
    [fm createFileAtPath:[_mount stringByAppendingPathComponent:@".metadata_never_index"] contents:nil attributes:nil];
    [fm createDirectoryAtPath:[_mount stringByAppendingPathComponent:@".fseventsd"] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createFileAtPath:[_mount stringByAppendingPathComponent:@".fseventsd/no_log"] contents:nil attributes:nil];
    [fm createDirectoryAtPath:[_mount stringByAppendingPathComponent:@"tmp"] withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    if (![self refill:dev]) { fail(@"cannot fill the RAM disk"); return nil; }
    return [self ramProfile];
}

- (NSUInteger)syncToDisk {
    NSString *ram = [self mountedProfile];   // the caller knows the browser runs on it (SFYTBrowser onRam)
    NSFileManager *fm = [NSFileManager defaultManager];
    // a RAM profile without its prefs is not one to mirror (a half filled or damaged disk)
    if (!ram || ![fm fileExistsAtPath:[ram stringByAppendingPathComponent:@"prefs.js"]]) return 0;
    NSDate *t0 = [NSDate date];
    double began = t0.timeIntervalSince1970;
    NSMutableArray *now = [NSMutableArray new], *pending = [NSMutableArray new];   // pending: @[tmp, dest, v, rel, digest]
    __block NSUInteger failed = 0;
    BOOL read = Walk(ram, ^(NSString *rel, const struct stat *st) {
        if (IsCompanion(rel)) return;
        NSString *s = [ram stringByAppendingPathComponent:rel], *d = [self->_diskProfile stringByAppendingPathComponent:rel];
        if (S_ISDIR(st->st_mode)) { [now addObject:[rel stringByAppendingString:@"/"]]; [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil]; return; }
        if (!S_ISREG(st->st_mode)) return;
        [now addObject:rel];
        off_t ramSize = st->st_size, diskSize = -1;
        double v = MAX(st->st_mtimespec.tv_sec + st->st_mtimespec.tv_nsec / 1e9, MTime([s stringByAppendingString:@"-wal"], NULL));   // a database changes in its WAL
        double dv = MTime(d, &diskSize);
        BOOL sqlite = IsSQLite(s);
        // unchanged: same time and size - and when the time shares a second with the last sync (HFS+ keeps
        // whole seconds), the same content as copied then
        BOOL recent = self->_lastSyncAt > 0 && v >= floor(self->_lastSyncAt);
        NSData *digest = recent ? Digest(s) : nil;
        if (dv >= 0 && fabs(dv - v) < 0.001 && (sqlite || diskSize == ramSize) && (!recent || [digest isEqualToData:self->_digests[rel]])) return;
        NSString *tmp = [[d stringByDeletingLastPathComponent] stringByAppendingPathComponent:[@".sofa-sync-" stringByAppendingString:rel.lastPathComponent]];
        BOOL ok = sqlite ? BackupSQLite(s, tmp) : copyfile(s.fileSystemRepresentation, tmp.fileSystemRepresentation, NULL, COPYFILE_DATA | COPYFILE_SECURITY) == 0;
        if (!ok) { SFLog(@"yt-ram: cannot copy %@ back (%@)", rel, sqlite ? @"database busy or unreadable" : @(strerror(errno))); failed++; unlink(tmp.fileSystemRepresentation); return; }
        // replaced last: the databases (they point at files beside them - blobs, cache bodies - which are
        // in place first), and prefs.js the very last (its new stamp then means "complete", see writeMarker)
        int order = [rel isEqualToString:@"prefs.js"] ? 2 : sqlite ? 1 : 0;
        [pending addObject:@[tmp, d, @(v), rel, digest ?: [NSNull null], @(order)]];
    });
    if (!read) {   // something could not be read: neither copy nor delete on half a picture
        for (NSArray *p in pending) unlink([p[0] fileSystemRepresentation]);
        SFLog(@"yt-ram: sync to disk skipped - the RAM profile could not be read completely");
        return 0;
    }
    // durable before it replaces anything: a reset at any moment leaves the old or the new file, never a torn one
    NSMutableArray *tmps = [NSMutableArray new];
    for (NSArray *p in pending) [tmps addObject:p[0]];
    Durable(tmps, _diskProfile);
    NSUInteger written = 0, removed = 0;
    if (!_digests) _digests = [NSMutableDictionary new];
    [pending sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[5] compare:b[5]]; }];
    for (NSArray *p in pending) {
        if (_testStopAfter >= 0 && (NSInteger)written >= _testStopAfter) return written;   // tests: Sofa ended mid-way
        NSString *tmp = p[0], *d = p[1], *rel = p[3];
        double v = [p[2] doubleValue];
        // the old companions first: a stale WAL next to the new database would be replayed into it
        for (NSString *c in @[@"-wal", @"-shm", @"-journal"]) unlink([d stringByAppendingString:c].fileSystemRepresentation);
        if (rename(tmp.fileSystemRepresentation, d.fileSystemRepresentation) != 0) { SFLog(@"yt-ram: cannot replace %@ (%s)", rel, strerror(errno)); failed++; unlink(tmp.fileSystemRepresentation); continue; }
        SetMTime(d, v);
        if (v >= floor(began) - 1) _digests[rel] = [p[4] isKindOfClass:[NSData class]] ? p[4] : Digest([[self ramProfile] stringByAppendingPathComponent:rel]);
        else [_digests removeObjectForKey:rel];
        written++;
    }
    if (_testStopAfter >= 0 && (NSInteger)written >= _testStopAfter) return written;   // tests: ended before the mark
    if (written) Durable(@[], _diskProfile);   // the renames committed
    [self writeMarker:nil];   // right after prefs.js: the disk profile as Sofa left it (a later change is someone else's)
    // deleted by the browser: only what the RAM profile had at the last fill/sync and has no more
    NSSet *nowSet = [NSSet setWithArray:now];
    for (NSString *gone in [self manifest]) {
        if (!gone.length || [nowSet containsObject:gone] || SFYTRamProfileSkips(gone)) continue;
        NSString *d = [_diskProfile stringByAppendingPathComponent:gone];
        if (![gone hasSuffix:@"/"]) for (NSString *c in @[@"-wal", @"-shm", @"-journal"]) unlink([d stringByAppendingString:c].fileSystemRepresentation);
        if ([fm removeItemAtPath:d error:nil]) removed++;
    }
    if (removed) Durable(@[], _diskProfile);   // the removals committed
    [self writeManifest:now];
    _lastSyncAt = began;
    if (written || removed || failed)
        SFLog(@"yt-ram: synced to disk - %lu written, %lu removed%@ (%.1f s)", (unsigned long)written, (unsigned long)removed,
              failed ? [NSString stringWithFormat:@", %lu failed", (unsigned long)failed] : @"", -[t0 timeIntervalSinceNow]);
    return written + removed;
}

- (NSUInteger)syncForBrowserOn:(NSString *)profile {
    NSString *ram = [self mountedProfile];
    return ram && [profile isEqualToString:ram] ? [self syncToDisk] : 0;
}

- (NSString *)consumers {
    NSMutableArray *parts = [NSMutableArray new];
    for (NSString *top in @[@"profile", @"tmp", @"firefox.log"]) {
        __block long long bytes = 0;
        NSString *root = [_mount stringByAppendingPathComponent:top];
        struct stat st;
        if (lstat(root.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)) bytes = st.st_size;
        else for (NSString *rel in [[NSFileManager defaultManager] enumeratorAtPath:root])
            if (lstat([root stringByAppendingPathComponent:rel].fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)) bytes += st.st_size;
        [parts addObject:[NSString stringWithFormat:@"%@ %.0f MB", top, bytes / 1048576.0]];
    }
    return [parts componentsJoinedByString:@", "];
}
@end
