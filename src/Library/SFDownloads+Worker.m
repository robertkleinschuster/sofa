// SFDownloads - the worker: picks the next download (per-source gaps, pauses, storage), runs ffmpeg
// into a part file, installs and verifies the result, fetches the thumbnail, records the outcome.
#import "SFDownloads+Private.h"
#import <signal.h>

@implementation SFDownloads (Worker)

- (NSString *)targetPathFor:(SFDownloadRecord *)r item:(SFItem *)item {
    NSString *dir = [self folderForSource:r.source channel:item.channel];
    NSString *rest = restOf(item.identifier);
    // short IDs (YouTube) readable; long ones (ARD crid base64, ZDF canonical) share long prefixes -> hash
    NSString *idPart = rest.length <= 16 ? safeName(rest, 16) : idHash(item.identifier);
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ [%@].mp4", safeName(item.title ?: @"Video", 120), idPart]];
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
    NSString *ff = [SFDownloads ffmpegToolPath];
    if (!ff) { SFLog(@"downloads: ffmpeg missing"); return; }
    SFDownloadRecord *r = next;
    SFItem *item = [self itemFromRec:r];
    if (!item) {
        r.state = SFDLFailed; r.error = @"Eintrag unlesbar"; r.tries = kSubMaxTries;
        [self save:r];
        dispatch_async(dispatch_get_main_queue(), ^{ [self pump]; });
        return;
    }
    _runningID = r.identifier;
    [self noteStartOf:[self sourceOf:r] at:now];
    _resumeID = nil;
    r.state = SFDLRunning; r.progress = 0;
    [self save:r];
    [self changed:_runningID];
    NSString *ident = _runningID;
    Class<SFApp> app = [SFAppRegistry appForItem:item];
    BOOL custom = [app respondsToSelector:@selector(downloadSourceForItem:done:)];
    SFDownloadURLDone got = ^(NSURL *url, NSURL *audio, NSDictionary *info, NSError *e) {
        SFMain(^{
            if (![ident isEqualToString:self->_runningID]) return;
            if (!url) { [self finish:ident ok:NO error:e.localizedDescription ?: @"Kein Stream"]; return; }
            NSDate *published = [info[@"published"] isKindOfClass:[NSDate class]] ? info[@"published"] : nil;
            if (published) {   // exact time from the source replaces a list's approximation ("vor 2 Wochen")
                item.date = published;
                r.published = [published timeIntervalSince1970];
                [self setItem:item ofRec:r];
                [self save:r];
            }
            [self runFFmpeg:ff url:url audio:audio rec:r item:item];
        });
    };
    if (custom) [app downloadSourceForItem:item done:got]; else [item resolveURL:^(NSURL *url, NSError *e) { got(url, nil, nil, e); }];
}

