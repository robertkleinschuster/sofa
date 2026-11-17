// SFYTRamProfile - the engine's Firefox profile on a RAM disk (user 2026-11-17: no disk writes while
// idle or resting; the iMac has 16 GB, ~11 GB free). Firefox writes its profile every few seconds
// (AlternateServices.bin, prefs, cookies, IndexedDB, startup cache); on the RAM disk none of that
// reaches the HDD. The disk profile stays the lasting copy: syncToDisk brings changed files back
// (SQLite through the backup API - a consistent copy while Firefox writes, with
// storage.sqlite.exclusiveLock.enabled off; other files copied and renamed into place; files gone
// from the RAM profile removed) - now and then and when the browser ends regularly. A reboot loses
// the RAM disk: the next attach fills it from the disk profile again (at most one sync interval of
// cookies and page state older). The RAM disk outlives Sofa (updates, crashes): the next Sofa uses
// it as it is - unless the disk profile changed since Sofa last left it (a browser ran on it: an
// older Sofa, a rollback), then the RAM disk is filled anew and never synced over the newer disk
// profile. Copies back are durable before they replace anything (fsync + F_FULLFSYNC, then rename):
// a hard reset leaves each file old or new, never torn. Only what the RAM profile had is ever
// deleted from the disk profile (a manifest), and nothing when anything could not be read. Caches stay
// out of both (cache2, startupCache, ...). After a rollback the RAM disk stays mounted until a reboot
// or `hdiutil detach` of the "SofaEngine" disk.
#import <Foundation/Foundation.h>

@interface SFYTRamProfile : NSObject
- (instancetype)initWithDiskProfile:(NSString *)disk mountPoint:(NSString *)mount sizeMB:(NSUInteger)mb;
@property (nonatomic, readonly) NSString *diskProfile;
// the RAM profile when its disk is mounted and filled and not older than the disk profile, else nil
- (NSString *)existing;
// the RAM profile when mounted with Sofa's marker, whoever ran last (a browser known to use it)
- (NSString *)mountedProfile;
// blocking: mount a RAM disk if none, fill it from the disk profile (which nobody may use meanwhile);
// the RAM profile's path, or nil (it could not be made: stay on the disk profile)
- (NSString *)attach;
- (NSString *)tmpDir;   // on the RAM disk (nil without it): TMPDIR for the browser and its display
- (long long)freeBytes;   // free space on the RAM disk, -1 without it
- (NSString *)consumers;  // what takes its space (for the log)
// blocking: changed files back to the disk profile; how many files were written or removed. Only
// while the browser runs on the RAM profile (or after it ended there) - the caller knows.
- (NSUInteger)syncToDisk;
// the sync as the browser asks it: only when the browser runs on the RAM profile (`profile` = the one
// it uses) - never over a disk profile a browser lives on while a RAM disk is mounted (RAM disk full)
- (NSUInteger)syncForBrowserOn:(NSString *)profile;
// tests: the mount point is a plain directory standing in for the RAM disk (no hdiutil)
@property (nonatomic) BOOL testWithoutDisk;
@property (nonatomic) NSInteger testStopAfter;   // tests: a sync stops after this many replacements (-1: off)
@end

// pure (tests): whether a profile entry (relative path) is a cache that never leaves RAM
BOOL SFYTRamProfileSkips(NSString *relativePath);
// pure (tests): from `hdiutil info` before and after a timed out attach, the devices it left -
// exactly ram://<sectors>, not mounted, new
NSArray *SFYTRamOrphans(NSString *before, NSString *after, NSUInteger sectors);
