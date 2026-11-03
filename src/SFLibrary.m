#import "SFLibrary.h"
#import <CoreServices/CoreServices.h>

NSString *const SFLibraryDidChangeNotification = @"SFLibraryDidChange";

@implementation SFShow @end

@implementation SFLibrary {
    NSArray *_shows;
    NSDictionary *_byPath;
    NSDictionary *_byYT;     // YouTube-Video-ID -> lokale Folge
    NSMutableArray *_waiters;
    dispatch_queue_t _q;
    BOOL _scanning, _rescan;
    NSMutableDictionary *_nfoCache;   // path -> @{mtime, dict}
    FSEventStreamRef _fsevents;
    NSTimer *_debounce;
}

+ (instancetype)shared {
    static SFLibrary *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFLibrary new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _root = [NSHomeDirectory() stringByAppendingPathComponent:@"TV Shows"];
        _waiters = [NSMutableArray new];
        _q = dispatch_queue_create("sofa.library", DISPATCH_QUEUE_SERIAL);
        _shows = @[];
        NSData *d = [NSData dataWithContentsOfFile:[self cachePath]];
        id c = d ? [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainers format:NULL error:nil] : nil;
        _nfoCache = [c isKindOfClass:[NSMutableDictionary class]] ? c : [NSMutableDictionary new];
        [self loadIndex];
        [self watch];
        dispatch_async(dispatch_get_main_queue(), ^{ [self scan]; });   // Index ist nur Vorschau
    }
    return self;
}

- (NSString *)indexPath { return [SFCacheDir() stringByAppendingPathComponent:@"library-index.plist"]; }

// Letzten Scan sofort verfügbar machen; der Hintergrund-Scan aktualisiert danach.
- (void)loadIndex {
    NSData *d = [NSData dataWithContentsOfFile:[self indexPath]];
    NSArray *arr = d ? [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:nil] : nil;
    if (![arr isKindOfClass:[NSArray class]]) return;
    NSMutableArray *shows = [NSMutableArray new];
    NSMutableDictionary *byPath = [NSMutableDictionary new];
    NSMutableDictionary *byYT = [NSMutableDictionary new];
    for (NSDictionary *sd in arr) {
        SFShow *s = [SFShow new];
        s.name = sd[@"name"]; s.path = sd[@"path"]; s.source = sd[@"source"];
        s.poster = sd[@"poster"]; s.fanart = sd[@"fanart"];
        NSMutableArray *eps = [NSMutableArray new];
        for (NSDictionary *ed in sd[@"eps"]) {
            SFItem *e = [SFItem itemWithDictionary:ed];
            e.style = SFTileStyleLandscape;
            e.subtitle = SFFormatDateShort(e.date);
            [eps addObject:e];
            if (e.localPath) byPath[e.localPath.precomposedStringWithCanonicalMapping] = e;
            if (e.externalID) byYT[e.externalID] = e;
        }
        if (!eps.count) continue;
        s.episodes = eps;
        s.latest = ((SFItem *)eps.firstObject).date;
        [shows addObject:s];
    }
    _shows = shows;
    _byPath = byPath;
    _byYT = byYT;
    _ready = YES;
    SFLog(@"library: index loaded (%lu shows)", (unsigned long)shows.count);
}

- (void)saveIndex:(NSArray *)shows {
    NSMutableArray *arr = [NSMutableArray new];
    for (SFShow *s in shows) {
        NSMutableArray *eps = [NSMutableArray new];
        for (SFItem *e in s.episodes) [eps addObject:[e dictionaryRepresentation]];
        NSMutableDictionary *sd = [@{@"name": s.name, @"path": s.path, @"source": s.source, @"eps": eps} mutableCopy];
        if (s.poster) sd[@"poster"] = s.poster;
        if (s.fanart) sd[@"fanart"] = s.fanart;
        [arr addObject:sd];
    }
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:arr format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [d writeToFile:[self indexPath] atomically:YES];
}

- (NSString *)cachePath { return [SFCacheDir() stringByAppendingPathComponent:@"library-nfo.plist"]; }

#pragma mark FSEvents

static void fsCallback(ConstFSEventStreamRef s, void *info, size_t n, void *paths, const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
    SFLibrary *lib = (__bridge SFLibrary *)info;
    dispatch_async(dispatch_get_main_queue(), ^{ [lib scheduleRescan]; });
}

