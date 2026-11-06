// SFDownloads – core: persistence (downloads table), queries, actions and migration;
// the queue and ffmpeg run: SFDownloads+Worker.m. Subscriptions: SFDownloads+Subscriptions.m; shared ivars: +Private.h.
#import "SFDownloads+Private.h"
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

// the real app: ~/Movies/Sofa; a dev instance keeps its downloads in its own data directory
+ (NSString *)root { return SFDevMode ? [SFAppSupportDir() stringByAppendingPathComponent:@"Downloads"] : [NSHomeDirectory() stringByAppendingPathComponent:@"Movies/Sofa"]; }

- (instancetype)init {
    if ((self = [super init])) {
        SFStore *st = [SFStore shared];
        _recs = [NSMutableDictionary new];
        _subs = [NSMutableDictionary new];
        _itemCache = [NSMutableDictionary new];
        for (NSDictionary *r in [st rows:@"SELECT * FROM downloads" args:nil]) _recs[r[@"id"]] = [r mutableCopy];
        for (NSDictionary *r in [st rows:@"SELECT * FROM subscriptions" args:nil]) _subs[r[@"id"]] = [r mutableCopy];
        // re-queue runs interrupted last time
        for (NSMutableDictionary *r in _recs.allValues)
            if ([r[@"state"] integerValue] == SFDLRunning) r[@"state"] = @(SFDLQueued);
        SFLog(@"downloads: %lu entries, %lu subscriptions", (unsigned long)_recs.count, (unsigned long)_subs.count);
        __weak SFDownloads *ws = self;
        SFSetLocalFileLookup(^NSString *(NSString *ident) { return [ws fileFor:ident]; });
    }
    return self;
}

#pragma mark Persistence

- (void)save:(NSDictionary *)r {
    NSArray *w = [self write:r];
    [[SFStore shared] run:w[0] args:w[1]];
}

// the statement that stores a record (save:, or several in one runAll:)
- (NSArray *)write:(NSDictionary *)r {
    [_itemCache removeObjectForKey:r[@"id"]];
    _generation++;
    return @[@"INSERT OR REPLACE INTO downloads (id,source,channel,item,path,thumb,state,progress,bytes,added,published,sub,error,tries,retryAt,keep,online,onlineAt) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
             @[r[@"id"], r[@"source"] ?: [NSNull null], r[@"channel"] ?: [NSNull null], r[@"item"] ?: [NSNull null],
               r[@"path"] ?: [NSNull null], r[@"thumb"] ?: [NSNull null], r[@"state"] ?: @0, r[@"progress"] ?: @0.0,
               r[@"bytes"] ?: @0, r[@"added"] ?: @0.0, r[@"published"] ?: [NSNull null], r[@"sub"] ?: [NSNull null],
               r[@"error"] ?: [NSNull null], r[@"tries"] ?: @0, r[@"retryAt"] ?: [NSNull null],
               r[@"keep"] ?: @0, r[@"online"] ?: [NSNull null], r[@"onlineAt"] ?: [NSNull null]]];
}



