// SFDownloads – core: persistence (downloads table), queries, actions and migration;
// the queue and ffmpeg run: SFDownloads+Worker.m. Subscriptions: SFDownloads+Subscriptions.m; shared ivars: +Private.h.
#import "SFDownloads+Private.h"
#import "SFMediaStore.h"
#import <signal.h>

NSString *const SFDownloadsDidChangeNotification = @"SFDownloadsDidChangeNotification";
NSString *const SFDownloadsStorageDidChangeNotification = @"SFDownloadsStorageDidChangeNotification";
NSString *const SFUnsortedChannel = @"Einzelne Videos";




static NSString *ffmpegPath(void) {
    for (NSString *p in @[SFTool(@"ffmpeg"), @"/usr/local/bin/ffmpeg"])
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
    return nil;
}

@implementation SFDownloads

+ (NSString *)ffmpegToolPath { return ffmpegPath(); }

+ (instancetype)shared {
    static SFDownloads *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFDownloads new]; });
    return s;
}

- (SFMediaStore *)mediaStore {
    static SFMediaStore *m; static dispatch_once_t o;
    dispatch_once(&o, ^{
        m = [[SFMediaStore alloc] initWithDirectory:[[SFDownloads root] stringByAppendingPathComponent:@".store"]];
        m.reserve = (long long)self.storageReserve;
        // a downloaded item (a download record: kept until the user deletes it) is never evicted
        m.isPinned = ^BOOL(NSString *item) { return [[SFDownloads shared] recordFor:item] != nil; };
    });
    return m;
}

// the real app: ~/Movies/Sofa; a dev instance keeps its downloads in its own data directory
+ (NSString *)root { return SFDevMode ? [SFAppSupportDir() stringByAppendingPathComponent:@"Downloads"] : [NSHomeDirectory() stringByAppendingPathComponent:@"Movies/Sofa"]; }

- (instancetype)init {
    if ((self = [super init])) {
        SFStore *st = [SFStore shared];
        _recs = [NSMutableDictionary new];
        _subs = [NSMutableDictionary new];
        _itemCache = [NSMutableDictionary new];
        for (NSDictionary *row in [st rows:@"SELECT d.*, i.json AS item FROM downloads d LEFT JOIN items i ON i.id = d.id" args:nil]) {
            SFDownloadRecord *r = [SFDownloadRecord recordWithRow:row];
            if (r.identifier) _recs[r.identifier] = r;
        }
        for (NSDictionary *row in [st rows:@"SELECT * FROM subscriptions" args:nil]) {
            SFSubscription *sub = [SFSubscription subscriptionWithRow:row];
            if (sub.identifier) _subs[sub.identifier] = sub;
        }
        // re-queue runs interrupted last time
        for (SFDownloadRecord *r in _recs.allValues)
            if (r.state == SFDLRunning) { r.state = SFDLQueued; _resumeID = r.identifier; }
        SFLog(@"downloads: %lu entries, %lu subscriptions", (unsigned long)_recs.count, (unsigned long)_subs.count);
        __weak SFDownloads *ws = self;
        SFSetLocalFileLookup(^NSString *(NSString *ident) { return [ws fileFor:ident]; });
    }
    return self;
}

#pragma mark Persistence

- (void)save:(SFDownloadRecord *)r {
    NSArray *w = [self write:r];
    [[SFStore shared] run:w[0] args:w[1]];
}

// the statement that stores a record (save:, or several in one runAll:)
- (NSArray *)write:(SFDownloadRecord *)r {
    [_itemCache removeObjectForKey:r.identifier];
    _generation++;
    return r.writeStatement;
}



