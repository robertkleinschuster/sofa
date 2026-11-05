// SFDownloads – private part: ivars and shared helpers for SFDownloads.m (persistence,
// queries, queue, ffmpeg run, actions, migration) and SFDownloads+Subscriptions.m
// (subscriptions, feeds) and SFDownloads+Storage.m (storage guard, "Behalten", online checks).
// Downloads are never deleted automatically (user 2026-11-05: a video may vanish from its source,
// then the copy is the only one) - only by hand, helped by the "Platz schaffen" page.
#import "SFDownloads.h"
#import "SFSettings.h"
#import "SFStore.h"
#import "SFCurl.h"
#import "SFNet.h"
#import "SFFollows.h"
#import "SFRuntime.h"
#import "SFStats.h"

// split a source ID "prefix:rest" (yt:…, zdfshow:…)
static inline NSString *prefixOf(NSString *ref) { NSRange r = [ref rangeOfString:@":"]; return r.location == NSNotFound ? nil : [ref substringToIndex:r.location]; }
static inline NSString *restOf(NSString *ref) { NSRange r = [ref rangeOfString:@":"]; return r.location == NSNotFound ? ref : [ref substringFromIndex:NSMaxRange(r)]; }

@interface SFDownloads () {
    NSMutableDictionary *_recs;      // id -> NSMutableDictionary (columns of the downloads table)
    NSMutableDictionary *_subs;      // id -> NSMutableDictionary
    NSTask *_task;
    NSString *_runningID;
    BOOL _started, _checking;
    NSTimer *_checkTimer;
    NSTimeInterval _pauseWake;
    NSTimeInterval _repairWake;  // retryDueRepairs scheduled for this time (epoch)
    NSMutableDictionary *_lastStart;   // source prefix -> epoch of its last download start   // pump already scheduled for when a paused source may continue
    NSMutableDictionary *_itemCache; // id -> SFItem (from JSON), invalidated by save:
    NSUInteger _generation;          // storage of the generation property (also for the subscription category)
    BOOL _storageFull;               // below the reserve (SFDownloads+Storage.m)
    NSTimer *_storageTimer;          // re-check while full
    NSTimer *_diskWatch;             // disk check while ffmpeg runs
    NSString *_runningPart;          // part file of the running download
    NSMutableDictionary *_diskNeed;  // id -> bytes needed after a disk stop (hysteresis)
    NSString *_onlineCurrent;        // identifier being checked right now
    BOOL _storagePostPending;        // a coalesced storage notification is queued
    BOOL _checkingOnline;            // an online check run is active
    NSMutableArray *_onlineQueue;    // identifiers waiting for an online check
    NSMutableArray *_onlineDone;     // completion blocks of checkOnline:done:
}
- (void)save:(NSDictionary *)r;
- (void)changed:(NSString *)identifier;
- (BOOL)enqueue:(SFItem *)item sub:(NSString *)subID;   // NO = already present/rejected
- (void)pump;
- (void)retryDueRepairs;
- (void)expireRepairBackoffForTesting;   // dev command dlretry
- (SFItem *)itemFromRec:(NSDictionary *)r;
+ (NSString *)ffmpegToolPath;
+ (NSString *)root;
@end

// Integrity layer (SFDownloads+Integrity.m): orphan reaping, unique part files, verification, audit
// Storage layer (SFDownloads+Storage.m): disk reserve, "Behalten", online availability
@interface SFDownloads (StoragePrivate)
- (BOOL)checkStorageFor:(NSDictionary *)next;   // YES = not enough room for it: don't start (re-check scheduled, notifies)
- (void)stopIfDiskRunsOut;     // during a run: stop ffmpeg when the reserve is half used up
- (void)watchDiskDuringRun:(BOOL)on;   // 10-s disk check while ffmpeg runs
- (void)setStorageFull:(BOOL)full;
@end

@interface SFDownloads (Integrity)
- (NSUInteger)reapOrphans;
- (void)sweepStaleParts;
- (NSString *)partSuffix;
- (void)auditExistingDownloads;
+ (NSString *)problemWithFile:(NSString *)path expectedDuration:(double)expected ffmpeg:(NSString *)ff;
@end