// Re-queues repairs whose backoff has elapsed and schedules itself for the next one that becomes
// due (before: only at start and every 3 h, so a 15-min backoff could take hours). Also called at
// start, after a failed repair and with every subscription check.
- (void)retryDueRepairs {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970, next = 0;
    NSMutableArray *writes = [NSMutableArray new];
    for (NSMutableDictionary *r in _recs.allValues) {
        if ([r[@"state"] integerValue] != SFDLDone || !r[@"retryAt"]) continue;   // no repair pending
        NSTimeInterval due = [r[@"retryAt"] doubleValue];
        if (due > now) { next = next ? MIN(next, due) : due; continue; }
        if (![[NSFileManager defaultManager] fileExistsAtPath:r[@"path"]]) continue;
        SFLog(@"downloads: retrying the repair of %@ (attempt %ld)", r[@"id"], (long)[r[@"tries"] integerValue] + 1);
        [r removeObjectForKey:@"error"]; [r removeObjectForKey:@"retryAt"];
        r[@"state"] = @(SFDLQueued); r[@"progress"] = @0;
        [writes addObject:[self write:r]]; [self changed:r[@"id"]];
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
    for (NSMutableDictionary *r in _recs.allValues) if ([r[@"state"] integerValue] == SFDLDone && r[@"retryAt"]) r[@"retryAt"] = @0;
}

- (BOOL)willRetry:(NSString *)identifier {
    NSDictionary *r = _recs[identifier];
    return [r[@"state"] integerValue] == SFDLRetrying;
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

- (NSString *)itemJSON:(SFItem *)item {
    NSMutableDictionary *d = [[item dictionaryRepresentation] mutableCopy];
    [d removeObjectForKey:@"localPath"];
    return SFJSONString(d);
}

#pragma mark Queries

- (SFDLState)stateFor:(NSString *)identifier progress:(double *)progress {
    NSDictionary *r = identifier ? _recs[identifier] : nil;
    if (!r) return SFDLNone;
    if (progress) *progress = [r[@"progress"] doubleValue];
    SFDLState s = [r[@"state"] integerValue];
    if (s == SFDLDone && ![[NSFileManager defaultManager] fileExistsAtPath:r[@"path"]]) return SFDLNone;
    return s;
}

- (NSString *)fileFor:(NSString *)identifier {
    NSDictionary *r = identifier ? _recs[identifier] : nil;
    if ([r[@"state"] integerValue] != SFDLDone) return nil;
    return [[NSFileManager defaultManager] fileExistsAtPath:r[@"path"]] ? r[@"path"] : nil;
}

- (SFItem *)itemFromRec:(NSDictionary *)r {
    SFItem *c = _itemCache[r[@"id"]];
    if (c) return c;
    c = [self parseRec:r];
    if (c) _itemCache[r[@"id"]] = c;
    return c;
}

- (SFItem *)parseRec:(NSDictionary *)r {
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[r[@"item"] ?: @"{}" dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    SFItem *i = [SFItem itemWithDictionary:d];
    if ([r[@"state"] integerValue] == SFDLDone) {
        i.localPath = r[@"path"];
        i.playURL = [NSURL fileURLWithPath:r[@"path"]];
    }
    if (r[@"thumb"] && [[NSFileManager defaultManager] fileExistsAtPath:r[@"thumb"]]) { i.image = r[@"thumb"]; i.backdrop = i.backdrop ?: r[@"thumb"]; }
    if (!i.date && [r[@"published"] doubleValue] > 0) i.date = [NSDate dateWithTimeIntervalSince1970:[r[@"published"] doubleValue]];
    i.style = SFTileStyleLandscape;
    i.inDownloadsList = YES;
    return i;
}

- (SFItem *)itemFor:(NSString *)identifier {
    NSDictionary *r = identifier ? _recs[identifier] : nil;
    if ([r[@"state"] integerValue] != SFDLDone || ![self fileFor:identifier]) return nil;
    return [self itemFromRec:r];
}

- (NSArray *)recsWithState:(SFDLState)st source:(NSString *)source {
    NSMutableArray *a = [NSMutableArray new];
    for (NSDictionary *r in _recs.allValues) {
        if ([r[@"state"] integerValue] != st) continue;
        if (source && ![r[@"source"] isEqualToString:source]) continue;
        [a addObject:r];
    }
    [a sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        double px = [x[@"published"] doubleValue] ?: [x[@"added"] doubleValue], py = [y[@"published"] doubleValue] ?: [y[@"added"] doubleValue];
        return px > py ? NSOrderedAscending : px < py ? NSOrderedDescending : NSOrderedSame;
    }];
    return a;
}

- (NSArray *)items:(NSString *)source {
    NSMutableArray *out = [NSMutableArray new];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSDictionary *r in [self recsWithState:SFDLDone source:source]) {
        if (![fm fileExistsAtPath:r[@"path"]]) continue;
        SFItem *i = [self itemFromRec:r];
        if (i) [out addObject:i];
    }
    return out;
}

- (NSArray *)active {
    NSMutableArray *out = [NSMutableArray new];
    for (NSNumber *st in @[@(SFDLRunning), @(SFDLQueued)])
        for (NSDictionary *r in [self recsWithState:st.integerValue source:nil]) { SFItem *i = [self itemFromRec:r]; if (i) [out addObject:i]; }
    return out;
}

- (unsigned long long)bytesUsedFor:(NSString *)source {
    unsigned long long n = 0;
    for (NSDictionary *r in _recs.allValues)
        if ([r[@"state"] integerValue] == SFDLDone && (!source || [r[@"source"] isEqualToString:source])) n += [r[@"bytes"] unsignedLongLongValue];
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

- (NSDictionary *)recordFor:(NSString *)identifier {
    NSDictionary *r = identifier ? _recs[identifier] : nil;
    return [r[@"state"] integerValue] == SFDLDone ? [r copy] : nil;
}

- (NSString *)storageSummary:(NSString *)source {
    return [NSString stringWithFormat:@"%@ belegt · %@ frei", gb([self bytesUsedFor:source]), gb([self freeBytes])];
}

- (NSUInteger)removeAllOfChannel:(NSString *)channel source:(NSString *)source {
    NSUInteger n = 0;
    for (NSDictionary *r in [_recs.allValues copy]) {
        NSString *rc = [r[@"channel"] length] ? r[@"channel"] : SFUnsortedChannel;
        if (![rc isEqualToString:channel] || (source && ![r[@"source"] isEqualToString:source])) continue;
        SFDLState st = [r[@"state"] integerValue];
        if (st == SFDLDismissed || [r[@"keep"] boolValue]) continue;   // "Behalten" survives deleting the show
        [self remove:r[@"id"]];
        n++;
    }
    SFLog(@"downloads: deleted %lu downloads of %@", (unsigned long)n, channel);
    return n;
}

#pragma mark Actions

- (void)download:(SFItem *)item { [self enqueue:item sub:nil]; }

- (BOOL)enqueue:(SFItem *)item sub:(NSString *)subID {
    if (!item.identifier || item.kind != SFItemVideo) return NO;
    NSMutableDictionary *r = _recs[item.identifier];
    SFDLState st = r ? [r[@"state"] integerValue] : SFDLNone;
    if (r && (st == SFDLQueued || st == SFDLRunning || (st == SFDLDone && [self fileFor:item.identifier]))) return NO;
    if (subID && r && st == SFDLDismissed) return NO;
    if (subID && r && (st == SFDLFailed || st == SFDLRetrying)) {
        if ([r[@"tries"] integerValue] >= kSubMaxTries) return NO;                                 // given up
        if ([NSDate date].timeIntervalSince1970 < [r[@"retryAt"] doubleValue]) return NO;          // keep waiting
    }
    if (subID && r && !r[@"sub"]) subID = nil;   // downloaded manually once = manual (no retention)
    // subscription episodes belong to the subscription's show (ZDF/ARD often name the series differently)
    NSString *subTitle = subID ? [[SFFollows shared] recordOf:subID][@"title"] : nil;
    if (subTitle.length) { item = [item copy]; item.channel = subTitle; }
    r = r ?: [NSMutableDictionary new];
    r[@"id"] = item.identifier;
    r[@"source"] = item.source ?: @"";
    r[@"channel"] = item.channel ?: @"";
    r[@"item"] = [self itemJSON:item];
    r[@"state"] = @(SFDLQueued);
    r[@"progress"] = @0;
    r[@"added"] = @([[NSDate date] timeIntervalSince1970]);
    if (item.date) r[@"published"] = @([item.date timeIntervalSince1970]);
    if (subID) r[@"sub"] = subID; else [r removeObjectForKey:@"sub"];   // manual = never delete automatically
    if (!subID) r[@"tries"] = @0;
    [r removeObjectForKey:@"error"]; [r removeObjectForKey:@"retryAt"];
    _recs[item.identifier] = r;
    [self save:r];
    [self changed:item.identifier];
    SFLog(@"downloads: + %@ (%@)", item.title, subID ? @"subscription" : @"manual");
    [self pump];
    return YES;
}

- (void)remove:(NSString *)identifier {
    NSMutableDictionary *r = _recs[identifier];
    if (!r) return;
    if ([identifier isEqualToString:_runningID]) {   // running: free the slot right away, drop the callbacks
        NSTask *t = _task;
        _task = nil; _runningID = nil;
        [t terminate];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pump]; });
    }
    if (r[@"path"]) [[NSFileManager defaultManager] removeItemAtPath:r[@"path"] error:nil];
    if (r[@"thumb"]) [[NSFileManager defaultManager] removeItemAtPath:r[@"thumb"] error:nil];
    [self pruneEmptyDirs:[r[@"path"] stringByDeletingLastPathComponent]];
    if (r[@"sub"]) {   // subscription episode: remember it so it does not come back
        r[@"state"] = @(SFDLDismissed); r[@"bytes"] = @0; [r removeObjectForKey:@"path"];
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
    pid_t pid = t.processIdentifier;
    [t terminate];
    for (int i = 0; i < 20 && t.isRunning; i++) usleep(50 * 1000);
    if (t.isRunning) kill(pid, SIGKILL);
}


