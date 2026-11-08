// SFDownloads - the worker: picks the next download (per-source gaps, pauses, storage) and fills the
// media store with it (docs/media-store.md) - by its app (fillItem:, YouTube) or by the media proxy
// (the file or HLS playlist the app resolves to) - fetches the thumbnail and records the outcome.
#import "SFDownloads+Private.h"
#import "SFHostFetch.h"
#import "SFDownloadBudget.h"
#import "SFMediaStore.h"
#import "SFMediaProxy.h"
#import "SFEngine.h"

@implementation SFDownloads (Worker)

// its thumbnail, in its show's folder (next to the show's artwork)
- (NSString *)thumbPathFor:(SFDownloadRecord *)r item:(SFItem *)item {
    NSString *dir = [self folderForSource:r.source channel:item.channel];
    NSString *rest = restOf(item.identifier);
    // short IDs (YouTube) readable; long ones (ARD crid base64, ZDF canonical) share long prefixes -> hash
    NSString *idPart = rest.length <= 16 ? safeName(rest, 16) : idHash(item.identifier);
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ [%@].jpg", safeName(item.title ?: @"Video", 120), idPart]];
}

- (void)pump {
    if (!_started || _runningID) return;
    if (![SFNet isOnline]) return;   // offline: wait instead of using up attempts (continues on SFNetOnlineDidChange)
    // manual downloads before subscription downloads, oldest request first in each
    SFDownloadRecord *next = nil;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970, wake = 0;
    for (SFDownloadRecord *r in _recs.allValues) {
        if (r.state != SFDLQueued) continue;
        NSTimeInterval until = [self notBefore:r];
        if (until > now) { wake = wake ? MIN(wake, until) : until; continue; }   // source paused: later
        if (!next) { next = r; continue; }
        BOOL rm = r.sub == nil, nm = next.sub == nil;
        if (rm != nm) { if (rm) next = r; continue; }
        if (r.added < next.added) next = r;
    }
    if (!next) { if (wake) [self pumpAt:wake]; else [self setStorageFull:NO]; return; }
    if ([self checkStorageFor:next]) return;   // not enough room for it: wait (re-checked every minute, user asked)
    SFDownloadRecord *r = next;
    SFItem *item = [self itemFromRec:r];
    if (!item) {
        r.state = SFDLFailed; r.error = @"Eintrag unlesbar"; r.tries = kSubMaxTries;
        [self save:r];
        dispatch_async(dispatch_get_main_queue(), ^{ [self pump]; });
        return;
    }
    Class<SFApp> app = [SFAppRegistry appForItem:item];
    BOOL fills = [app respondsToSelector:@selector(fillItem:progress:done:)];
    _runningID = r.identifier;
    [self noteStartOf:[self sourceOf:r] at:now subscription:r.sub != nil];
    _resumeID = nil;
    r.state = SFDLRunning; r.progress = 0;
    [self save:r];
    [self changed:_runningID];
    if (fills) {
        [self runFill:^dispatch_block_t(void (^progress)(double), void (^done)(NSDictionary *, NSError *)) {
            return [app fillItem:item progress:progress done:done];
        } rec:r item:item];
        return;
    }
    // the media proxy fills what the app resolves to: a file or an HLS playlist (and its subtitles)
    NSString *ident = _runningID;
    [item resolveURL:^(NSURL *url, NSError *e) {
        if (![ident isEqualToString:self->_runningID]) return;
        if (!url) { [self finish:ident ok:NO error:e.localizedDescription ?: @"Kein Stream"]; return; }
        if (![SFMediaProxy canServe:url]) { [self finish:ident ok:NO error:@"Diese Quelle lässt sich nicht herunterladen"]; return; }
        NSArray *subs = SFMPVSourceFor(url)[@"subs"];
        [self runFill:^dispatch_block_t(void (^progress)(double), void (^done)(NSDictionary *, NSError *)) {
            return [[SFMediaProxy shared] fill:url item:ident subs:subs duration:item.duration progress:progress
                                          done:^(NSError *fe) { done(fe ? nil : @{}, fe); }];
        } rec:r item:item];
    }];
}

// exact time from the source replaces a list's approximation ("vor 2 Wochen")
- (void)notePublished:(NSDictionary *)info rec:(SFDownloadRecord *)r item:(SFItem *)item {
    NSDate *published = [info[@"published"] isKindOfClass:[NSDate class]] ? info[@"published"] : nil;
    if (!published) return;
    item.date = published;
    r.published = [published timeIntervalSince1970];
    [self setItem:item ofRec:r];
    [self save:r];
}

