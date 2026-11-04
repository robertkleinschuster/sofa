// SFDownloads – Kern: Persistenz (Tabelle downloads), Abfragen, Warteschlange, ffmpeg-Lauf,
// Aktionen und Migration. Abos: SFDownloads+Subscriptions.m; gemeinsame Ivars: +Private.h.
#import "SFDownloads+Private.h"

NSString *const SFDownloadsDidChangeNotification = @"SFDownloadsDidChangeNotification";
NSString *const SFUnsortedChannel = @"Einzelne Videos";

static NSMutableDictionary *gDLURL;   // prefix -> SFDownloadURLFetcher
void SFRegisterDownloadURL(NSString *prefix, SFDownloadURLFetcher f) { if (!gDLURL) gDLURL = [NSMutableDictionary new]; gDLURL[prefix] = [f copy]; }

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

@implementation SFDownloads

+ (instancetype)shared {
    static SFDownloads *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFDownloads new]; });
    return s;
}

// Dev-Instanzen arbeiten getrennt (eigener Ordner, eigene Tabellen) – nie die echten Downloads anfassen
+ (NSString *)root { return [NSHomeDirectory() stringByAppendingPathComponent:SFDevMode ? @"Movies/Sofa-dev" : @"Movies/Sofa"]; }

- (instancetype)init {
    if ((self = [super init])) {
        SFStore *st = [SFStore shared];
        [st run:@"CREATE TABLE IF NOT EXISTS downloads (id TEXT PRIMARY KEY, source TEXT, channel TEXT, item TEXT, path TEXT, thumb TEXT, state INTEGER, progress REAL, bytes INTEGER, added REAL, published REAL, sub TEXT, error TEXT, tries INTEGER DEFAULT 0)" args:nil];
        // Spalte failedAt (Abo-Wiederholung mit Backoff) für ältere Datenbanken nachrüsten
        BOOL hasFailedAt = NO;
        for (NSDictionary *c in [st rows:@"PRAGMA table_info(downloads)" args:nil]) if ([c[@"name"] isEqual:@"failedAt"]) hasFailedAt = YES;
        if (!hasFailedAt) [st run:@"ALTER TABLE downloads ADD COLUMN failedAt REAL" args:nil];
        [st run:@"CREATE TABLE IF NOT EXISTS subscriptions (id TEXT PRIMARY KEY, source TEXT, title TEXT, image TEXT, keepDays INTEGER, since REAL, added REAL, lastCheck REAL)" args:nil];
        _recs = [NSMutableDictionary new];
        _subs = [NSMutableDictionary new];
        _itemCache = [NSMutableDictionary new];
        for (NSDictionary *r in [st rows:@"SELECT * FROM downloads" args:nil]) _recs[r[@"id"]] = [r mutableCopy];
        for (NSDictionary *r in [st rows:@"SELECT * FROM subscriptions" args:nil]) _subs[r[@"id"]] = [r mutableCopy];
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
    [[SFStore shared] run:@"INSERT OR REPLACE INTO downloads (id,source,channel,item,path,thumb,state,progress,bytes,added,published,sub,error,tries,failedAt) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
                     args:@[r[@"id"], r[@"source"] ?: [NSNull null], r[@"channel"] ?: [NSNull null], r[@"item"] ?: [NSNull null],
                            r[@"path"] ?: [NSNull null], r[@"thumb"] ?: [NSNull null], r[@"state"] ?: @0, r[@"progress"] ?: @0.0,
                            r[@"bytes"] ?: @0, r[@"added"] ?: @0.0, r[@"published"] ?: [NSNull null], r[@"sub"] ?: [NSNull null],
                            r[@"error"] ?: [NSNull null], r[@"tries"] ?: @0, r[@"failedAt"] ?: [NSNull null]]];
}

// Abo-Folgen: fehlgeschlagene Downloads mit wachsendem Abstand wiederholen (15 min, 30 min, 1 h …,
// insgesamt ~16 h). YouTube drosselt zeitweise („Sign in to confirm you're not a bot“) – ohne
// Abstand waren die Versuche in Minuten verbraucht und die Folge für immer verloren.
static const NSInteger kSubMaxTries = 6;
static NSTimeInterval SFRetryDelay(NSInteger tries) { return 900.0 * (1 << MAX(0, MIN(tries, 10) - 1)); }

- (BOOL)willRetry:(NSString *)identifier {
    NSDictionary *r = _recs[identifier];
    return r[@"sub"] && [r[@"state"] integerValue] == SFDLFailed && [r[@"tries"] integerValue] < kSubMaxTries;
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

- (NSString *)storageSummary:(NSString *)source {
    return [NSString stringWithFormat:@"%@ belegt · %@ frei", gb([self bytesUsedFor:source]), gb([self freeBytes])];
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
    if (subID && r && st == SFDLDismissed) return NO;
    if (subID && r && st == SFDLFailed) {
        NSInteger n = [r[@"tries"] integerValue];
        if (n >= kSubMaxTries) return NO;
        if ([NSDate date].timeIntervalSince1970 - [r[@"failedAt"] doubleValue] < SFRetryDelay(n)) return NO;   // noch warten
    }
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
        [[SFStore shared] run:@"DELETE FROM downloads WHERE id=?" args:@[identifier]];
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
        r[@"state"] = @(SFDLFailed); r[@"error"] = @"Eintrag unlesbar"; r[@"tries"] = @(kSubMaxTries);
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
    SFDownloadURLDone got = ^(NSURL *url, NSURL *audio, NSError *e) {
        SFMain(^{
            if (![ident isEqualToString:self->_runningID]) return;
            if (!url) { [self finish:ident ok:NO error:e.localizedDescription ?: @"Kein Stream"]; return; }
            [self runFFmpeg:ff url:url audio:audio rec:r item:item];
        });
    };
    if (custom) custom(item, got); else [item resolveURL:^(NSURL *url, NSError *e) { got(url, nil, e); }];
}

- (void)runFFmpeg:(NSString *)ff url:(NSURL *)url audio:(NSURL *)audio rec:(NSMutableDictionary *)r item:(SFItem *)item {
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
                              @"-i", src.absoluteString] mutableCopy];
    if (audio) {   // eigene Tonspur (Originalton): Bild aus dem Stream, Ton aus der zweiten Quelle
        NSURL *asrc = [[SFStreamProxy shared] playableURLFor:audio];
        [args addObjectsFromArray:@[@"-readrate", @"3", @"-readrate_initial_burst", @"10", @"-i", asrc.absoluteString,
                                    @"-map", @"0:v:0", @"-map", @"1:a:0", @"-shortest"]];
        SFLog(@"downloads: %@ mit eigener Tonspur (Originalton)", item.title);
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
        if (!ok) { r[@"error"] = error ?: @"Fehler"; r[@"tries"] = @([r[@"tries"] integerValue] + 1); r[@"failedAt"] = @([NSDate date].timeIntervalSince1970); }
        [self save:r];
        SFLog(@"downloads: %@ %@%@", ok ? @"fertig" : @"FEHLER", ident, ok ? @"" : [@" – " stringByAppendingString:error ?: @""]);
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
