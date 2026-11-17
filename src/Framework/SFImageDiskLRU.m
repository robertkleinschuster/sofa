#import "SFImageDiskLRU.h"
#import "SFCore.h"
#include <sys/stat.h>

static NSString *const kStore = @".lru.plist";

@implementation SFImageDiskLRU {
    NSString *_dir;
    long long _max;
    NSMutableDictionary *_used;   // name -> epoch seconds (@synchronized)
    BOOL _loaded;
}

- (instancetype)initWithDirectory:(NSString *)dir maxBytes:(long long)maxBytes {
    if ((self = [super init])) { _dir = dir; _max = maxBytes; _used = [NSMutableDictionary new]; }
    return self;
}

- (void)noteUse:(NSString *)name {
    if (!name.length) return;
    @synchronized (self) { _used[name] = @([NSDate date].timeIntervalSince1970); }
}

- (NSUInteger)trimAt:(NSTimeInterval)now {
    NSString *store = [_dir stringByAppendingPathComponent:kStore];
    NSDictionary *used;
    @synchronized (self) {
        if (!_loaded) {   // once: what earlier runs noted, older than anything noted since
            _loaded = YES;
            NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:store];
            if ([old isKindOfClass:[NSDictionary class]])
                for (NSString *k in old) if (!_used[k] && [old[k] isKindOfClass:[NSNumber class]]) _used[k] = old[k];
        }
        used = [_used copy];
    }
    NSMutableArray *files = [NSMutableArray new];   // @[last use, size, name]
    long long total = 0;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_dir error:nil]) {
        if ([name isEqualToString:kStore]) continue;
        struct stat st;
        if (lstat([_dir stringByAppendingPathComponent:name].fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        total += st.st_size;
        double last = MAX([used[name] doubleValue], (double)st.st_mtimespec.tv_sec);
        [files addObject:@[@(last), @(st.st_size), name]];
    }
    NSUInteger removed = 0;
    long long before = total;
    if (total > _max) {
        [files sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
        for (NSArray *f in files) {
            if (total <= _max) break;
            if (unlink([_dir stringByAppendingPathComponent:f[2]].fileSystemRepresentation) == 0) {
                total -= [f[1] longLongValue]; removed++;
                @synchronized (self) { [_used removeObjectForKey:f[2]]; }
            }
        }
        SFLog(@"images: disk cache %.0f -> %.0f MB (%lu least recently used removed)", before / 1048576.0, total / 1048576.0, (unsigned long)removed);
    }
    // persist the uses of files that are still there (one small write a day)
    NSMutableDictionary *keep = [NSMutableDictionary new];
    @synchronized (self) { for (NSArray *f in files) if (_used[f[2]]) keep[f[2]] = _used[f[2]]; }
    [keep writeToFile:store atomically:YES];
    return removed;
}
@end