// Re-queues repairs whose backoff has elapsed and schedules itself for the next one that becomes
// due (before: only at start and every 3 h, so a 15-min backoff could take hours). Also called at
// start, after a failed repair and with every subscription check.
- (void)retryDueRepairs {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970, next = 0;
    NSMutableArray *writes = [NSMutableArray new];
    for (SFDownloadRecord *r in _recs.allValues) {
        if (r.state != SFDLDone || !r.retryAt) continue;   // no repair pending
        NSTimeInterval due = r.retryAt;
        if (due > now) { next = next ? MIN(next, due) : due; continue; }
        if (!r.path || ![[NSFileManager defaultManager] fileExistsAtPath:r.path]) continue;
        SFLog(@"downloads: retrying the repair of %@ (attempt %ld)", r.identifier, (long)r.tries + 1);
        r.error = nil; r.retryAt = 0;
        r.state = SFDLQueued; r.progress = 0;
        [writes addObject:[self write:r]]; [self changed:r.identifier];
    }
    if (writes.count) { [[SFStore shared] runAll:writes]; [self pump]; }
    if (next && (!_repairWake || next < _repairWake || _repairWake <= now)) {
        _repairWake = next;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((next - now + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_repairWake == next) self->_repairWake = 0;
            [self retryDueRepairs];
        });
    }
}

- (void)expireRepairBackoffForTesting {
    for (SFDownloadRecord *r in _recs.allValues) if (r.state == SFDLDone && r.retryAt) r.retryAt = 1;   // due long ago
}

- (BOOL)willRetry:(NSString *)identifier {
    return [self recOf:identifier].state == SFDLRetrying;
}

- (void)storageChangedSoon {
    if (_storagePostPending) return;
    _storagePostPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_storagePostPending = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:SFDownloadsStorageDidChangeNotification object:self];
    });
}

- (void)changed:(NSString *)identifier {
    SFMain(^{ [[NSNotificationCenter defaultCenter] postNotificationName:SFDownloadsDidChangeNotification object:identifier]; });
}

// The record's item: its metadata goes to the shared items table, the record keeps the JSON for
// parseRec (until the next launch reads it back from there)
- (void)setItem:(SFItem *)item ofRec:(SFDownloadRecord *)r {
    r.itemJSON = [[SFStore shared] saveItem:item];
}

#pragma mark Queries

- (SFDLState)stateFor:(NSString *)identifier progress:(double *)progress {
    SFDownloadRecord *r = identifier ? _recs[identifier] : nil;
    if (!r) return SFDLNone;
    if (progress) *progress = r.progress;
    if (r.state == SFDLDone && ![self fileExists:r]) return SFDLNone;
    return r.state;
}

- (SFDownloadRecord *)recOf:(NSString *)identifier { return identifier ? _recs[identifier] : nil; }

- (BOOL)fileExists:(SFDownloadRecord *)r {
    return r.path && [[NSFileManager defaultManager] fileExistsAtPath:r.path];
}

- (NSString *)fileFor:(NSString *)identifier {
    SFDownloadRecord *r = identifier ? _recs[identifier] : nil;
    return r.state == SFDLDone && [self fileExists:r] ? r.path : nil;
}

- (SFItem *)itemFromRec:(SFDownloadRecord *)r {
    SFItem *c = _itemCache[r.identifier];
    if (c) return c;
    c = [self parseRec:r];
    if (c) _itemCache[r.identifier] = c;
    return c;
}

- (SFItem *)parseRec:(SFDownloadRecord *)r {
    NSDictionary *d = SFJSONParse(r.itemJSON ?: @"{}");
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    SFItem *i = [SFItem itemWithDictionary:d];
    if (r.state == SFDLDone && r.path) {
        i.localPath = r.path;
        i.playURL = [NSURL fileURLWithPath:r.path];
    }
    if (r.thumb && [[NSFileManager defaultManager] fileExistsAtPath:r.thumb]) { i.image = r.thumb; i.backdrop = i.backdrop ?: r.thumb; }
    // the download's own facts: its show's name, the publication time it learned (exact when the
    // source gave one - a list's "vor 2 Wochen" written to the item later must not replace it)
    if (r.channel.length) i.channel = r.channel;
    if (r.published > 0) i.date = [NSDate dateWithTimeIntervalSince1970:r.published];
    i.style = SFTileStyleLandscape;
    i.inDownloadsList = YES;
    return i;
}

