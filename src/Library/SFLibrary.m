#import "SFLibrary.h"
#import "SFDownloads.h"

NSString *const SFLibraryDidChangeNotification = @"SFLibraryDidChange";

@implementation SFShow @end

@implementation SFLibrary {
    NSArray *_shows;
    NSArray *_recent;   // all downloaded episodes, newest download first
    NSUInteger _gen;        // state of the grouping cache
    NSUInteger _notified;   // last notified state (separate, otherwise a rebuild swallows the notification)
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

// progress notifications arrive every 2 s: regroup only on real state changes
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
    NSMutableArray *recent = [NSMutableArray new];
    for (SFItem *e in [dl items:nil]) {   // newest first
        NSString *src = e.source.length ? e.source : (self.untaggedSource ?: @"");
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
        [recent addObject:e];
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
    NSMutableDictionary *added = [NSMutableDictionary new];
    for (SFItem *e in recent) added[e.identifier] = @([dl recordFor:e.identifier].added);
    [recent sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(SFItem *a, SFItem *b) {
        return [added[b.identifier] compare:added[a.identifier]];
    }];
    _shows = order;
    _recent = recent;
    return _shows;
}

- (NSArray *)showsForSource:(NSString *)source {
    NSArray *all = [self shows];
    if (!source) return all;
    return [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"source == %@", source]];
}

- (NSArray *)recentDownloads:(NSInteger)n source:(NSString *)source {
    [self shows];
    NSMutableArray *r = [NSMutableArray new];
    for (SFItem *e in _recent) {
        if ((NSInteger)r.count >= n) break;
        if (!source.length || [(e.source.length ? e.source : (self.untaggedSource ?: @"")) isEqualToString:source]) [r addObject:e];
    }
    return r;
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

@end
