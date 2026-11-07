// SFDownloads – private part: ivars and shared helpers for SFDownloads.m (persistence,
// queries, actions, migration), SFDownloads+Worker.m (queue, ffmpeg run), SFDownloads+Subscriptions.m
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

// helpers shared by SFDownloads.m and its parts
static inline NSString *safeName(NSString *s, NSUInteger max) {
    NSMutableString *o = [NSMutableString new];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '/' || c == ':' || c < 32) [o appendString:@"-"];
        else [o appendFormat:@"%C", c];
    }
    NSString *t = [o stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ."]];
    if (t.length > max) t = [t substringToIndex:max];
    return t.length ? t : @"Video";
}

static inline NSString *idHash(NSString *s) {   // FNV-1a 64 bit, stable
    uint64_t h = 1469598103934665603ULL;
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *b = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) { h ^= b[i]; h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)h];
}

// Subscription episodes: retry failed downloads with growing intervals (15 min, 30 min, 1 h …,
// ~16 h in total). YouTube throttles at times ("Sign in to confirm you're not a bot") – without
// spacing, the attempts were used up within minutes and the episode was lost for good.
static const NSInteger kSubMaxTries = 6;
static inline NSTimeInterval SFRetryDelay(NSInteger tries) {
    static double base;   // 15 min; tests shorten it (SOFA_RETRY_BASE)
    static dispatch_once_t once;
    dispatch_once(&once, ^{ base = SFDevSeconds(@"SOFA_RETRY_BASE", 900); });
    return base * (1 << MAX(0, MIN(tries, 10) - 1));
}


@interface SFDownloads () {
    NSMutableDictionary *_recs;      // id -> SFDownloadRecord
    NSMutableDictionary *_subs;      // id -> SFSubscription
    NSTask *_task;
    NSString *_runningID;
    BOOL _started, _starting;   // _started: orphans reaped, the worker may write
    NSTimer *_checkTimer;
    NSTimeInterval _pauseWake;
    NSTimeInterval _repairWake;  // retryDueRepairs scheduled for this time (epoch)
    NSMutableDictionary *_nextStart;   // source prefix -> earliest next download start (epoch; persisted, a restart keeps the spacing)   // pump already scheduled for when a paused source may continue
    NSMutableDictionary *_itemCache; // id -> SFItem (from JSON), invalidated by save:
    NSUInteger _generation;          // storage of the generation property (also for the subscription category)
    BOOL _storageFull;               // below the reserve (SFDownloads+Storage.m)
    NSTimer *_storageTimer;          // re-check while full
    NSTimer *_diskWatch;             // disk check while ffmpeg runs
    NSString *_runningPart;          // part file of the running download
    NSString *_resumeID;             // the run an exit interrupted: continues at once, not after the source's spacing
    NSMutableDictionary *_diskNeed;  // id -> bytes needed after a disk stop (hysteresis)
    NSString *_onlineCurrent;        // identifier being checked right now
    BOOL _storagePostPending;        // a coalesced storage notification is queued
    BOOL _checkingOnline;            // an online check run is active
    NSMutableArray *_onlineQueue;    // identifiers waiting for an online check
    NSMutableArray *_onlineDone;     // completion blocks of checkOnline:done:
}
- (void)save:(SFDownloadRecord *)r;
- (BOOL)fileExists:(SFDownloadRecord *)r;   // its file is there
- (SFDownloadRecord *)recOf:(NSString *)identifier;   // the record (not a copy); nil = none
- (NSArray *)write:(SFDownloadRecord *)r;   // the statement save: runs - for several records in one runAll:
- (void)changed:(NSString *)identifier;
- (BOOL)enqueue:(SFItem *)item sub:(NSString *)subID;   // NO = already present/rejected
- (void)retryDueRepairs;
- (void)expireRepairBackoffForTesting;   // dev command dlretry
- (SFItem *)itemFromRec:(SFDownloadRecord *)r;
- (void)setItem:(SFItem *)item ofRec:(SFDownloadRecord *)r;   // item JSON in the record + the items table
+ (NSString *)ffmpegToolPath;
+ (NSString *)root;
@end

@interface SFDownloads (SubscriptionsPrivate)
- (void)checkSub:(SFSubscription *)s;   // against its follow's list (no request)
@end

// Worker (SFDownloads+Worker.m): next download, ffmpeg run, install, outcome
@interface SFDownloads (Worker)
- (void)pump;
- (void)pumpAt:(NSTimeInterval)when;
- (NSString *)targetPathFor:(SFDownloadRecord *)r item:(SFItem *)item;
- (void)fetchThumb:(SFItem *)item rec:(SFDownloadRecord *)r;
- (void)finish:(NSString *)ident ok:(BOOL)ok error:(NSString *)error;
@end

// Integrity layer (SFDownloads+Integrity.m): orphan reaping, unique part files, verification, audit
// Storage layer (SFDownloads+Storage.m): disk reserve, "Behalten", online availability
@interface SFDownloads (StoragePrivate)
- (BOOL)checkStorageFor:(SFDownloadRecord *)next;   // YES = not enough room for it: don't start (re-check scheduled, notifies)
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
