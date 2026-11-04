#import "SFDownloads.h"
#import "SFStore.h"
#import "SFCurl.h"
#import "SFNet.h"
#import "SFFollows.h"
#import "SFRuntime.h"

NSString *const SFDownloadsDidChangeNotification = @"SFDownloadsDidChangeNotification";
NSString *const SFUnsortedChannel = @"Einzelne Videos";

static NSMutableDictionary *gFeeds, *gDLURL;
void SFRegisterFeed(NSString *prefix, SFFeedFetcher f) { if (!gFeeds) gFeeds = [NSMutableDictionary new]; gFeeds[prefix] = [f copy]; }
SFFeedFetcher SFFeedFor(NSString *identifier) { NSRange r = [identifier rangeOfString:@":"]; return r.location == NSNotFound ? nil : gFeeds[[identifier substringToIndex:r.location]]; }
void SFRegisterDownloadURL(NSString *prefix, SFDownloadURLFetcher f) { if (!gDLURL) gDLURL = [NSMutableDictionary new]; gDLURL[prefix] = [f copy]; }
void SFRegisterFeedFromLoader(NSString *prefix, SFPageLoader (^loaderFor)(NSString *ref)) {
    SFRegisterFeed(prefix, ^(NSString *ref, void (^done)(NSArray *, NSError *)) {
        SFPageLoader l = loaderFor(ref);
        if (!l) { done(nil, SFError(@"Unbekannte Sendung")); return; }
        l(^(SFPage *page, NSError *e) {
            if (!page) { done(nil, e); return; }
            NSMutableArray *items = [NSMutableArray new];
            NSMutableSet *seen = [NSMutableSet new];
            for (SFShelf *sh in page.shelves) for (SFItem *i in sh.items)
                if (i.kind == SFItemVideo && i.identifier && ![seen containsObject:i.identifier]) { [seen addObject:i.identifier]; [items addObject:i]; }
            [items sortUsingComparator:^NSComparisonResult(SFItem *a, SFItem *b) {
                return [(b.date ?: [NSDate distantPast]) compare:(a.date ?: [NSDate distantPast])];
            }];
            done(items, nil);
        });
    });
}

static NSString *prefixOf(NSString *ref) { NSRange r = [ref rangeOfString:@":"]; return r.location == NSNotFound ? nil : [ref substringToIndex:r.location]; }
static NSString *restOf(NSString *ref) { NSRange r = [ref rangeOfString:@":"]; return r.location == NSNotFound ? ref : [ref substringFromIndex:NSMaxRange(r)]; }

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

static NSString *idHash(NSString *s) {   // FNV-1a 64 bit, stabil
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

@implementation SFDownloads {
    NSMutableDictionary *_recs;      // id -> NSMutableDictionary (Spalten der Tabelle downloads)
    NSMutableDictionary *_subs;      // id -> NSMutableDictionary
    NSTask *_task;
    NSString *_runningID;
    BOOL _started, _checking;
    NSTimer *_checkTimer;
    NSMutableDictionary *_itemCache; // id -> SFItem (aus JSON), ungültig bei save:
}

+ (instancetype)shared {
    static SFDownloads *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFDownloads new]; });
    return s;
}

// Dev-Instanzen arbeiten getrennt (eigener Ordner, eigene Tabellen) – nie die echten Downloads anfassen
+ (NSString *)root { return [NSHomeDirectory() stringByAppendingPathComponent:SFDevMode ? @"Movies/Sofa-dev" : @"Movies/Sofa"]; }
static NSString *T(NSString *sql) {
    if (!SFDevMode) return sql;
    return [[sql stringByReplacingOccurrencesOfString:@" downloads" withString:@" dev_downloads"] stringByReplacingOccurrencesOfString:@" subscriptions" withString:@" dev_subscriptions"];
}

