// SFDownloads – core: persistence (downloads table), queries, queue, ffmpeg run,
// actions and migration. Subscriptions: SFDownloads+Subscriptions.m; shared ivars: +Private.h.
#import "SFDownloads+Private.h"
#import <signal.h>

NSString *const SFDownloadsDidChangeNotification = @"SFDownloadsDidChangeNotification";
NSString *const SFDownloadsStorageDidChangeNotification = @"SFDownloadsStorageDidChangeNotification";
NSString *const SFUnsortedChannel = @"Einzelne Videos";


static NSString *safeName(NSString *s, NSUInteger max) {
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

static NSString *idHash(NSString *s) {   // FNV-1a 64 bit, stable
    uint64_t h = 1469598103934665603ULL;
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *b = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) { h ^= b[i]; h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)h];
}

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
    [_itemCache removeObjectForKey:r[@"id"]];
    _generation++;
    [[SFStore shared] run:@"INSERT OR REPLACE INTO downloads (id,source,channel,item,path,thumb,state,progress,bytes,added,published,sub,error,tries,failedAt,keep,online,onlineAt) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
                     args:@[r[@"id"], r[@"source"] ?: [NSNull null], r[@"channel"] ?: [NSNull null], r[@"item"] ?: [NSNull null],
                            r[@"path"] ?: [NSNull null], r[@"thumb"] ?: [NSNull null], r[@"state"] ?: @0, r[@"progress"] ?: @0.0,
                            r[@"bytes"] ?: @0, r[@"added"] ?: @0.0, r[@"published"] ?: [NSNull null], r[@"sub"] ?: [NSNull null],
                            r[@"error"] ?: [NSNull null], r[@"tries"] ?: @0, r[@"failedAt"] ?: [NSNull null],
                            r[@"keep"] ?: @0, r[@"online"] ?: [NSNull null], r[@"onlineAt"] ?: [NSNull null]]];
}

// Subscription episodes: retry failed downloads with growing intervals (15 min, 30 min, 1 h …,
// ~16 h in total). YouTube throttles at times ("Sign in to confirm you're not a bot") – without
// spacing, the attempts were used up within minutes and the episode was lost for good.
static const NSInteger kSubMaxTries = 6;
static NSTimeInterval SFRetryDelay(NSInteger tries) {
    static double base;   // 15 min; tests shorten it (SOFA_RETRY_BASE)
    static dispatch_once_t once;
    dispatch_once(&once, ^{ base = SFDevSeconds(@"SOFA_RETRY_BASE", 900); });
    return base * (1 << MAX(0, MIN(tries, 10) - 1));
}

// Marks a finished file whose repair download failed and is to be retried (error column).
static NSString *const kRepairPrefix = @"repair: ";

// Re-queues repairs whose backoff has elapsed and schedules itself for the next one that becomes
// due (before: only at start and every 3 h, so a 15-min backoff could take hours). Also called at
// start, after a failed repair and with every subscription check.
- (void)retryDueRepairs {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970, next = 0;
    BOOL any = NO;
    for (NSMutableDictionary *r in _recs.allValues) {
        if ([r[@"state"] integerValue] != SFDLDone || ![r[@"error"] hasPrefix:kRepairPrefix]) continue;
        NSInteger n = [r[@"tries"] integerValue];
        if (n >= kSubMaxTries) continue;
        NSTimeInterval due = [r[@"failedAt"] doubleValue] + SFRetryDelay(n);
        if (due > now) { next = next ? MIN(next, due) : due; continue; }
        if (![[NSFileManager defaultManager] fileExistsAtPath:r[@"path"]]) continue;
        SFLog(@"downloads: retrying the repair of %@ (attempt %ld)", r[@"id"], (long)n + 1);
        [r removeObjectForKey:@"error"];
        r[@"state"] = @(SFDLQueued); r[@"progress"] = @0;
        [self save:r]; [self changed:r[@"id"]];
        any = YES;
    }
    if (any) [self pump];
    if (next && (!_repairWake || next < _repairWake || _repairWake <= now)) {
        _repairWake = next;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((next - now + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_repairWake == next) self->_repairWake = 0;
            [self retryDueRepairs];
        });
    }
}

- (void)expireRepairBackoffForTesting {
    for (NSMutableDictionary *r in _recs.allValues) if ([r[@"error"] hasPrefix:kRepairPrefix]) r[@"failedAt"] = @0;
}