- (void)runFFmpeg:(NSString *)ff url:(NSURL *)url audio:(NSURL *)audio rec:(SFDownloadRecord *)r item:(SFItem *)item {
    NSString *target = [self targetPathFor:r item:item];
    NSString *part = [[target stringByDeletingPathExtension] stringByAppendingString:[self partSuffix]];
    [[NSFileManager defaultManager] createDirectoryAtPath:[target stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *src = [[SFStreamProxy shared] playableURLFor:url];   // ORF & co. via the TLS bridge
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/bin/nice";
    NSMutableArray *args = [@[@"-n", @"10", ff, @"-nostdin", @"-hide_banner", @"-loglevel", @"error", @"-y", @"-progress", @"pipe:1",
                              // spare bandwidth: at most 3x playback speed (background downloads must not slow down
                              // streaming on the TV or other connections); short unthrottled start.
                              // -rw_timeout: a dead connection must end the run (30 s), never hang the queue forever
                              @"-readrate", @"3", @"-readrate_initial_burst", @"10", @"-rw_timeout", @"30000000",
                              ] mutableCopy];
    // local SABR streams (sofa-yt): a response cut after a wait must reconnect, not end the file early
    NSArray *local = @[@"-reconnect", @"1", @"-reconnect_on_network_error", @"1", @"-reconnect_delay_max", @"5"];
    if ([src.host isEqualToString:@"127.0.0.1"]) [args addObjectsFromArray:local];
    [args addObjectsFromArray:@[@"-i", src.absoluteString]];
    if (audio) {   // separate audio track (original audio): video from the stream, audio from the second source
        NSURL *asrc = [[SFStreamProxy shared] playableURLFor:audio];
        [args addObjectsFromArray:@[@"-readrate", @"3", @"-readrate_initial_burst", @"10", @"-rw_timeout", @"30000000"]];
        if ([asrc.host isEqualToString:@"127.0.0.1"]) [args addObjectsFromArray:local];
        [args addObjectsFromArray:@[@"-i", asrc.absoluteString,
                                    @"-map", @"0:v:0", @"-map", @"1:a:0", @"-shortest"]];
        SFLog(@"downloads: %@ with separate audio track (original audio)", item.title);
    }
    [args addObjectsFromArray:@[@"-c", @"copy", @"-movflags", @"+faststart"]];
    if (!audio && ![src.path.pathExtension.lowercaseString isEqualToString:@"mp4"]) [args addObjectsFromArray:@[@"-bsf:a", @"aac_adtstoasc"]];
    [args addObject:part];
    t.arguments = args;
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    t.environment = env;
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
    t.standardOutput = out; t.standardError = err; t.standardInput = [NSFileHandle fileHandleWithNullDevice];
    NSString *ident = r.identifier;
    double dur = item.duration;
    __block NSDate *lastUI = [NSDate distantPast];
    out.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSString *s = [[NSString alloc] initWithData:h.availableData encoding:NSUTF8StringEncoding];
        NSRange k = [s rangeOfString:@"out_time_ms=" options:NSBackwardsSearch];
        if (k.location == NSNotFound || dur <= 0) return;
        double us = [[s substringFromIndex:NSMaxRange(k)] doubleValue];
        double p = MIN(0.99, us / 1e6 / dur);
        SFMain(^{
            if (![ident isEqualToString:self->_runningID]) return;
            r.progress = p;
            if (-[lastUI timeIntervalSinceNow] > 2) { lastUI = [NSDate date]; [self changed:ident]; }
        });
    };
    NSMutableData *errData = [NSMutableData new];
    err.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) { NSData *d = h.availableData; @synchronized (errData) { [errData appendData:d]; } };
    t.terminationHandler = ^(NSTask *tt) {
        int code = tt.terminationStatus;
        SFMain(^{
            out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil;
            if (![ident isEqualToString:self->_runningID]) { [[NSFileManager defaultManager] removeItemAtPath:part error:nil]; return; }
            NSFileManager *fm = [NSFileManager defaultManager];
            if (code == 0 && [fm fileExistsAtPath:part]) {
                // verify before the file replaces anything (off the main thread, a few seconds)
                SFBackground(^{
                    NSString *problem = [SFDownloads problemWithFile:part expectedDuration:dur ffmpeg:ff];
                    SFMain(^{
                        if (![ident isEqualToString:self->_runningID]) { [fm removeItemAtPath:part error:nil]; return; }
                        if (problem) {
                            SFLog(@"downloads: %@ failed verification (%@)", ident, problem);
                            [fm removeItemAtPath:part error:nil];
                            [self finish:ident ok:NO error:@"Datei war beschädigt – wird erneut geladen"];
                            return;
                        }
                        [self installPart:part target:target rec:r item:item];
                    });
                });
            } else {
                [fm removeItemAtPath:part error:nil];
                NSString *msg; @synchronized (errData) { msg = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding]; }
                if ([self recOf:ident].state != SFDLRunning) return;   // cancelled
                [self finish:ident ok:NO error:[msg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"ffmpeg-Fehler"];
            }
        });
    };
    @try { [t launch]; }
    @catch (NSException *ex) { [self finish:ident ok:NO error:ex.reason]; return; }
    _task = t;
    _runningPart = part;
    [self watchDiskDuringRun:YES];   // never fill the disk: stop, back into the queue
    SFLog(@"downloads: loading %@", item.title);
}