- (void)start {
    if (_started) return;
    _started = YES;
    [self reapOrphans];        // before anything writes: no second writer may survive from an earlier run
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
                                                  usingBlock:^(NSNotification *n) { NSMutableDictionary *s = self->_subs[n.object]; if (s) [self checkSub:s]; }];
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
    NSMutableDictionary *r = [@{@"id": item.identifier, @"source": item.source ?: @"", @"channel": item.channel ?: @"",
                                @"state": @(SFDLDone), @"progress": @1.0,
                                @"added": @([[NSDate date] timeIntervalSince1970])} mutableCopy];
    r[@"item"] = [self itemJSON:item];
    if (item.date) r[@"published"] = @([item.date timeIntervalSince1970]);
    if (subID) r[@"sub"] = subID;
    NSString *target = [self targetPathFor:r item:item];
    if (![path.pathExtension.lowercaseString isEqualToString:@"mp4"]) target = [[target stringByDeletingPathExtension] stringByAppendingPathExtension:path.pathExtension];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[target stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm moveItemAtPath:path toPath:target error:err]) return NO;      // same volume: just rename
    r[@"path"] = target;
    r[@"bytes"] = @([[fm attributesOfItemAtPath:target error:nil] fileSize]);
    if (thumb && [fm fileExistsAtPath:thumb]) {
        NSString *tt = [[target stringByDeletingPathExtension] stringByAppendingString:@".jpg"];
        if ([fm moveItemAtPath:thumb toPath:tt error:nil]) r[@"thumb"] = tt;
    }
    _recs[item.identifier] = r;
    [self save:r];
    return YES;
}
@end
