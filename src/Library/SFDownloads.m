// SFDownloads – core: persistence (downloads table), queries and actions. A download is its item's
// tracks in the media store, pinned (docs/media-store.md); the queue and the fill: SFDownloads+Worker.m.
// Shared ivars: +Private.h.
#import "SFDownloads+Private.h"
#import "SFMediaStore.h"
#import "SFMediaProxy.h"
#import "SFEngine.h"

NSString *const SFDownloadsDidChangeNotification = @"SFDownloadsDidChangeNotification";
NSString *const SFDownloadsStorageDidChangeNotification = @"SFDownloadsStorageDidChangeNotification";
NSString *const SFUnsortedChannel = @"Einzelne Videos";


@implementation SFDownloads

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
        // a download, and what a pending download is going to read, stay
        __weak SFDownloads *ws = self;
        m.isPinned = ^BOOL(NSString *item) { return [ws.storePinned containsObject:item]; };
    });
    return m;
}

// the real app: ~/Movies/Sofa; a dev instance keeps its downloads in its own data directory
+ (NSString *)root { return SFDevMode ? [SFAppSupportDir() stringByAppendingPathComponent:@"Downloads"] : [NSHomeDirectory() stringByAppendingPathComponent:@"Movies/Sofa"]; }

- (instancetype)init {
    if ((self = [super init])) {
        SFStore *st = [SFStore shared];
        _recs = [NSMutableDictionary new];
        _itemCache = [NSMutableDictionary new];
        for (NSDictionary *row in [st rows:@"SELECT d.*, i.json AS item FROM downloads d LEFT JOIN items i ON i.id = d.id" args:nil]) {
            SFDownloadRecord *r = [SFDownloadRecord recordWithRow:row];
            if (r.identifier) _recs[r.identifier] = r;
        }
        // re-queue runs interrupted last time
        for (SFDownloadRecord *r in _recs.allValues)
            if (r.state == SFDLRunning) { r.state = SFDLQueued; _resumeID = r.identifier; }
        NSMutableSet *pinned = [NSMutableSet new];
        for (SFDownloadRecord *r in _recs.allValues) if (PinsStore(r)) [pinned addObject:r.identifier];
        self.storePinned = pinned;
        SFLog(@"downloads: %lu entries", (unsigned long)_recs.count);
        __weak SFDownloads *ws = self;
        SFSetLocalCopyLookup(^NSURL *(NSString *ident) { return [ws localCopyOf:ident]; });
    }
    return self;
}

#pragma mark Persistence

// pending (its bytes are on their way), or done (its bytes are the download)
static BOOL PinsStore(SFDownloadRecord *r) {
    return r.state == SFDLQueued || r.state == SFDLRunning || r.state == SFDLDone;
}

- (void)notePinned:(BOOL)pinned item:(NSString *)item {
    NSSet *now = self.storePinned;
    if (!item || [now containsObject:item] == pinned) return;
    NSMutableSet *next = [now mutableCopy] ?: [NSMutableSet new];
    if (pinned) [next addObject:item]; else [next removeObject:item];
    self.storePinned = next;
}

- (void)save:(SFDownloadRecord *)r {
    NSArray *w = [self write:r];
    [[SFStore shared] run:w[0] args:w[1]];
}

// the statement that stores a record (save:, or several in one runAll:)
- (NSArray *)write:(SFDownloadRecord *)r {
    [_itemCache removeObjectForKey:r.identifier];
    [self notePinned:PinsStore(r) item:r.identifier];
    _generation++;
    return r.writeStatement;
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
    return r.state;
}

- (SFDownloadRecord *)recOf:(NSString *)identifier { return identifier ? _recs[identifier] : nil; }

