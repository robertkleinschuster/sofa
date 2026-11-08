// SFDownloads – storage layer. Downloads are never deleted automatically (user 2026-11-05: videos
// vanish from YouTube and the Mediatheken; then the local copy is the only one). Instead:
//  - storage guard: below a reserve no download starts and a running one stops (back into the
//    queue, no attempt used up); the queue continues by itself once there is room again. The UI
//    asks the user to make room (SFDownloadsStorageDidChangeNotification, "Platz schaffen").
//  - "Behalten": a mark that keeps a video out of every bulk deletion.
//  - online availability per download (cached 30 days), so "Platz schaffen" can tell what is
//    replaceable (still online) from what is not. YouTube asks oEmbed (no player request).
#import "SFDownloads+Private.h"


static const unsigned long long kGB = 1000ULL * 1000ULL * 1000ULL;
// How long a checked state is trusted: "online" for showing it (30 days), but bulk deletion
// re-verifies anything older than a day right before deleting (Mediathek episodes expire after
// 7-30 days - a month-old "online" must not delete the last copy, review 2026-11-05). "Gone" is
// re-checked after 3 days (a transient source error must not mark a video irreplaceable for long).
static const NSTimeInterval kOnlineValid = 30 * 86400;
static const NSTimeInterval kGoneValid = 3 * 86400;
static const NSTimeInterval kOnlineGap = 1.5;            // spacing between two checks (spare the sources)

@implementation SFDownloads (Storage)

#pragma mark Storage guard

// 10 GB: room for the system (swap, caches) and a few more videos. Dev tests change it (dev command
// dlreserve) to provoke a full disk without filling one.
static unsigned long long gReserve = 10 * kGB;
- (unsigned long long)storageReserve { return gReserve; }
- (void)setStorageReserveForTesting:(unsigned long long)bytes {
    if (!SFDevMode) return;
    gReserve = bytes;
    SFLog(@"dev: disk reserve %llu MB", bytes / 1000000ULL);
    [self pump];   // re-checks at once
    [self stopIfDiskRunsOut];
}

- (BOOL)storageFull { return _storageFull; }

- (void)setStorageFull:(BOOL)full {
    if (full == _storageFull) return;
    _storageFull = full;
    _generation++;
    if (full) {
        SFLog(@"downloads: storage full (%llu MB free, reserve %llu MB) - downloads paused", self.freeBytes / 1000000ULL, self.storageReserve / 1000000ULL);
        if (!_storageTimer)   // re-check every minute: room comes back by deleting, also outside Sofa
            _storageTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(storageTick:) userInfo:nil repeats:YES];
    } else {
        SFLog(@"downloads: storage free again (%llu MB) - downloads continue", self.freeBytes / 1000000ULL);
        [_storageTimer invalidate]; _storageTimer = nil;
    }
    [self changed:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:SFDownloadsStorageDidChangeNotification object:self];
}

- (void)storageTick:(NSTimer *)t { [self pump]; }   // pump re-checks and continues when there is room

// Room a download needs before it may start: the reserve plus twice its expected size (ffmpeg's
// +faststart rewrites the finished file, ~2x at the very end). Expected size from the duration at
// ~1 MB/s (1080p60 VP9 + Opus measured 0.4-0.9 MB/s), 2 GB when unknown. After a disk stop at least
// 2.5x what that run had written - hysteresis: removing its part file frees the room again, and
// without it the same download started over and over (review 2026-11-05).
- (unsigned long long)roomNeededFor:(SFDownloadRecord *)r {
    SFItem *item = [self itemFromRec:r];
    unsigned long long est = item.duration > 0 ? (unsigned long long)(item.duration * 1e6) : 2 * kGB;
    unsigned long long need = self.storageReserve + 2 * est;
    unsigned long long stopped = [_diskNeed[r.identifier] unsignedLongLongValue];
    return MAX(need, self.storageReserve + stopped);
}

- (BOOL)checkStorageFor:(SFDownloadRecord *)next {
    if (!next) return NO;
    [self setStorageFull:self.freeBytes < [self roomNeededFor:next]];
    return _storageFull;
}

// While a download runs (timer, every 10 s - also for unknown durations and the faststart phase, which
// report no progress): stop it when the reserve is half used up.
- (void)stopIfDiskRunsOut {
    if (!(_task.isRunning || _fillCancel) || self.freeBytes >= self.storageReserve / 2) return;
    unsigned long long written = _runningPart ? [[[NSFileManager defaultManager] attributesOfItemAtPath:_runningPart error:nil] fileSize] : 0;
    SFLog(@"downloads: disk nearly full while loading %@ (%llu MB written) - stopping it (continues when there is room)", _runningID, written / 1000000ULL);
    if (_runningID) {
        if (!_diskNeed) _diskNeed = [NSMutableDictionary new];
        _diskNeed[_runningID] = @((unsigned long long)(written * 2.5) + kGB);
    }
    [self setStorageFull:YES];
    if (_fillCancel) { NSString *ident = _runningID; [self abortRun]; [self finish:ident ok:NO error:@"Speicher voll"]; return; }   // -> deferred (disk)
    [_task terminate];   // termination -> finish:ok:NO -> deferred (disk), the part file is removed
}