- (BOOL)willRetry:(NSString *)identifier {
    NSDictionary *r = _recs[identifier];
    return r[@"sub"] && [r[@"state"] integerValue] == SFDLFailed && [r[@"tries"] integerValue] < kSubMaxTries;
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
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    return j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : nil;
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
    if (subID && r && st == SFDLFailed) {
        NSInteger n = [r[@"tries"] integerValue];
        if (n >= kSubMaxTries) return NO;
        if ([NSDate date].timeIntervalSince1970 - [r[@"failedAt"] doubleValue] < SFRetryDelay(n)) return NO;   // keep waiting
    }
    if (subID && r && !r[@"sub"]) subID = nil;   // downloaded manually once = manual (no retention)
    // subscription episodes belong to the subscription's show (ZDF/ARD often name the series differently)
    NSString *subTitle = subID ? _subs[subID][@"title"] : nil;
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
    [r removeObjectForKey:@"error"];
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
    // subscriptions: shortly after start, then every 3 h; cleanup on every check
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self checkSubscriptionsNow]; });
    _checkTimer = [NSTimer scheduledTimerWithTimeInterval:3 * 3600 target:self selector:@selector(checkSubscriptionsNow) userInfo:nil repeats:YES];
}

- (NSString *)folderForSource:(NSString *)source channel:(NSString *)channel {
    return [[[SFDownloads root] stringByAppendingPathComponent:safeName(source ?: @"", 20)] stringByAppendingPathComponent:safeName(channel ?: @"Einzelne", 80)];
}

- (NSString *)targetPathFor:(NSDictionary *)r item:(SFItem *)item {
    NSString *dir = [self folderForSource:r[@"source"] channel:item.channel];
    NSString *rest = restOf(item.identifier);
    // short IDs (YouTube) readable; long ones (ARD crid base64, ZDF canonical) share long prefixes -> hash
    NSString *idPart = rest.length <= 16 ? safeName(rest, 16) : idHash(item.identifier);
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ [%@].mp4", safeName(item.title ?: @"Video", 120), idPart]];
}

- (void)pump {
    if (!_started || _runningID) return;
    if (![SFNet isOnline]) return;   // offline: wait instead of using up attempts (continues on SFNetOnlineDidChange)
    // manual downloads before subscription downloads, oldest request first in each
    NSDictionary *next = nil;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970, wake = 0;
    for (NSDictionary *r in _recs.allValues) {
        if ([r[@"state"] integerValue] != SFDLQueued) continue;
        NSTimeInterval until = [self notBefore:r];
        if (until > now) { wake = wake ? MIN(wake, until) : until; continue; }   // source paused: later
        if (!next) { next = r; continue; }
        BOOL rm = r[@"sub"] == nil, nm = next[@"sub"] == nil;
        if (rm != nm) { if (rm) next = r; continue; }
        if ([r[@"added"] doubleValue] < [next[@"added"] doubleValue]) next = r;
    }
    if (!next) { if (wake) [self pumpAt:wake]; else [self setStorageFull:NO]; return; }
    if ([self checkStorageFor:next]) return;   // not enough room for it: wait (re-checked every minute, user asked)
    NSString *ff = ffmpegPath();
    if (!ff) { SFLog(@"downloads: ffmpeg missing"); return; }
    NSMutableDictionary *r = _recs[next[@"id"]];
    SFItem *item = [self itemFromRec:r];
    if (!item) {
        r[@"state"] = @(SFDLFailed); r[@"error"] = @"Eintrag unlesbar"; r[@"tries"] = @(kSubMaxTries);
        [self save:r];
        dispatch_async(dispatch_get_main_queue(), ^{ [self pump]; });
        return;
    }
    _runningID = r[@"id"];
    if (!_lastStart) _lastStart = [NSMutableDictionary new];
    _lastStart[[self sourceOf:r]] = @(now);
    r[@"state"] = @(SFDLRunning); r[@"progress"] = @0;
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
                r[@"published"] = @([published timeIntervalSince1970]);
                r[@"item"] = [self itemJSON:item];
                [self save:r];
            }
            [self runFFmpeg:ff url:url audio:audio rec:r item:item];
        });
    };
    if (custom) [app downloadSourceForItem:item done:got]; else [item resolveURL:^(NSURL *url, NSError *e) { got(url, nil, nil, e); }];
}

