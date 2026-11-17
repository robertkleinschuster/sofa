// SFImageDiskLRU - which cached pictures were used last, counted by Sofa itself: the disk's access
// time is not kept (noatime on this iMac since 2026-11-17), so st_atime would only be the time a
// file was stored. Uses are noted in memory (cheap, any thread) and persisted only with a trim
// (once a day) in <dir>/.lru.plist; a file never noted counts by its modification time.
#import <Foundation/Foundation.h>

@interface SFImageDiskLRU : NSObject
- (instancetype)initWithDirectory:(NSString *)dir maxBytes:(long long)maxBytes;
- (void)noteUse:(NSString *)name;   // a file of the directory was read or written now (any thread)
// blocking (a background queue): beyond maxBytes, the least recently used files go; the uses are
// persisted. Returns how many were removed. `now` for tests (0 = the clock).
- (NSUInteger)trimAt:(NSTimeInterval)now;
@end