- (void)watchDiskDuringRun:(BOOL)on {
    [_diskWatch invalidate]; _diskWatch = nil;
    if (on) _diskWatch = [NSTimer scheduledTimerWithTimeInterval:10 target:self selector:@selector(diskWatchTick:) userInfo:nil repeats:YES];
}
- (void)diskWatchTick:(NSTimer *)t { [self stopIfDiskRunsOut]; }

#pragma mark Behalten

- (BOOL)isKept:(NSString *)identifier { return [self recOf:identifier].keep; }

- (void)setKept:(BOOL)kept forIdentifier:(NSString *)identifier {
    SFDownloadRecord *r = _recs[identifier];
    if (!r || r.keep == kept) return;
    r.keep = kept;
    [self save:r];
    [self changed:identifier];
    SFLog(@"downloads: %@ %@", identifier, kept ? @"kept (Behalten)" : @"no longer kept");
}

#pragma mark Online availability

- (NSInteger)onlineStateFor:(NSString *)identifier { return [self onlineStateFor:identifier maxAge:kOnlineValid]; }

- (NSInteger)onlineStateFor:(NSString *)identifier maxAge:(NSTimeInterval)maxAge {
    SFDownloadRecord *r = _recs[identifier];
    if (!r || r.online < 0) return -1;
    BOOL online = r.online != 0;
    NSTimeInterval age = [NSDate date].timeIntervalSince1970 - r.onlineAt;
    if (age > (online ? maxAge : MIN(maxAge, kGoneValid))) return -1;
    return online ? 1 : 0;
}

- (void)checkOnline:(NSArray *)identifiers done:(dispatch_block_t)done { [self checkOnline:identifiers maxAge:kOnlineValid done:done]; }

- (void)checkOnline:(NSArray *)identifiers maxAge:(NSTimeInterval)maxAge done:(dispatch_block_t)done {
    if (!_onlineQueue) { _onlineQueue = [NSMutableArray new]; _onlineDone = [NSMutableArray new]; }
    for (NSString *i in identifiers)
        if ([self onlineStateFor:i maxAge:maxAge] < 0 && [self recOf:i].state == SFDLDone
            && ![_onlineQueue containsObject:i] && ![i isEqualToString:_onlineCurrent]) [_onlineQueue addObject:i];
    if (done) [_onlineDone addObject:[done copy]];
    if (!_checkingOnline) [self nextOnlineCheck];
}

- (void)finishOnlineChecks {
    _checkingOnline = NO; _onlineCurrent = nil;
    NSArray *d = [_onlineDone copy];
    [_onlineDone removeAllObjects];
    [[NSNotificationCenter defaultCenter] postNotificationName:SFDownloadsStorageDidChangeNotification object:self];
    for (dispatch_block_t b in d) b();
}

- (void)nextOnlineCheck {
    if (!_onlineQueue.count || ![SFNet isOnline]) { [_onlineQueue removeAllObjects]; [self finishOnlineChecks]; return; }
    _checkingOnline = YES;
    NSString *ident = _onlineQueue[0];
    [_onlineQueue removeObjectAtIndex:0];
    _onlineCurrent = ident;
    SFItem *item = [self itemFromRec:_recs[ident]];
    NSString *ref = item.resolverRef ?: item.identifier;
    __block BOOL answered = NO;
    SFAvailabilityDone got = ^(NSInteger online) {
        SFMain(^{
            if (answered) return;
            answered = YES;
            SFDownloadRecord *r = self->_recs[ident];
            if (r && online >= 0) {
                r.online = online ? 1 : 0; r.onlineAt = [NSDate date].timeIntervalSince1970;
                [self save:r];
                if (!online) SFLog(@"downloads: %@ is no longer online at its source", ident);
            }
            SFCount(online > 0 ? @"downloads.online-check.online" : online == 0 ? @"downloads.online-check.gone" : @"downloads.online-check.unknown");
            // progress for the page roughly every 10 checks, and the end
            if (self->_onlineQueue.count % 10 == 0)
                [[NSNotificationCenter defaultCenter] postNotificationName:SFDownloadsStorageDidChangeNotification object:self];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOnlineGap * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self nextOnlineCheck]; });
        });
    };
    // a check that never answers must not stop the run
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ got(-1); });
    if (!item) { got(-1); return; }
    Class<SFApp> app = [SFAppRegistry appForItem:item];
    if ([app respondsToSelector:@selector(availabilityOfItem:done:)]) { [app availabilityOfItem:item done:got]; return; }
    // default: the source's online resolver (a stream that resolves = still online). Mediathek
    // resolvers answer "not available" for expired items.
    SFResolveRefOnline(ref, ^(NSURL *url, NSError *e) {
        if (url) { got(1); return; }
        got([SFNet isOnline] ? 0 : -1);
    });
}

@end