- (void)watch {
    FSEventStreamContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
    _fsevents = FSEventStreamCreate(NULL, fsCallback, &ctx, (__bridge CFArrayRef)@[_root],
                                    kFSEventStreamEventIdSinceNow, 5.0, kFSEventStreamCreateFlagNone);
    if (!_fsevents) return;
    FSEventStreamScheduleWithRunLoop(_fsevents, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    FSEventStreamStart(_fsevents);
}

- (void)scheduleRescan {
    [_debounce invalidate];
    _debounce = [NSTimer scheduledTimerWithTimeInterval:8 target:self selector:@selector(scan) userInfo:nil repeats:NO];
}

#pragma mark Scan

- (void)whenReady:(dispatch_block_t)block {
    if (_ready) { block(); return; }
    [_waiters addObject:[block copy]];
    [self scan];
}

- (void)scan {
    if (_scanning) { _rescan = YES; return; }
    _scanning = YES;
    dispatch_async(_q, ^{
        NSDate *t0 = [NSDate date];
        NSArray *shows = [self scanAll];
        NSMutableDictionary *byPath = [NSMutableDictionary new];
        NSUInteger eps = 0;
        NSMutableDictionary *byYT = [NSMutableDictionary new];
        for (SFShow *s in shows) for (SFItem *e in s.episodes) { byPath[e.localPath.precomposedStringWithCanonicalMapping] = e; if (e.externalID) byYT[e.externalID] = e; eps++; }
        NSData *d = [NSPropertyListSerialization dataWithPropertyList:self->_nfoCache format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        [d writeToFile:[self cachePath] atomically:YES];
        [self saveIndex:shows];
        SFLog(@"library: %lu shows, %lu episodes in %.2fs", (unsigned long)shows.count, (unsigned long)eps, -[t0 timeIntervalSinceNow]);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_shows = shows;
            self->_byPath = byPath;
            self->_byYT = byYT;
            self->_ready = YES;
            self->_scanning = NO;
            NSArray *w = [self->_waiters copy];
            [self->_waiters removeAllObjects];
            for (dispatch_block_t b in w) b();
            [[NSNotificationCenter defaultCenter] postNotificationName:SFLibraryDidChangeNotification object:self];
            if (self->_rescan) { self->_rescan = NO; [self scan]; }
        });
    });
}

static NSString *sourceForGenre(NSString *g) {
    NSString *l = g.lowercaseString;
    if ([l isEqualToString:@"zdf"]) return @"zdf";
    if ([l isEqualToString:@"ard"]) return @"ard";
    if ([l isEqualToString:@"orf"]) return @"orf";
    if ([l isEqualToString:@"ccc"]) return @"ccc";
    return @"youtube";
}

- (NSDictionary *)nfo:(NSString *)path {
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!a) return nil;
    NSNumber *mt = @([a.fileModificationDate timeIntervalSince1970]);
    NSDictionary *c = _nfoCache[path];
    if (c && [c[@"m"] isEqual:mt]) return c[@"d"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
    NSMutableDictionary *d = [NSMutableDictionary new];
    for (NSXMLNode *n in doc.rootElement.children) {
        if (n.kind != NSXMLElementKind || !n.name) continue;
        if (!d[n.name]) d[n.name] = n.stringValue ?: @"";
    }
    _nfoCache[path] = @{@"m": mt, @"d": d};
    return d;
}