- (instancetype)init {
    if ((self = [super init])) {
        SFStore *st = [SFStore shared];
        [st run:T(@"CREATE TABLE IF NOT EXISTS downloads (id TEXT PRIMARY KEY, source TEXT, channel TEXT, item TEXT, path TEXT, thumb TEXT, state INTEGER, progress REAL, bytes INTEGER, added REAL, published REAL, sub TEXT, error TEXT, tries INTEGER DEFAULT 0)") args:nil];
        [st run:T(@"CREATE TABLE IF NOT EXISTS subscriptions (id TEXT PRIMARY KEY, source TEXT, title TEXT, image TEXT, keepDays INTEGER, since REAL, added REAL, lastCheck REAL)") args:nil];
        _recs = [NSMutableDictionary new];
        _subs = [NSMutableDictionary new];
        _itemCache = [NSMutableDictionary new];
        for (NSDictionary *r in [st rows:T(@"SELECT * FROM downloads") args:nil]) _recs[r[@"id"]] = [r mutableCopy];
        for (NSDictionary *r in [st rows:T(@"SELECT * FROM subscriptions") args:nil]) _subs[r[@"id"]] = [r mutableCopy];
        // Abgebrochene Läufe vom letzten Mal wieder einreihen
        for (NSMutableDictionary *r in _recs.allValues)
            if ([r[@"state"] integerValue] == SFDLRunning) r[@"state"] = @(SFDLQueued);
        SFLog(@"downloads: %lu Einträge, %lu Abos", (unsigned long)_recs.count, (unsigned long)_subs.count);
        __weak SFDownloads *ws = self;
        SFSetLocalFileLookup(^NSString *(NSString *ident) { return [ws fileFor:ident]; });
    }
    return self;
}

#pragma mark Persistenz

- (void)save:(NSDictionary *)r {
    [_itemCache removeObjectForKey:r[@"id"]];
    _generation++;
    [[SFStore shared] run:T(@"INSERT OR REPLACE INTO downloads (id,source,channel,item,path,thumb,state,progress,bytes,added,published,sub,error,tries) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
                     args:@[r[@"id"], r[@"source"] ?: [NSNull null], r[@"channel"] ?: [NSNull null], r[@"item"] ?: [NSNull null],
                            r[@"path"] ?: [NSNull null], r[@"thumb"] ?: [NSNull null], r[@"state"] ?: @0, r[@"progress"] ?: @0.0,
                            r[@"bytes"] ?: @0, r[@"added"] ?: @0.0, r[@"published"] ?: [NSNull null], r[@"sub"] ?: [NSNull null],
                            r[@"error"] ?: [NSNull null], r[@"tries"] ?: @0]];
}

- (void)saveSub:(NSDictionary *)s {
    [[SFStore shared] run:T(@"INSERT OR REPLACE INTO subscriptions (id,source,title,image,keepDays,since,added,lastCheck) VALUES (?,?,?,?,?,?,?,?)")
                     args:@[s[@"id"], s[@"source"] ?: [NSNull null], s[@"title"] ?: [NSNull null], s[@"image"] ?: [NSNull null],
                            s[@"keepDays"] ?: @90, s[@"since"] ?: @0.0, s[@"added"] ?: @0.0, s[@"lastCheck"] ?: @0.0]];
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

#pragma mark Abfragen

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

- (unsigned long long)bytesUsed {
    unsigned long long n = 0;
    for (NSDictionary *r in _recs.allValues) if ([r[@"state"] integerValue] == SFDLDone) n += [r[@"bytes"] unsignedLongLongValue];
    return n;
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

- (NSString *)storageSummary:(NSString *)source {
    return [NSString stringWithFormat:@"%@ belegt · %@ frei", gb([self bytesUsedFor:source]), gb([self freeBytes])];
}

- (NSString *)subscriptionIDForChannel:(NSString *)channel source:(NSString *)source {
    if (!channel) return nil;
    for (NSDictionary *s in _subs.allValues)
        if ([s[@"title"] isEqualToString:channel] && (!source || [s[@"source"] isEqualToString:source])) return s[@"id"];
    return nil;
}

- (NSUInteger)removeAllOfChannel:(NSString *)channel source:(NSString *)source {
    NSUInteger n = 0;
    for (NSDictionary *r in [_recs.allValues copy]) {
        NSString *rc = [r[@"channel"] length] ? r[@"channel"] : SFUnsortedChannel;
        if (![rc isEqualToString:channel] || (source && ![r[@"source"] isEqualToString:source])) continue;
        SFDLState st = [r[@"state"] integerValue];
        if (st == SFDLDismissed) continue;
        [self remove:r[@"id"]];
        n++;
    }
    SFLog(@"downloads: %lu Downloads von %@ gelöscht", (unsigned long)n, channel);
    return n;
}

#pragma mark Aktionen

- (void)download:(SFItem *)item { [self enqueue:item sub:nil]; }

- (BOOL)enqueue:(SFItem *)item sub:(NSString *)subID {
    if (!item.identifier || item.kind != SFItemVideo) return NO;
    NSMutableDictionary *r = _recs[item.identifier];
    SFDLState st = r ? [r[@"state"] integerValue] : SFDLNone;
    if (r && (st == SFDLQueued || st == SFDLRunning || (st == SFDLDone && [self fileFor:item.identifier]))) return NO;
    if (subID && r && (st == SFDLDismissed || ([r[@"tries"] integerValue] >= 3 && st == SFDLFailed))) return NO;
    if (subID && r && !r[@"sub"]) subID = nil;   // einmal manuell geladen = manuell (keine Behaltefrist)
    // Abo-Folgen gehören zur Sendung des Abos (ZDF/ARD nennen die Reihe oft anders)
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
    if (subID) r[@"sub"] = subID; else [r removeObjectForKey:@"sub"];   // manuell = nie automatisch löschen
    if (!subID) r[@"tries"] = @0;
    [r removeObjectForKey:@"error"];
    _recs[item.identifier] = r;
    [self save:r];
    [self changed:item.identifier];
    SFLog(@"downloads: + %@ (%@)", item.title, subID ? @"Abo" : @"manuell");
    [self pump];
    return YES;
}

- (void)remove:(NSString *)identifier {
    NSMutableDictionary *r = _recs[identifier];
    if (!r) return;
    if ([identifier isEqualToString:_runningID]) {   // laufend: Slot sofort freigeben, Rückrufe verwerfen
        NSTask *t = _task;
        _task = nil; _runningID = nil;
        [t terminate];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pump]; });
    }
    if (r[@"path"]) [[NSFileManager defaultManager] removeItemAtPath:r[@"path"] error:nil];
    if (r[@"thumb"]) [[NSFileManager defaultManager] removeItemAtPath:r[@"thumb"] error:nil];
    [self pruneEmptyDirs:[r[@"path"] stringByDeletingLastPathComponent]];
    if (r[@"sub"]) {   // Abo-Folge: merken, damit sie nicht wiederkommt
        r[@"state"] = @(SFDLDismissed); r[@"bytes"] = @0; [r removeObjectForKey:@"path"];
        [self save:r];
    } else {
        [_recs removeObjectForKey:identifier];
        [_itemCache removeObjectForKey:identifier];
        _generation++;
        [[SFStore shared] run:T(@"DELETE FROM downloads WHERE id=?") args:@[identifier]];
    }
    [self changed:identifier];
}

