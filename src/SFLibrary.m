#import "SFLibrary.h"
#import "SFDownloads.h"

NSString *const SFLibraryDidChangeNotification = @"SFLibraryDidChange";

@implementation SFShow @end

@implementation SFLibrary {
    NSArray *_shows;
    NSUInteger _gen;        // Stand des Gruppierungs-Caches
    NSUInteger _notified;   // zuletzt gemeldeter Stand (getrennt, sonst schluckt ein Rebuild die Meldung)
    BOOL _pending;
}

+ (instancetype)shared {
    static SFLibrary *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFLibrary new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _gen = NSNotFound;
        _notified = [SFDownloads shared].generation;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadsChanged) name:SFDownloadsDidChangeNotification object:nil];
    }
    return self;
}

- (BOOL)ready { return YES; }
- (void)whenReady:(dispatch_block_t)block { block(); }

// Fortschritts-Meldungen kommen alle 2 s: nur bei echten Zustandsänderungen neu gruppieren
- (void)downloadsChanged {
    if (_pending || [SFDownloads shared].generation == _notified) return;
    _pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_pending = NO;
        NSUInteger g = [SFDownloads shared].generation;
        if (g == self->_notified) return;
        self->_notified = g;
        self->_shows = nil;
        [[NSNotificationCenter defaultCenter] postNotificationName:SFLibraryDidChangeNotification object:self];
    });
}

- (NSArray *)shows {
    SFDownloads *dl = [SFDownloads shared];
    if (_shows && dl.generation == _gen) return _shows;
    _gen = dl.generation;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableDictionary *groups = [NSMutableDictionary new];   // "source\tchannel" -> SFShow
    NSMutableArray *order = [NSMutableArray new];
    NSMutableDictionary *eps = [NSMutableDictionary new];      // key -> NSMutableArray
    for (SFItem *e in [dl items:nil]) {   // neueste zuerst
        NSString *src = e.source.length ? e.source : @"youtube";
        NSString *ch = e.channel.length ? e.channel : SFUnsortedChannel;
        NSString *k = [NSString stringWithFormat:@"%@\t%@", src, ch];
        SFShow *s = groups[k];
        if (!s) {
            s = [SFShow new];
            s.name = ch; s.source = src;
            s.path = [dl folderForSource:src channel:e.channel];
            NSString *poster = [s.path stringByAppendingPathComponent:@"poster.jpg"], *fan = [s.path stringByAppendingPathComponent:@"fanart.jpg"];
            if ([fm fileExistsAtPath:poster]) s.poster = poster;
            if ([fm fileExistsAtPath:fan]) s.fanart = fan;
            eps[k] = [NSMutableArray new];
            groups[k] = s;
            [order addObject:s];
        }
        e.style = SFTileStyleLandscape;
        e.subtitle = SFFormatDateShort(e.date);
        [eps[k] addObject:e];
    }
    for (NSString *k in eps) {
        SFShow *s = groups[k];
        s.episodes = [eps[k] sortedArrayUsingComparator:^NSComparisonResult(SFItem *a, SFItem *b) {
            return [(b.date ?: [NSDate distantPast]) compare:(a.date ?: [NSDate distantPast])];
        }];
        SFItem *first = s.episodes.firstObject;
        s.latest = first.date;
        if (!s.poster) s.poster = first.image;
    }
    [order sortUsingComparator:^NSComparisonResult(SFShow *a, SFShow *b) {
        return [(b.latest ?: [NSDate distantPast]) compare:(a.latest ?: [NSDate distantPast])];
    }];
    _shows = order;
    return _shows;
}

- (NSArray *)showsForSource:(NSString *)source {
    NSArray *all = [self shows];
    if (!source) return all;
    return [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"source == %@", source]];
}

- (NSArray *)latestEpisodes:(NSInteger)n source:(NSString *)source {
    NSMutableArray *all = [NSMutableArray new];
    for (SFShow *s in [self showsForSource:source]) {
        NSUInteger k = MIN((NSUInteger)n, s.episodes.count);
        [all addObjectsFromArray:[s.episodes subarrayWithRange:NSMakeRange(0, k)]];
    }
    [all sortUsingComparator:^NSComparisonResult(SFItem *a, SFItem *b) { return [(b.date ?: [NSDate distantPast]) compare:(a.date ?: [NSDate distantPast])]; }];
    if ((NSInteger)all.count > n) [all removeObjectsInRange:NSMakeRange(n, all.count - n)];
    return all;
}

- (SFShow *)showNamed:(NSString *)name { return [self showNamed:name source:nil]; }
- (SFShow *)showNamed:(NSString *)name source:(NSString *)source {
    if (!name) return nil;
    for (SFShow *s in [self shows]) if ([s.name isEqualToString:name] && (!source.length || [s.source isEqualToString:source])) return s;
    return nil;
}

- (SFItem *)episodeForYouTubeID:(NSString *)vid {
    return vid.length ? [[SFDownloads shared] itemFor:[@"yt:" stringByAppendingString:vid]] : nil;
}
@end