- (void)installPart:(NSString *)part target:(NSString *)target rec:(SFDownloadRecord *)r item:(SFItem *)item {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *old = r.path;   // repair of an earlier file whose name changed: drop the old one
    if (old.length && ![old isEqualToString:target]) [fm removeItemAtPath:old error:nil];
    [fm removeItemAtPath:target error:nil];
    [fm moveItemAtPath:part toPath:target error:nil];
    r.path = target;
    r.bytes = [[fm attributesOfItemAtPath:target error:nil] fileSize];
    [self fetchThumb:item rec:r];
    [self finish:r.identifier ok:YES error:nil];
}

- (void)fetchThumb:(SFItem *)item rec:(SFDownloadRecord *)r {
    NSString *img = item.image;
    if (![img hasPrefix:@"http"] || !r.path) return;
    NSString *thumb = [[r.path stringByDeletingPathExtension] stringByAppendingString:@".jpg"];
    NSString *ident = r.identifier;
    SFBackground(^{
        NSInteger st = 0;
        NSData *d = SFCurlFetch(img, @"GET", nil, nil, &st, NULL);
        if (d.length && st < 400 && [d writeToFile:thumb atomically:YES]) SFMain(^{
            SFDownloadRecord *rr = self->_recs[ident];
            if (!rr) return;
            rr.thumb = thumb; [self save:rr]; [self changed:ident];
        });
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

- (NSTimeInterval)nextStartOf:(NSString *)src {
    if (!_nextStart) _nextStart = [NSMutableDictionary new];
    NSNumber *n = _nextStart[src];
    if (!n) _nextStart[src] = n = @([[[SFStore shared] setting:nextStartKey(src)] doubleValue]);
    return n.doubleValue;
}

- (void)noteStartOf:(NSString *)src at:(NSTimeInterval)now {
    NSTimeInterval next = now + SFStartSpacing(src);
    if (!_nextStart) _nextStart = [NSMutableDictionary new];
    _nextStart[src] = @(next);
    [[SFStore shared] setSetting:[NSString stringWithFormat:@"%.0f", next] forKey:nextStartKey(src)];
}

- (NSString *)sourceOf:(SFDownloadRecord *)r {
    SFItem *item = [self itemFromRec:r];
    return prefixOf(item.resolverRef ?: item.identifier ?: r.identifier);
}

// Epoch until which the record's source has paused itself (0 = go).
- (NSTimeInterval)pausedUntil:(SFDownloadRecord *)r {
    return SFBackgroundPausedUntil([[self sourceOf:r] stringByAppendingString:@":"]);
}

// pausedUntil plus the per-source spacing of starts (not for the run an exit interrupted - the same
// download going on, e.g. after an update, 2026-11-06: it waited 16 min)
- (NSTimeInterval)notBefore:(SFDownloadRecord *)r {
    if ([r.identifier isEqualToString:_resumeID]) return [self pausedUntil:r];
    return MAX([self pausedUntil:r], [self nextStartOf:[self sourceOf:r]]);
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
    _task = nil; _runningID = nil; _runningPart = nil;
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
    if (r && !ok && [self fileExists:r]) {
        // a repair download failed: keep the existing file instead of losing it, and remember the
        // repair (retryAt, persisted) so retryDueRepairs tries again with backoff - YouTube's bot
        // check often blocks for hours, a single attempt would leave the file broken
        NSInteger n = r.tries + 1;
        r.state = SFDLDone; r.progress = 1;
        r.tries = n; r.error = error ?: @"Fehler";
        r.retryAt = n < kSubMaxTries ? [NSDate date].timeIntervalSince1970 + SFRetryDelay(n) : 0;
        [self save:r];
        SFLog(@"downloads: repair of %@ failed (%@) - keeping the existing file, %@", ident, error,
              n < kSubMaxTries ? [NSString stringWithFormat:@"retry in %.0f min", SFRetryDelay(n) / 60] : @"giving up");
        dispatch_async(dispatch_get_main_queue(), ^{ [self retryDueRepairs]; });   // schedules the retry
    } else if (r) {
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