- (void)pruneEmptyDirs:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [SFDownloads root];
    NSSet *decor = [NSSet setWithArray:@[@".DS_Store", @"poster.jpg", @"fanart.jpg"]];   // Sendungsbilder zählen nicht als Inhalt
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

- (void)start {
    if (_started) return;
    _started = YES;
    [[NSNotificationCenter defaultCenter] addObserverForName:SFNetOnlineDidChangeNotification object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { if ([SFNet isOnline]) [self pump]; }];
    [self pump];
    // Abos: kurz nach dem Start, dann alle 3 h; Aufräumen bei jeder Prüfung
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self checkSubscriptionsNow]; });
    _checkTimer = [NSTimer scheduledTimerWithTimeInterval:3 * 3600 target:self selector:@selector(checkSubscriptionsNow) userInfo:nil repeats:YES];
}

- (NSString *)folderForSource:(NSString *)source channel:(NSString *)channel {
    return [[[SFDownloads root] stringByAppendingPathComponent:safeName(source ?: @"", 20)] stringByAppendingPathComponent:safeName(channel ?: @"Einzelne", 80)];
}

- (NSString *)targetPathFor:(NSDictionary *)r item:(SFItem *)item {
    NSString *dir = [self folderForSource:r[@"source"] channel:item.channel];
    NSString *rest = restOf(item.identifier);
    // kurze IDs (YouTube) lesbar; lange (ARD-crid base64, ZDF-canonical) teilen lange Präfixe -> Hash
    NSString *idPart = rest.length <= 16 ? safeName(rest, 16) : idHash(item.identifier);
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ [%@].mp4", safeName(item.title ?: @"Video", 120), idPart]];
}