- (SFItem *)itemFor:(NSString *)identifier {
    SFDownloadRecord *r = identifier ? _recs[identifier] : nil;
    return r.state == SFDLDone && [self fileExists:r] ? [self itemFromRec:r] : nil;
}

- (NSArray *)recsWithState:(SFDLState)st source:(NSString *)source {
    NSMutableArray *a = [NSMutableArray new];
    for (SFDownloadRecord *r in _recs.allValues)
        if (r.state == st && (!source || [r.source isEqualToString:source])) [a addObject:r];
    [a sortUsingComparator:^NSComparisonResult(SFDownloadRecord *x, SFDownloadRecord *y) {
        double px = x.published ?: x.added, py = y.published ?: y.added;
        return px > py ? NSOrderedAscending : px < py ? NSOrderedDescending : NSOrderedSame;
    }];
    return a;
}

- (NSArray *)items:(NSString *)source {
    NSMutableArray *out = [NSMutableArray new];
    for (SFDownloadRecord *r in [self recsWithState:SFDLDone source:source]) {
        if (![self fileExists:r]) continue;
        SFItem *i = [self itemFromRec:r];
        if (i) [out addObject:i];
    }
    return out;
}

- (NSArray *)active {
    NSMutableArray *out = [NSMutableArray new];
    for (NSNumber *st in @[@(SFDLRunning), @(SFDLQueued)])
        for (SFDownloadRecord *r in [self recsWithState:st.integerValue source:nil]) { SFItem *i = [self itemFromRec:r]; if (i) [out addObject:i]; }
    return out;
}

- (unsigned long long)bytesUsedFor:(NSString *)source {
    unsigned long long n = 0;
    for (SFDownloadRecord *r in _recs.allValues)
        if (r.state == SFDLDone && (!source || [r.source isEqualToString:source])) n += r.bytes;
    return n;
}

- (unsigned long long)freeBytes {
    NSString *root = [SFDownloads root];
    NSString *p = [[NSFileManager defaultManager] fileExistsAtPath:root] ? root : NSHomeDirectory();
    return [[[NSFileManager defaultManager] attributesOfFileSystemForPath:p error:nil][NSFileSystemFreeSize] unsignedLongLongValue];
}

static NSString *gb(unsigned long long b) {
    if (b < 1000000000ULL) return [NSString stringWithFormat:@"%llu MB", b / 1000000ULL];
    return [NSString stringWithFormat:@"%.0f GB", b / 1e9];
}

- (SFDownloadRecord *)recordFor:(NSString *)identifier {
    SFDownloadRecord *r = identifier ? _recs[identifier] : nil;
    return r.state == SFDLDone ? [r copy] : nil;
}

- (NSString *)storageSummary:(NSString *)source {
    return [NSString stringWithFormat:@"%@ belegt · %@ frei", gb([self bytesUsedFor:source]), gb([self freeBytes])];
}

- (NSUInteger)removeAllOfChannel:(NSString *)channel source:(NSString *)source {
    NSUInteger n = 0;
    for (SFDownloadRecord *r in [_recs.allValues copy]) {
        NSString *rc = r.channel.length ? r.channel : SFUnsortedChannel;
        if (![rc isEqualToString:channel] || (source && ![r.source isEqualToString:source])) continue;
        if (r.state == SFDLDismissed || r.keep) continue;   // "Behalten" survives deleting the show
        [self remove:r.identifier];
        n++;
    }
    SFLog(@"downloads: deleted %lu downloads of %@", (unsigned long)n, channel);
    return n;
}

#pragma mark Actions

- (void)download:(SFItem *)item { [self enqueue:item sub:nil]; }

