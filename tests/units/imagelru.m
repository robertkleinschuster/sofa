// sources: src/Framework/SFImageDiskLRU.m
// SFImageDiskLRU: the picture cache's least recently used, counted by Sofa (no atime on this Mac):
// a noted use beats an older file, unnoted files count by their mtime, the uses survive a restart.
#import "../../src/Framework/SFImageDiskLRU.h"
#import "SFCore.h"
#include <sys/time.h>
BOOL SFDevMode = NO;

static int fails;
static void expect(BOOL ok, NSString *what) { if (!ok) { fails++; printf("FAIL %s\n", what.UTF8String); } }
static NSString *dir;
static void file(NSString *name, NSUInteger kb, NSTimeInterval mtime) {
    NSString *p = [dir stringByAppendingPathComponent:name];
    [[NSMutableData dataWithLength:kb * 1024] writeToFile:p atomically:NO];
    struct timeval tv[2] = {{(time_t)mtime, 0}, {(time_t)mtime, 0}};
    utimes(p.fileSystemRepresentation, tv);
}
static BOOL has(NSString *name) { return [[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:name]]; }

int main(void) {
    @autoreleasepool {
        dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"imglru-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        file(@"old-but-used", 100, now - 30 * 86400);
        file(@"old", 100, now - 20 * 86400);
        file(@"middle", 100, now - 10 * 86400);
        file(@"new", 100, now - 3600);
        SFImageDiskLRU *l = [[SFImageDiskLRU alloc] initWithDirectory:dir maxBytes:250 * 1024];
        [l noteUse:@"old-but-used"];
        expect([l trimAt:0] == 2, @"two over the limit removed");
        expect(has(@"old-but-used") && has(@"new") && !has(@"old") && !has(@"middle"), @"the used one stays, the oldest unused go");
        expect(has(@".lru.plist"), @"the uses persisted with the trim");
        // a new instance (Sofa restarted): the persisted use still counts
        file(@"fresh", 100, now - 60);
        SFImageDiskLRU *l2 = [[SFImageDiskLRU alloc] initWithDirectory:dir maxBytes:250 * 1024];
        expect([l2 trimAt:0] == 1 && has(@"old-but-used") && has(@"fresh") && !has(@"new"),
               @"after a restart: the use noted before still beats an hour-old file");
        expect([l2 trimAt:0] == 0, @"under the limit: nothing removed");
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    if (!fails) printf("imagelru ok\n");
    return fails ? 1 : 0;
}