// A download: the app (fillItem:) or the media proxy fills the item's tracks; its size is the store's.
// Pinned while pending and once done (storePinned), so eviction never takes it.
- (void)runFill:(dispatch_block_t (^)(void (^progress)(double), void (^done)(NSDictionary *info, NSError *e)))start
            rec:(SFDownloadRecord *)r item:(SFItem *)item {
    NSString *ident = r.identifier;
    __block NSDate *lastUI = [NSDate distantPast];
    _fillCancel = start(^(double p) {
        SFMain(^{
            if (![ident isEqualToString:self->_runningID]) return;
            r.progress = p;
            if (-[lastUI timeIntervalSinceNow] > 2) { lastUI = [NSDate date]; [self changed:ident]; }
        });
    }, ^(NSDictionary *info, NSError *e) {
        SFMain(^{
            if (![ident isEqualToString:self->_runningID]) return;
            self->_fillCancel = nil;
            if (!info) { [self finish:ident ok:NO error:e.localizedDescription ?: @"Fehler"]; return; }
            [self notePublished:info rec:r item:item];
            // a subscription episode is pre-buffered: it goes after a while (SFDownloads+Subscriptions
            // expirePrebuffers); a manual download stays
            r.expires = r.sub ? [NSDate date].timeIntervalSince1970 + kPrebufferDays * 86400.0 : 0;
            [self fetchThumb:item rec:r];
            [self finish:ident ok:YES error:nil];
        });
    });
    [self watchDiskDuringRun:YES];
    SFLog(@"downloads: loading %@", item.title);
}

// Ends the running fill without a verdict of its own (exit, removal, disk): cancelled - what it stored
// stays. NO when nothing ran.
- (BOOL)abortRun {
    dispatch_block_t cancel = _fillCancel;
    _fillCancel = nil; _runningID = nil;
    if (cancel) cancel();
    return cancel != nil;
}

- (void)fetchThumb:(SFItem *)item rec:(SFDownloadRecord *)r {
    NSString *img = item.image;
    if (![img hasPrefix:@"http"]) return;
    NSString *thumb = [self thumbPathFor:r item:item];
    [[NSFileManager defaultManager] createDirectoryAtPath:[thumb stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *ident = r.identifier;
    void (^got)(NSData *, NSInteger) = ^(NSData *d, NSInteger st) {
        if (d.length && st < 400 && [d writeToFile:thumb atomically:YES]) SFMain(^{
            SFDownloadRecord *rr = self->_recs[ident];
            if (!rr) return;
            rr.thumb = thumb; [self save:rr]; [self changed:ident];
        });
    };
    SFHostFetcher own = SFHostFetcherFor([NSURL URLWithString:img]);
    if (own) { own([NSURL URLWithString:img], got); return; }   // the source's own client (SFHostFetch.h)
    SFBackground(^{
        NSInteger st = 0;
        NSData *d = SFCurlFetch(img, @"GET", nil, nil, &st, NULL);
        got(d, st);
    });
}

// Starts per source at least the app's downloadSpacing apart: quick failures or short videos must
// not turn into a burst of requests to one site (YouTube flags the IP for bursts of player
// requests). Above a minute up to half of it more at random - no machine cadence. Tests set
// SOFA_SOURCE_GAP (seconds, every source, no randomness).
static NSTimeInterval SFStartSpacing(NSString *src) {
    NSTimeInterval dev = SFDevSeconds(@"SOFA_SOURCE_GAP", 0);
    if (dev > 0) return dev;
    NSTimeInterval gap = SFDownloadSpacing([src stringByAppendingString:@":"]);
    return gap > 60 ? gap + arc4random_uniform((uint32_t)(gap / 2)) : gap;
}

static NSString *nextStartKey(NSString *src) { return [@"downloads.nextStart." stringByAppendingString:src]; }
static NSString *subStartsKey(NSString *src) { return [@"downloads.subscriptionStarts." stringByAppendingString:src]; }

- (NSTimeInterval)nextStartOf:(NSString *)src {
    if (!_nextStart) _nextStart = [NSMutableDictionary new];
    NSNumber *n = _nextStart[src];
    if (!n) _nextStart[src] = n = @([[[SFStore shared] setting:nextStartKey(src)] doubleValue]);
    return n.doubleValue;
}

- (void)noteStartOf:(NSString *)src at:(NSTimeInterval)now subscription:(BOOL)sub {
    NSTimeInterval next = now + SFStartSpacing(src);
    if (!_nextStart) _nextStart = [NSMutableDictionary new];
    _nextStart[src] = @(next);
    [[SFStore shared] setSetting:[NSString stringWithFormat:@"%.0f", next] forKey:nextStartKey(src)];
    if (!sub || !SFSubscriptionDownloadsPerDay([src stringByAppendingString:@":"])) return;
    NSMutableArray *starts = [[self subscriptionStartsOf:src now:now] mutableCopy];
    [starts addObject:@(now)];
    _subStarts[src] = starts;
    [[SFStore shared] setSetting:[starts componentsJoinedByString:@","] forKey:subStartsKey(src)];
}

// The source's subscription download starts within the last 24 h (oldest first).
- (NSArray *)subscriptionStartsOf:(NSString *)src now:(NSTimeInterval)now {
    if (!_subStarts) _subStarts = [NSMutableDictionary new];
    NSArray *all = _subStarts[src];
    if (!all) {
        NSMutableArray *read = [NSMutableArray new];
        for (NSString *t in [[[SFStore shared] setting:subStartsKey(src)] componentsSeparatedByString:@","]) if (t.doubleValue > 0) [read addObject:@(t.doubleValue)];
        all = read;
    }
    return _subStarts[src] = SFDownloadBudgetRecent(all, now);
}

// When the source's daily subscription budget allows the next start (0 = now).
- (NSTimeInterval)subscriptionBudgetFreeAt:(NSString *)src {
    NSUInteger max = SFSubscriptionDownloadsPerDay([src stringByAppendingString:@":"]);
    return SFDownloadBudgetFreeAt([self subscriptionStartsOf:src now:[NSDate date].timeIntervalSince1970], max);
}

- (NSString *)sourceOf:(SFDownloadRecord *)r {
    SFItem *item = [self itemFromRec:r];
    return prefixOf(item.resolverRef ?: item.identifier ?: r.identifier);
}

// Epoch until which the record's source has paused itself (0 = go).
- (NSTimeInterval)pausedUntil:(SFDownloadRecord *)r {
    return SFBackgroundPausedUntil([[self sourceOf:r] stringByAppendingString:@":"]);
}

// pausedUntil plus the per-source spacing of starts and, for subscription downloads, the daily
// budget (not for the run an exit interrupted - the same
// download going on, e.g. after an update, 2026-11-06: it waited 16 min)
- (NSTimeInterval)notBefore:(SFDownloadRecord *)r {
    if ([r.identifier isEqualToString:_resumeID]) return [self pausedUntil:r];
    NSString *src = [self sourceOf:r];
    NSTimeInterval t = MAX([self pausedUntil:r], [self nextStartOf:src]);
    return r.sub ? MAX(t, [self subscriptionBudgetFreeAt:src]) : t;   // the daily budget: subscriptions only
}

- (void)pumpAt:(NSTimeInterval)when {
    if (_pauseWake && _pauseWake <= when && _pauseWake > [NSDate date].timeIntervalSince1970) return;   // earlier wake pending
    _pauseWake = when;
    NSTimeInterval in = MAX(1, when - [NSDate date].timeIntervalSince1970 + 1);
    if (in > 60) SFLog(@"downloads: source paused - next attempt in %.0f min", round(in / 60));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(in * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_pauseWake == when) self->_pauseWake = 0;
        [self pump];
    });
}