- (BOOL)enqueue:(SFItem *)item sub:(NSString *)subID {
    if (!item.identifier || item.kind != SFItemVideo) return NO;
    SFDownloadRecord *r = _recs[item.identifier];
    SFDLState st = r ? r.state : SFDLNone;
    if (r && (st == SFDLQueued || st == SFDLRunning || (st == SFDLDone && [self fileFor:item.identifier]))) return NO;
    if (subID && r && st == SFDLDismissed) return NO;
    if (subID && r && (st == SFDLFailed || st == SFDLRetrying)) {
        if (r.tries >= kSubMaxTries) return NO;                                   // given up
        if ([NSDate date].timeIntervalSince1970 < r.retryAt) return NO;          // keep waiting
    }
    if (subID && r && !r.sub) subID = nil;   // downloaded manually once = manual (no retention)
    // subscription episodes belong to the subscription's show (ZDF/ARD often name the series
    // differently) - the download's channel; the item itself keeps its source's
    NSString *subTitle = subID ? [[SFFollows shared] recordOf:subID].title : nil;
    r = r ?: [SFDownloadRecord new];
    r.identifier = item.identifier;
    r.source = item.source ?: @"";
    r.channel = subTitle.length ? subTitle : item.channel ?: @"";
    [self setItem:item ofRec:r];
    r.state = SFDLQueued;
    r.progress = 0;
    r.added = [[NSDate date] timeIntervalSince1970];
    if (item.date) r.published = [item.date timeIntervalSince1970];
    r.sub = subID;   // nil = manual: never deleted automatically
    if (!subID) r.tries = 0;
    r.error = nil; r.retryAt = 0;
    _recs[item.identifier] = r;
    [self save:r];
    [self changed:item.identifier];
    SFLog(@"downloads: + %@ (%@)", item.title, subID ? @"subscription" : @"manual");
    [self pump];
    return YES;
}

- (void)remove:(NSString *)identifier {
    SFDownloadRecord *r = _recs[identifier];
    if (!r) return;
    if ([identifier isEqualToString:_runningID]) {   // running: free the slot right away, drop the callbacks
        NSTask *t = _task;
        _task = nil; _runningID = nil;
        [t terminate];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pump]; });
    }
    if (r.path) [[NSFileManager defaultManager] removeItemAtPath:r.path error:nil];
    if (r.thumb) [[NSFileManager defaultManager] removeItemAtPath:r.thumb error:nil];
    [self pruneEmptyDirs:[r.path stringByDeletingLastPathComponent]];
    if (r.sub) {   // subscription episode: remember it so it does not come back
        r.state = SFDLDismissed; r.bytes = 0; r.path = nil;
        [self save:r];
    } else {
        [_recs removeObjectForKey:identifier];
        [_itemCache removeObjectForKey:identifier];
        _generation++;
        [[SFStore shared] run:@"DELETE FROM downloads WHERE id=?" args:@[identifier]];
    }
    [self changed:identifier];
    [self storageChangedSoon];   // "Platz schaffen" follows (coalesced: bulk deletions post once)
    if (_storageFull) dispatch_async(dispatch_get_main_queue(), ^{ [self pump]; });   // room again? (pump re-checks)
}

- (void)pruneEmptyDirs:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [SFDownloads root];
    NSSet *decor = [NSSet setWithArray:@[@".DS_Store", @"poster.jpg", @"fanart.jpg"]];   // show artwork does not count as content
    while (dir.length > root.length && [dir hasPrefix:root]) {
        NSArray *c = [fm contentsOfDirectoryAtPath:dir error:nil];
        BOOL empty = YES;
        for (NSString *f in c) if (![decor containsObject:f]) { empty = NO; break; }
        if (!empty) break;
        [fm removeItemAtPath:dir error:nil];
        dir = [dir stringByDeletingLastPathComponent];
    }
}

#pragma mark Worker