// What plays without the source: an item complete in the media store that the media proxy serves (its
// stored subtitles go along as the player's source). YouTube items answer for themselves (their stored
// sessions, SFYTEngine+Store.m).
- (NSURL *)localCopyOf:(NSString *)ident {
    NSArray *subs = nil;
    NSURL *stored = [[SFMediaProxy shared] storedURLFor:ident subs:&subs];
    if (stored) SFSetMPVSource(stored, @{@"subs": subs ?: @[], @"stored": @YES});
    return stored;
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
    return r.state == SFDLDone ? [self itemFromRec:r] : nil;
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

- (unsigned long long)bytesOf:(NSString *)ident {
    long long n = ident ? [self.mediaStore bytesOfItem:ident] : 0;
    return n > 0 ? (unsigned long long)n : 0;
}

- (unsigned long long)bytesUsedFor:(NSString *)source {
    unsigned long long n = 0;
    for (SFDownloadRecord *r in _recs.allValues)
        if (r.state == SFDLDone && (!source || [r.source isEqualToString:source])) n += [self bytesOf:r.identifier];
    return n;
}

- (unsigned long long)freeBytes {
    NSString *root = [SFDownloads root];
    NSString *p = [[NSFileManager defaultManager] fileExistsAtPath:root] ? root : NSHomeDirectory();
    return [[[NSFileManager defaultManager] attributesOfFileSystemForPath:p error:nil][NSFileSystemFreeSize] unsignedLongLongValue];
}

- (SFDownloadRecord *)recordFor:(NSString *)identifier {
    SFDownloadRecord *r = identifier ? _recs[identifier] : nil;
    return r.state == SFDLDone ? [r copy] : nil;
}

- (NSString *)storageSummary:(NSString *)source {
    return [NSString stringWithFormat:@"%@ belegt · %@ frei", SFFormatBytes([self bytesUsedFor:source]), SFFormatBytes([self freeBytes])];
}

- (NSUInteger)removeAllOfChannel:(NSString *)channel source:(NSString *)source {
    NSUInteger n = 0;
    for (SFDownloadRecord *r in [_recs.allValues copy]) {
        NSString *rc = r.channel.length ? r.channel : SFUnsortedChannel;
        if (![rc isEqualToString:channel] || (source && ![r.source isEqualToString:source])) continue;
        if (r.keep) continue;   // "Behalten" survives deleting the show
        [self remove:r.identifier];
        n++;
    }
    SFLog(@"downloads: deleted %lu downloads of %@", (unsigned long)n, channel);
    return n;
}

#pragma mark Actions

- (void)download:(SFItem *)item told:(void (^)(NSString *))told {
    NSString *ident = item.identifier;
    [self download:item];
    SFMediaStore *store = self.mediaStore;
    if ([store bytesOfItem:ident] <= 0) { told(@"Wird heruntergeladen – auch offline verfügbar"); return; }
    SFBackground(^{   // the missing bytes wait for the store's queue (its tracks' ranges)
        long long missing = ident ? [store missingBytesOf:ident] : -1;
        SFMain(^{
            if (missing == 0) told(@"Heruntergeladen – war schon vollständig geladen");
            else if (missing > 0) told([NSString stringWithFormat:@"Wird heruntergeladen – noch %@, der Rest ist schon geladen", SFFormatBytes((unsigned long long)missing)]);
            else told(@"Wird heruntergeladen – Geladenes wird übernommen");
        });
    });
}

// queued unless it is already there (pending or done); a failed one is tried again
- (void)download:(SFItem *)item {
    if (!item.identifier || item.kind != SFItemVideo) return;
    SFDownloadRecord *r = _recs[item.identifier];
    if (r && r.state != SFDLFailed) return;
    r = r ?: [SFDownloadRecord new];
    r.identifier = item.identifier;
    r.source = item.source ?: @"";
    r.channel = item.channel ?: @"";
    [self setItem:item ofRec:r];
    r.state = SFDLQueued;
    r.progress = 0;
    r.added = [[NSDate date] timeIntervalSince1970];
    if (item.date) r.published = [item.date timeIntervalSince1970];
    r.error = nil;
    _recs[item.identifier] = r;
    [self save:r];
    [self changed:item.identifier];
    SFLog(@"downloads: + %@", item.title);
    [self pump];
}

- (void)remove:(NSString *)identifier {
    SFDownloadRecord *r = _recs[identifier];
    if (!r) return;
    if ([identifier isEqualToString:_runningID]) {   // running: free the slot right away, drop the callbacks
        [self abortRun];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pump]; });
    }
    [self.mediaStore removeItem:identifier];   // its bytes are the download
    if (r.thumb) [[NSFileManager defaultManager] removeItemAtPath:r.thumb error:nil];
    [self pruneEmptyDirs:[r.thumb stringByDeletingLastPathComponent]];
    [_recs removeObjectForKey:identifier];
    [_itemCache removeObjectForKey:identifier];
    [self notePinned:NO item:identifier];
    _generation++;
    [[SFStore shared] run:@"DELETE FROM downloads WHERE id=?" args:@[identifier]];
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

// Not a failure: the running fill is let go (it stays Running in the database; the next start queues
// it again and fetches only the rest - what it stored stays).
- (void)stopForExit {
    if (!_fillCancel) return;
    SFLog(@"downloads: stopping the download before exit (%@ resumes on the next start)", _runningID);
    [self abortRun];
}

- (void)start {
    if (_started) return;
    _started = YES;
    [self verifyStoreDownloads];
    [[NSNotificationCenter defaultCenter] addObserverForName:SFNetOnlineDidChangeNotification object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { if ([SFNet isOnline]) [self pump]; }];
    [self pump];
}

#pragma mark Paths

- (NSString *)folderForSource:(NSString *)source channel:(NSString *)channel {
    return [[[SFDownloads root] stringByAppendingPathComponent:safeName(source ?: @"", 20)] stringByAppendingPathComponent:safeName(channel ?: @"Einzelne", 80)];
}

@end
