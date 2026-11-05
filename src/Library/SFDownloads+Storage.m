// SFDownloads – storage layer. Downloads are never deleted automatically (user 2026-11-05: videos
// vanish from YouTube and the Mediatheken; then the local copy is the only one). Instead:
//  - storage guard: below a reserve no download starts and a running one stops (back into the
//    queue, no attempt used up); the queue continues by itself once there is room again. The UI
//    asks the user to make room (SFDownloadsStorageDidChangeNotification, "Platz schaffen").
//  - "Behalten": a mark that keeps a video out of every bulk deletion.
//  - online availability per download (cached 30 days), so "Platz schaffen" can tell what is
//    replaceable (still online) from what is not. YouTube asks oEmbed (no player request).
#import "SFDownloads+Private.h"

static NSMutableDictionary *gAvailability;   // prefix -> SFAvailabilityCheck
void SFRegisterAvailabilityCheck(NSString *prefix, SFAvailabilityCheck f) {
    if (!gAvailability) gAvailability = [NSMutableDictionary new];
    gAvailability[prefix] = [f copy];
}

static const unsigned long long kGB = 1000ULL * 1000ULL * 1000ULL;
static const NSTimeInterval kOnlineValid = 30 * 86400;   // a checked state is trusted this long
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

- (BOOL)checkStorage {
    BOOL anyQueued = NO;
    for (NSDictionary *r in _recs.allValues) if ([r[@"state"] integerValue] == SFDLQueued) { anyQueued = YES; break; }
    // full = below the reserve; only reported while something waits (an idle queue needs no room)
    [self setStorageFull:anyQueued && self.freeBytes < self.storageReserve];
    return _storageFull;
}

- (void)stopIfDiskRunsOut {
    if (!_task.isRunning || self.freeBytes >= self.storageReserve / 2) return;
    SFLog(@"downloads: disk nearly full while loading %@ - stopping it (continues later)", _runningID);
    [self setStorageFull:YES];
    [_task terminate];   // termination -> finish:ok:NO -> deferred (storageFull), the part file is removed
}

#pragma mark Behalten

- (BOOL)isKept:(NSString *)identifier { return [_recs[identifier][@"keep"] boolValue]; }

- (void)setKept:(BOOL)kept forIdentifier:(NSString *)identifier {
    NSMutableDictionary *r = _recs[identifier];
    if (!r || [r[@"keep"] boolValue] == kept) return;
    r[@"keep"] = @(kept);
    [self save:r];
    [self changed:identifier];
    SFLog(@"downloads: %@ %@", identifier, kept ? @"kept (Behalten)" : @"no longer kept");
}

#pragma mark Online availability

- (NSInteger)onlineStateFor:(NSString *)identifier {
    NSDictionary *r = _recs[identifier];
    if (!r[@"online"] || r[@"online"] == [NSNull null]) return -1;
    if ([NSDate date].timeIntervalSince1970 - [r[@"onlineAt"] doubleValue] > kOnlineValid) return -1;
    return [r[@"online"] integerValue] ? 1 : 0;
}

- (void)checkOnline:(NSArray *)identifiers done:(dispatch_block_t)done {
    if (!_onlineQueue) { _onlineQueue = [NSMutableArray new]; _onlineDone = [NSMutableArray new]; }
    for (NSString *i in identifiers)
        if ([self onlineStateFor:i] < 0 && [_recs[i][@"state"] integerValue] == SFDLDone && ![_onlineQueue containsObject:i]) [_onlineQueue addObject:i];
    if (done) [_onlineDone addObject:[done copy]];
    if (!_checkingOnline) [self nextOnlineCheck];
}

- (void)finishOnlineChecks {
    _checkingOnline = NO;
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
    SFItem *item = [self itemFromRec:_recs[ident]];
    NSString *ref = item.resolverRef ?: item.identifier;
    NSString *prefix = prefixOf(ref);
    __block BOOL answered = NO;
    SFAvailabilityDone got = ^(NSInteger online) {
        SFMain(^{
            if (answered) return;
            answered = YES;
            NSMutableDictionary *r = self->_recs[ident];
            if (r && online >= 0) {
                r[@"online"] = @(online); r[@"onlineAt"] = @([NSDate date].timeIntervalSince1970);
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
    SFAvailabilityCheck checker = prefix ? gAvailability[prefix] : nil;
    if (!item) { got(-1); return; }
    if (checker) { checker(item, got); return; }
    // default: the source's online resolver (a stream that resolves = still online). Mediathek
    // resolvers answer "not available" for expired items.
    SFResolveRefOnline(ref, ^(NSURL *url, NSError *e) {
        if (url) { got(1); return; }
        got([SFNet isOnline] ? 0 : -1);
    });
}

@end