- (void)stopForExit {
    NSTask *t = _task;
    if (!t.isRunning) return;
    SFLog(@"downloads: stopping ffmpeg before exit (%@ resumes on the next start)", _runningID);
    // not a failure: let go of it first, so its termination handler only removes the part file
    // (it stays Running in the database; the next start queues it again). Before 2026-11-06 a
    // handler that still ran (update restart) counted it as a failed attempt.
    _task = nil; _runningID = nil;
    pid_t pid = t.processIdentifier;
    [t terminate];
    for (int i = 0; i < 20 && t.isRunning; i++) usleep(50 * 1000);
    if (t.isRunning) kill(pid, SIGKILL);
}


- (void)start {
    if (_started || _starting) return;
    _starting = YES;
    // orphans first, before anything writes: no second writer may survive from an earlier run. The
    // process list is a sysctl walk (80 ms of the main thread at launch, hitch monitor 2026-11-07):
    // off it - the worker waits for _started.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self reapOrphans];
        SFMain(^{ self->_started = YES; [self startWorking]; });
    });
}

- (void)startWorking {
    [self sweepStaleParts];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self retryDueRepairs];
        [self auditExistingDownloads];
    });
    [[NSNotificationCenter defaultCenter] addObserverForName:SFNetOnlineDidChangeNotification object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { if ([SFNet isOnline]) [self pump]; }];
    [self pump];
    [self retryDueRepairs];   // due repairs go now, the others are scheduled for when they become due
    // subscriptions: a follow with news (its own refresh plan), plus all of them locally shortly
    // after start and every 3 h with the repairs
    [[NSNotificationCenter defaultCenter] addObserverForName:SFFollowsNewItemsNotification object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { SFSubscription *s = self->_subs[n.object]; if (s) [self checkSub:s]; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self checkSubscriptionsNow]; });
    _checkTimer = [NSTimer scheduledTimerWithTimeInterval:3 * 3600 target:self selector:@selector(checkSubscriptionsNow) userInfo:nil repeats:YES];
}

#pragma mark Paths

- (NSString *)folderForSource:(NSString *)source channel:(NSString *)channel {
    return [[[SFDownloads root] stringByAppendingPathComponent:safeName(source ?: @"", 20)] stringByAppendingPathComponent:safeName(channel ?: @"Einzelne", 80)];
}

#pragma mark Migration

- (BOOL)adoptFile:(NSString *)path item:(SFItem *)item thumb:(NSString *)thumb subscription:(NSString *)subID error:(NSError **)err {
    if (!item.identifier || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
    if ([self fileFor:item.identifier]) { if (err) *err = SFError(@"bereits vorhanden"); return NO; }
    SFDownloadRecord *r = [SFDownloadRecord new];
    r.identifier = item.identifier; r.source = item.source ?: @""; r.channel = item.channel ?: @"";
    r.state = SFDLDone; r.progress = 1; r.added = [[NSDate date] timeIntervalSince1970];
    [self setItem:item ofRec:r];
    if (item.date) r.published = [item.date timeIntervalSince1970];
    r.sub = subID;
    NSString *target = [self targetPathFor:r item:item];
    if (![path.pathExtension.lowercaseString isEqualToString:@"mp4"]) target = [[target stringByDeletingPathExtension] stringByAppendingPathExtension:path.pathExtension];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[target stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm moveItemAtPath:path toPath:target error:err]) return NO;      // same volume: just rename
    r.path = target;
    r.bytes = [[fm attributesOfItemAtPath:target error:nil] fileSize];
    if (thumb && [fm fileExistsAtPath:thumb]) {
        NSString *tt = [[target stringByDeletingPathExtension] stringByAppendingString:@".jpg"];
        if ([fm moveItemAtPath:thumb toPath:tt error:nil]) r.thumb = tt;
    }
    _recs[item.identifier] = r;
    [self save:r];
    return YES;
}
@end