- (void)pump {
    if (!_started || _runningID) return;
    if (![SFNet isOnline]) return;   // offline: warten statt Versuche zu verbrauchen (weiter bei SFNetOnlineDidChange)
    // manuelle Downloads vor Abo-Downloads, jeweils älteste Anforderung zuerst
    NSDictionary *next = nil;
    for (NSDictionary *r in _recs.allValues) {
        if ([r[@"state"] integerValue] != SFDLQueued) continue;
        if (!next) { next = r; continue; }
        BOOL rm = r[@"sub"] == nil, nm = next[@"sub"] == nil;
        if (rm != nm) { if (rm) next = r; continue; }
        if ([r[@"added"] doubleValue] < [next[@"added"] doubleValue]) next = r;
    }
    if (!next) return;
    NSString *ff = ffmpegPath();
    if (!ff) { SFLog(@"downloads: ffmpeg fehlt"); return; }
    NSMutableDictionary *r = _recs[next[@"id"]];
    SFItem *item = [self itemFromRec:r];
    if (!item) {
        r[@"state"] = @(SFDLFailed); r[@"error"] = @"Eintrag unlesbar"; r[@"tries"] = @3;
        [self save:r];
        dispatch_async(dispatch_get_main_queue(), ^{ [self pump]; });
        return;
    }
    _runningID = r[@"id"];
    r[@"state"] = @(SFDLRunning); r[@"progress"] = @0;
    [self save:r];
    [self changed:_runningID];
    NSString *ident = _runningID;
    SFDownloadURLFetcher custom = gDLURL[prefixOf(item.resolverRef ?: item.identifier)];
    SFURLDone got = ^(NSURL *url, NSError *e) {
        SFMain(^{
            if (![ident isEqualToString:self->_runningID]) return;
            if (!url) { [self finish:ident ok:NO error:e.localizedDescription ?: @"Kein Stream"]; return; }
            [self runFFmpeg:ff url:url rec:r item:item];
        });
    };
    if (custom) custom(item, got); else [item resolveURL:got];
}

- (void)runFFmpeg:(NSString *)ff url:(NSURL *)url rec:(NSMutableDictionary *)r item:(SFItem *)item {
    NSString *target = [self targetPathFor:r item:item];
    NSString *part = [[target stringByDeletingPathExtension] stringByAppendingString:@".part.mp4"];
    [[NSFileManager defaultManager] createDirectoryAtPath:[target stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *src = [[SFStreamProxy shared] playableURLFor:url];   // ORF & Co. über die TLS-Brücke
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/bin/nice";
    NSMutableArray *args = [@[@"-n", @"10", ff, @"-nostdin", @"-hide_banner", @"-loglevel", @"error", @"-y", @"-progress", @"pipe:1",
                              // Bandbreite schonen: höchstens 3x Abspielgeschwindigkeit (Hintergrund-Downloads sollen
                              // Streaming am TV und andere Verbindungen nicht ausbremsen); kurzer Anlauf ungedrosselt
                              @"-readrate", @"3", @"-readrate_initial_burst", @"10",
                              @"-i", src.absoluteString, @"-c", @"copy", @"-movflags", @"+faststart"] mutableCopy];
    if (![src.path.pathExtension.lowercaseString isEqualToString:@"mp4"]) [args addObjectsFromArray:@[@"-bsf:a", @"aac_adtstoasc"]];
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
                [fm removeItemAtPath:target error:nil];
                [fm moveItemAtPath:part toPath:target error:nil];
                r[@"path"] = target;
                r[@"bytes"] = @([[fm attributesOfItemAtPath:target error:nil] fileSize]);
                [self fetchThumb:item rec:r];
                [self finish:ident ok:YES error:nil];
            } else {
                [fm removeItemAtPath:part error:nil];
                NSString *msg; @synchronized (errData) { msg = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding]; }
                if ([self->_recs[ident][@"state"] integerValue] != SFDLRunning) return;   // abgebrochen
                [self finish:ident ok:NO error:[msg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"ffmpeg-Fehler"];
            }
        });
    };
    @try { [t launch]; }
    @catch (NSException *ex) { [self finish:ident ok:NO error:ex.reason]; return; }
    _task = t;
    SFLog(@"downloads: lade %@", item.title);
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

