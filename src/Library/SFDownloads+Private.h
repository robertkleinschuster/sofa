// SFDownloads – private part: ivars and shared helpers for SFDownloads.m (persistence, queries,
// actions), SFDownloads+Worker.m (queue, the fill of the media store), SFDownloads+Subscriptions.m
// (subscriptions, feeds, pre-buffering), SFDownloads+Storage.m (storage guard, "Behalten", online
// checks) and SFDownloads+Integrity.m (completeness in the store).
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
    dispatch_block_t _fillCancel;    // cancels the running fill
    NSString *_runningID;
    BOOL _started;                   // the worker may run
    NSTimer *_checkTimer;
    NSTimeInterval _pauseWake;
    NSMutableDictionary *_subStarts;   // source prefix -> epochs of subscription download starts within 24 h (persisted)
    NSMutableDictionary *_nextStart;   // source prefix -> earliest next download start (epoch; persisted, a restart keeps the spacing)   // pump already scheduled for when a paused source may continue
    NSMutableDictionary *_itemCache; // id -> SFItem (from JSON), invalidated by save:
    NSUInteger _generation;          // storage of the generation property (also for the subscription category)
    BOOL _storageFull;               // below the reserve (SFDownloads+Storage.m)
    NSTimer *_storageTimer;          // re-check while full
    NSTimer *_diskWatch;             // disk check while a download runs
    NSString *_resumeID;             // the run an exit interrupted: continues at once, not after the source's spacing
    NSMutableDictionary *_diskNeed;  // id -> bytes needed after a disk stop (hysteresis)
    NSString *_onlineCurrent;        // identifier being checked right now
    BOOL _storagePostPending;        // a coalesced storage notification is queued
    BOOL _checkingOnline;            // an online check run is active
    NSMutableArray *_onlineQueue;    // identifiers waiting for an online check
    NSMutableArray *_onlineDone;     // completion blocks of checkOnline:done:
}
// Items the media store never evicts: downloads, and what a pending download (queued, running,
// retrying) is going to read. A snapshot the main thread swaps on every record write - the store asks
// from its own queue and must never touch _recs.
@property (atomic, copy) NSSet *storePinned;
- (void)save:(SFDownloadRecord *)r;
- (SFDownloadRecord *)recOf:(NSString *)identifier;   // the record (not a copy); nil = none
- (NSArray *)write:(SFDownloadRecord *)r;   // the statement save: runs - for several records in one runAll:
- (void)changed:(NSString *)identifier;
- (void)storageChangedSoon;   // SFDownloadsStorageDidChangeNotification, coalesced
- (BOOL)enqueue:(SFItem *)item sub:(NSString *)subID;   // NO = already present/rejected
- (SFItem *)itemFromRec:(SFDownloadRecord *)r;
- (void)setItem:(SFItem *)item ofRec:(SFDownloadRecord *)r;   // item JSON in the record + the items table
+ (NSString *)root;
@end

// Pre-buffering (docs/media-store.md phase 3, agreed with the user 2026-11-08): a subscription episode
// in the media store stays until watched plus kAfterWatchedDays, at most kPrebufferDays after it was
// complete; "Behalten" or "Herunterladen" keeps it.
static const double kPrebufferDays = 14, kAfterWatchedDays = 3;

@interface SFDownloads (SubscriptionsPrivate)
- (void)checkSub:(SFSubscription *)s;   // against its follow's list (no request)
// expired pre-buffered episodes leave (dismissed: not fetched again; their bytes become plain buffer)
- (void)expirePrebuffers;
@end

// Worker (SFDownloads+Worker.m): next download, its fill, outcome
@interface SFDownloads (Worker)
- (void)pump;
- (void)pumpAt:(NSTimeInterval)when;
- (void)fetchThumb:(SFItem *)item rec:(SFDownloadRecord *)r;
- (void)finish:(NSString *)ident ok:(BOOL)ok error:(NSString *)error;
- (BOOL)abortRun;   // the running download ends without a verdict (exit, removal, disk); NO = none ran
@end

// Storage layer (SFDownloads+Storage.m): disk reserve, "Behalten", online availability
@interface SFDownloads (StoragePrivate)
- (BOOL)checkStorageFor:(SFDownloadRecord *)next;   // YES = not enough room for it: don't start (re-check scheduled, notifies)
- (void)stopIfDiskRunsOut;     // during a run: stop it when the reserve is half used up
- (void)watchDiskDuringRun:(BOOL)on;   // 10-s disk check while a download runs
- (void)setStorageFull:(BOOL)full;
@end

@interface SFDownloads (Integrity)
// downloads whose tracks are not complete any more (block files gone from outside): queued again - the
// fill fetches only what is missing. Once per launch.
- (void)verifyStoreDownloads;
@end