- (NSArray *)scanAll {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *shows = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd"; df.timeZone = [NSTimeZone localTimeZone]; }
    for (NSString *name in [fm contentsOfDirectoryAtPath:_root error:nil]) {
        if ([name hasPrefix:@"."]) continue;
        NSString *sp = [_root stringByAppendingPathComponent:name];
        BOOL dir = NO;
        if (![fm fileExistsAtPath:sp isDirectory:&dir] || !dir) continue;
        NSDictionary *tv = [self nfo:[sp stringByAppendingPathComponent:@"tvshow.nfo"]];
        SFShow *show = [SFShow new];
        show.name = tv[@"title"] ?: name;
        show.path = sp;
        show.source = sourceForGenre(tv[@"genre"] ?: @"");
        NSString *poster = [sp stringByAppendingPathComponent:@"poster.jpg"];
        NSString *fan = [sp stringByAppendingPathComponent:@"fanart.jpg"];
        if ([fm fileExistsAtPath:poster]) show.poster = poster;
        if ([fm fileExistsAtPath:fan]) show.fanart = fan;
        NSMutableArray *eps = [NSMutableArray new];
        for (NSString *season in [fm contentsOfDirectoryAtPath:sp error:nil]) {
            NSString *sdir = [sp stringByAppendingPathComponent:season];
            if (![fm fileExistsAtPath:sdir isDirectory:&dir] || !dir) continue;
            for (NSString *f in [fm contentsOfDirectoryAtPath:sdir error:nil]) {
                NSString *ext = f.pathExtension.lowercaseString;
                if (!([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"m4v"] || [ext isEqualToString:@"mkv"] || [ext isEqualToString:@"mov"])) continue;
                if ([f hasPrefix:@"."]) continue;
                NSString *vp = [sdir stringByAppendingPathComponent:f];
                NSString *base = [vp stringByDeletingPathExtension];
                NSDictionary *n = [self nfo:[base stringByAppendingPathExtension:@"nfo"]];
                SFItem *e = [SFItem new];
                e.kind = SFItemVideo;
                e.localPath = vp;
                e.playURL = [NSURL fileURLWithPath:vp];
                e.identifier = [@"local:" stringByAppendingString:[vp substringFromIndex:self->_root.length + 1]];
                NSString *t = n[@"title"];
                if (!t.length) {
                    t = f.stringByDeletingPathExtension;
                    NSRange dash = [t rangeOfString:@" - "];
                    if (dash.location != NSNotFound && dash.location < 20) t = [t substringFromIndex:NSMaxRange(dash)];
                }
                e.title = t;
                e.channel = show.name;
                e.source = show.source;
                NSString *plot = n[@"plot"];
                // YouTube-NFOs beginnen mit der Video-URL — für die Anzeige entfernen
                if ([plot hasPrefix:@"http"]) {
                    NSRange v = [plot rangeOfString:@"watch?v="];
                    if (v.location != NSNotFound && v.location < 40 && plot.length >= NSMaxRange(v) + 11) e.externalID = [plot substringWithRange:NSMakeRange(NSMaxRange(v), 11)];
                    NSRange nl = [plot rangeOfString:@"\n"];
                    if (nl.location != NSNotFound) {
                        plot = [[plot substringFromIndex:nl.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    }
                }
                e.plot = plot;
                NSString *aired = n[@"aired"] ?: n[@"premiered"];
                e.date = aired.length >= 10 ? [df dateFromString:[aired substringToIndex:10]] : nil;
                if (!e.date) {
                    NSDictionary *fa = [fm attributesOfItemAtPath:vp error:nil];
                    e.date = fa.fileModificationDate;
                }
                e.duration = [n[@"runtime"] doubleValue] * 60;
                NSString *thumb = [base stringByAppendingString:@"-thumb.jpg"];
                if ([fm fileExistsAtPath:thumb]) e.image = thumb;
                else if ([fm fileExistsAtPath:[base stringByAppendingPathExtension:@"jpg"]]) e.image = [base stringByAppendingPathExtension:@"jpg"];
                e.backdrop = e.image;   // Vorschaubild; YouTube-Banner (fanart) taugen nicht als Hintergrund
                e.style = SFTileStyleLandscape;
                [eps addObject:e];
            }
        }
        [eps sortUsingComparator:^NSComparisonResult(SFItem *a, SFItem *b) {
            NSComparisonResult r = [b.date compare:a.date];
            return r != NSOrderedSame ? r : [b.localPath compare:a.localPath];
        }];
        if (!eps.count) continue;
        for (SFItem *e in eps) e.subtitle = SFFormatDateShort(e.date);
        show.episodes = eps;
        show.latest = ((SFItem *)eps.firstObject).date;
        if (!show.poster) show.poster = ((SFItem *)eps.firstObject).image;
        [shows addObject:show];
        [seen addObject:sp];
    }
    // Cache-Einträge verwaister Dateien entfernen
    for (NSString *k in _nfoCache.allKeys) if (![fm fileExistsAtPath:k]) [_nfoCache removeObjectForKey:k];
    [shows sortUsingComparator:^NSComparisonResult(SFShow *a, SFShow *b) { return [b.latest compare:a.latest]; }];
    return shows;
}

#pragma mark Queries

- (NSArray *)showsForSource:(NSString *)source {
    if (!source) return _shows;
    return [_shows filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"source == %@", source]];
}

- (NSArray *)latestEpisodes:(NSInteger)n source:(NSString *)source {
    NSMutableArray *all = [NSMutableArray new];
    for (SFShow *s in [self showsForSource:source]) {
        NSUInteger k = MIN((NSUInteger)n, s.episodes.count);
        [all addObjectsFromArray:[s.episodes subarrayWithRange:NSMakeRange(0, k)]];
    }
    [all sortUsingComparator:^NSComparisonResult(SFItem *a, SFItem *b) { return [b.date compare:a.date]; }];
    if ((NSInteger)all.count > n) [all removeObjectsInRange:NSMakeRange(n, all.count - n)];
    return all;
}

- (SFShow *)showNamed:(NSString *)name {
    for (SFShow *s in _shows) if ([s.name isEqualToString:name]) return s;
    return nil;
}
- (SFItem *)episodeForPath:(NSString *)path { return _byPath[path.precomposedStringWithCanonicalMapping]; }
- (SFItem *)episodeForYouTubeID:(NSString *)vid { return vid ? _byYT[vid] : nil; }
@end