- (void)runFFmpeg:(NSString *)ff url:(NSURL *)url audio:(NSURL *)audio rec:(NSMutableDictionary *)r item:(SFItem *)item {
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
    NSString *ident = r[@"id"];
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
            r[@"progress"] = @(p);
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
                if ([self->_recs[ident][@"state"] integerValue] != SFDLRunning) return;   // cancelled
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

- (void)installPart:(NSString *)part target:(NSString *)target rec:(NSMutableDictionary *)r item:(SFItem *)item {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *old = r[@"path"];   // repair of an earlier file whose name changed: drop the old one
    if (old.length && ![old isEqualToString:target]) [fm removeItemAtPath:old error:nil];
    [fm removeItemAtPath:target error:nil];
    [fm moveItemAtPath:part toPath:target error:nil];
    r[@"path"] = target;
    r[@"bytes"] = @([[fm attributesOfItemAtPath:target error:nil] fileSize]);
    [self fetchThumb:item rec:r];
    [self finish:r[@"id"] ok:YES error:nil];
}

- (void)fetchThumb:(SFItem *)item rec:(NSMutableDictionary *)r {
    NSString *img = item.image;
    if (![img hasPrefix:@"http"]) return;
    NSString *thumb = [[r[@"path"] stringByDeletingPathExtension] stringByAppendingString:@".jpg"];
    NSString *ident = r[@"id"];
    SFBackground(^{
        NSInteger st = 0;
        NSData *d = SFCurlFetch(img, @"GET", nil, nil, &st, NULL);
        if (d.length && st < 400 && [d writeToFile:thumb atomically:YES]) SFMain(^{
            NSMutableDictionary *rr = self->_recs[ident];
            if (!rr) return;
            rr[@"thumb"] = thumb; [self save:rr]; [self changed:ident];
        });
    });
}

// Epoch until which the record's source must not be asked (0 = go).
// Starts per source at least this far apart: quick failures or short videos must not turn into a
// burst of requests to one site (YouTube flags the IP for bursts of player requests).
static NSTimeInterval SFSourceGap(void) {   // 30 s; tests shorten it (SOFA_SOURCE_GAP)
    static NSTimeInterval gap; static dispatch_once_t once;
    dispatch_once(&once, ^{ gap = SFDevSeconds(@"SOFA_SOURCE_GAP", 30); });
    return gap;
}

- (NSString *)sourceOf:(NSDictionary *)r {
    SFItem *item = [self itemFromRec:r];
    return prefixOf(item.resolverRef ?: item.identifier ?: r[@"id"]);
}

// Epoch until which the record's source has paused itself (0 = go).
- (NSTimeInterval)pausedUntil:(NSDictionary *)r {
    Class<SFApp> app = [SFAppRegistry appForRef:[[self sourceOf:r] stringByAppendingString:@":"]];
    return [app respondsToSelector:@selector(downloadsPausedUntil)] ? [app downloadsPausedUntil] : 0;
}

// pausedUntil plus the per-source spacing of starts
- (NSTimeInterval)notBefore:(NSDictionary *)r {
    NSString *src = [self sourceOf:r];
    NSTimeInterval last = [_lastStart[src] doubleValue];
    return MAX([self pausedUntil:r], last ? last + SFSourceGap() : 0);
}

- (void)pumpAt:(NSTimeInterval)when {
    if (_pauseWake && _pauseWake <= when && _pauseWake > [NSDate date].timeIntervalSince1970) return;   // earlier wake pending
    _pauseWake = when;
    NSTimeInterval in = MAX(1, when - [NSDate date].timeIntervalSince1970 + 1);
    if (in > SFSourceGap() + 2) SFLog(@"downloads: source paused - next attempt in %.0f min", round(in / 60));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(in * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_pauseWake == when) self->_pauseWake = 0;
        [self pump];
    });
}

- (void)finish:(NSString *)ident ok:(BOOL)ok error:(NSString *)error {
    NSMutableDictionary *r = _recs[ident];
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
        r[@"state"] = @(SFDLQueued); r[@"progress"] = @0;
        [self save:r]; [self changed:ident];
        SFLog(@"downloads: %@ deferred (%@)", ident, error);
        dispatch_async(dispatch_get_main_queue(), ^{ [self pump]; });
        return;
    }
    if (r && !ok && [r[@"path"] length] && [[NSFileManager defaultManager] fileExistsAtPath:r[@"path"]]) {
        // a repair download failed: keep the existing file instead of losing it, and remember the
        // repair (error prefix kRepairPrefix, persisted) so retryDueRepairs tries again with backoff -
        // YouTube's bot check often blocks for hours, a single attempt would leave the file broken
        NSInteger n = [r[@"tries"] integerValue] + 1;
        r[@"state"] = @(SFDLDone); r[@"progress"] = @1.0;
        r[@"tries"] = @(n); r[@"failedAt"] = @([NSDate date].timeIntervalSince1970);
        r[@"error"] = [kRepairPrefix stringByAppendingString:error ?: @""];
        [self save:r];
        SFLog(@"downloads: repair of %@ failed (%@) - keeping the existing file, %@", ident, error,
              n < kSubMaxTries ? [NSString stringWithFormat:@"retry in %.0f min", SFRetryDelay(n) / 60] : @"giving up");
        dispatch_async(dispatch_get_main_queue(), ^{ [self retryDueRepairs]; });   // schedules the retry
    } else if (r) {
        r[@"state"] = @(ok ? SFDLDone : SFDLFailed);
        r[@"progress"] = @(ok ? 1.0 : 0.0);
        if (ok) { [r removeObjectForKey:@"error"]; r[@"tries"] = @0; }
        if (!ok) { r[@"error"] = error ?: @"Fehler"; r[@"tries"] = @([r[@"tries"] integerValue] + 1); r[@"failedAt"] = @([NSDate date].timeIntervalSince1970); }
        [self save:r];
        SFLog(@"downloads: %@ %@%@", ok ? @"done" : @"FAILED", ident, ok ? @"" : [@" – " stringByAppendingString:error ?: @""]);
    }
    [self changed:ident];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pump]; });
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