- (void)finish:(NSString *)ident ok:(BOOL)ok error:(NSString *)error {
    NSMutableDictionary *r = _recs[ident];
    _task = nil; _runningID = nil;
    if (r) {
        r[@"state"] = @(ok ? SFDLDone : SFDLFailed);
        r[@"progress"] = @(ok ? 1.0 : 0.0);
        if (!ok) { r[@"error"] = error ?: @"Fehler"; r[@"tries"] = @([r[@"tries"] integerValue] + 1); }
        [self save:r];
        SFLog(@"downloads: %@ %@%@", ok ? @"fertig" : @"FEHLER", ident, ok ? @"" : [@" – " stringByAppendingString:error ?: @""]);
    }
    [self changed:ident];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pump]; });
}

#pragma mark Abos

- (BOOL)canSubscribe:(SFItem *)folder { return folder.identifier && gFeeds[prefixOf(folder.identifier)] != nil; }
- (BOOL)isSubscribed:(NSString *)fid { return fid && _subs[fid] != nil; }
- (NSArray *)subscriptions {
    return [_subs.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] ?: @"" localizedCaseInsensitiveCompare:b[@"title"] ?: @""];
    }];
}

- (void)addSubscriptionRecord:(NSDictionary *)rec {
    NSMutableDictionary *s = [rec mutableCopy];
    if (!s[@"id"]) return;
    s[@"added"] = s[@"added"] ?: @([[NSDate date] timeIntervalSince1970]);
    s[@"keepDays"] = s[@"keepDays"] ?: @90;
    _subs[s[@"id"]] = s;
    [self saveSub:s];
}

- (void)subscribe:(SFItem *)folder {
    if (![self canSubscribe:folder]) return;
    NSMutableDictionary *s = [@{@"id": folder.identifier, @"source": folder.source ?: @"", @"title": folder.title ?: @"",
                                @"keepDays": @90, @"since": @0, @"added": @([[NSDate date] timeIntervalSince1970])} mutableCopy];
    if (folder.image) s[@"image"] = folder.image;
    _subs[folder.identifier] = s;
    [self saveSub:s];
    SFLog(@"downloads: Automatisch herunterladen an: %@ (%@)", folder.title, folder.identifier);
    [[SFFollows shared] follow:folder];   // Automatisch herunterladen setzt Folgen voraus
    [self changed:folder.identifier];
    [self checkSub:s initial:YES done:nil];
}

- (void)unsubscribe:(NSString *)fid {
    if (!_subs[fid]) return;
    SFLog(@"downloads: Automatisch herunterladen aus: %@ (%@)", _subs[fid][@"title"], fid);
    [_subs removeObjectForKey:fid];
    [[SFStore shared] run:T(@"DELETE FROM subscriptions WHERE id=?") args:@[fid]];
    // bereits geladene Folgen bleiben, werden aber nicht mehr automatisch gelöscht
    for (NSMutableDictionary *r in _recs.allValues)
        if ([r[@"sub"] isEqualToString:fid] && [r[@"state"] integerValue] != SFDLDismissed) { [r removeObjectForKey:@"sub"]; [self save:r]; }
    [self changed:fid];
}

- (void)checkSub:(NSMutableDictionary *)s initial:(BOOL)initial done:(dispatch_block_t)done {
    SFFeedFetcher f = gFeeds[prefixOf(s[@"id"])];
    if (!f) { if (done) done(); return; }
    f(restOf(s[@"id"]), ^(NSArray *items, NSError *e) {
        SFMain(^{
            if (self->_subs[s[@"id"]] != s) { if (done) done(); return; }   // inzwischen abbestellt/ersetzt
            if (!items) { SFLog(@"downloads: Abo %@: %@", s[@"title"], e.localizedDescription); if (done) done(); return; }
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            double keep = ([s[@"keepDays"] doubleValue] ?: 90) * 86400;
            double since = [s[@"since"] doubleValue];
            NSInteger added = 0, n = 0;
            for (SFItem *it in items) {
                if (it.kind != SFItemVideo) continue;
                n++;
                if (initial && n > 3) {                              // neues Abo: die 3 neuesten, Älteres nie nachladen
                    double pub3 = it.date ? [it.date timeIntervalSince1970] : now;
                    if ([s[@"since"] doubleValue] <= 0) s[@"since"] = @(pub3);
                    break;
                }
                double pub = it.date ? [it.date timeIntervalSince1970] : 0;
                if (pub && pub < now - keep) break;                   // älter als Behaltefrist
                if (since > 0 && pub && pub <= since) break;         // migrierte Abos: nur Neues
                if ([[SFStore shared] watched:it.identifier]) continue;
                if (added >= 5) break;                               // pro Prüfung höchstens 5
                if ([self enqueue:it sub:s[@"id"]]) added++;
            }
            s[@"lastCheck"] = @(now);
            [self saveSub:s];
            if (added) SFLog(@"downloads: Abo %@: %ld neu", s[@"title"], (long)added);
            if (done) done();
        });
    });
}