- (void)finish:(NSString *)ident ok:(BOOL)ok error:(NSString *)error {
    SFDownloadRecord *r = _recs[ident];
    _fillCancel = nil; _runningID = nil;
    [self watchDiskDuringRun:NO];
    // a run that failed on a (nearly) full disk - ENOSPC, or stopped by the disk watch - is not the
    // download's fault: the live free space decides, not the cached flag (review 2026-11-05)
    BOOL diskFull = !ok && self.freeBytes < self.storageReserve;
    if (diskFull) [self setStorageFull:YES];
    if (ok) [_diskNeed removeObjectForKey:ident];
    if (r && !ok && ([self pausedUntil:r] > [NSDate date].timeIntervalSince1970 || self.storageFull || diskFull)) {
        // the source paused itself (YouTube bot check) or the disk is full - not the download's fault:
        // back into the queue without using up an attempt; pump continues when the pause is over
        r.state = SFDLQueued; r.progress = 0;
        [self save:r]; [self changed:ident];
        SFLog(@"downloads: %@ deferred (%@)", ident, error);
        dispatch_async(dispatch_get_main_queue(), ^{ [self pump]; });
        return;
    }
    if (r) {
        r.progress = ok ? 1 : 0;
        if (ok) { r.state = SFDLDone; r.error = nil; r.retryAt = 0; r.tries = 0; }
        else {
            // the next attempt's time is kept for every failure under the limit (a subscription may find
            // a manual one later); only a subscription episode is retried by Sofa itself
            NSInteger n = r.tries + 1;
            r.error = error ?: @"Fehler"; r.tries = n;
            r.retryAt = n < kSubMaxTries ? [NSDate date].timeIntervalSince1970 + SFRetryDelay(n) : 0;
            r.state = r.sub && n < kSubMaxTries ? SFDLRetrying : SFDLFailed;
        }
        [self save:r];
        SFLog(@"downloads: %@ %@%@", ok ? @"done" : @"FAILED", ident, ok ? @"" : [@" – " stringByAppendingString:error ?: @""]);
    }
    [self changed:ident];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pump]; });
}
@end