- (void)checkSubscriptionsNow {
    if (_checking || ![SFNet isOnline]) return;
    _checking = YES;
    [self cleanup];
    NSArray *all = [_subs.allValues copy];
    __block NSUInteger i = 0;
    __block void (^next)(void);
    __weak SFDownloads *ws = self;
    next = ^{
        SFDownloads *me = ws;
        if (!me) return;
        if (i >= all.count) { me->_checking = NO; next = nil; SFLog(@"downloads: Abo-Prüfung fertig"); return; }
        NSMutableDictionary *s = all[i++];
        // nacheinander, mit kleiner Pause (schont die Quellen)
        __block BOOL called = NO;
        dispatch_block_t step = ^{
            if (called) return;
            called = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (next) next(); });
        };
        [me checkSub:s initial:NO done:step];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)), dispatch_get_main_queue(), step);   // Zeitlimit je Feed
    };
    next();
}

static NSString *deleteWatchedKey(void) { return SFDevMode ? @"downloads.dev.deleteWatched" : @"downloads.deleteWatched"; }   // Dev nie die echte Einstellung
- (BOOL)deletesWatched { return ![[[SFStore shared] setting:deleteWatchedKey()] isEqualToString:@"0"]; }
- (void)setDeletesWatched:(BOOL)on {
    [[SFStore shared] setSetting:on ? @"1" : @"0" forKey:deleteWatchedKey()];
    _generation++;
    [self changed:nil];
    SFLog(@"downloads: gesehene Abo-Folgen löschen %@", on ? @"an" : @"aus");
    if (on) [self cleanup];
}

// Behaltefrist: Abo-Folgen nach keepDays (ab Veröffentlichung) löschen;
// Smart Downloads: gesehene Abo-Folgen 1 Tag nach dem Ansehen
- (void)cleanup {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (self.deletesWatched) {
        NSMutableDictionary *seen = [NSMutableDictionary new];   // id -> Zeitpunkt "gesehen"
        for (NSDictionary *row in [[SFStore shared] rows:[NSString stringWithFormat:@"SELECT id, updated FROM %@ WHERE watched=1", SFProgressTable()] args:nil]) seen[row[@"id"]] = row[@"updated"];
        for (NSMutableDictionary *r in [_recs.allValues copy]) {
            if ([r[@"state"] integerValue] != SFDLDone || !r[@"sub"]) continue;
            NSNumber *w = seen[r[@"id"]];
            if (w && [w doubleValue] < now - 86400) {
                SFLog(@"downloads: gesehen, gelöscht: %@", r[@"id"]);
                [self remove:r[@"id"]];
            }
        }
    }
    for (NSMutableDictionary *r in [_recs.allValues copy]) {
        if ([r[@"state"] integerValue] != SFDLDone || !r[@"sub"]) continue;
        NSDictionary *s = _subs[r[@"sub"]];
        double keep = ([s[@"keepDays"] doubleValue] ?: 90) * 86400;
        double pub = [r[@"published"] doubleValue] ?: [r[@"added"] doubleValue];
        if (pub && pub < now - keep) {
            SFLog(@"downloads: Behaltefrist abgelaufen: %@", r[@"id"]);
            [self remove:r[@"id"]];
        }
    }
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
    if (![fm moveItemAtPath:path toPath:target error:err]) return NO;      // gleiches Volume: nur umbenennen
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
