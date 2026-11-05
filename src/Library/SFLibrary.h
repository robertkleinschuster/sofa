// Library = view of the offline layer (SFDownloads), grouped by source + show/channel.
// No own storage and no scan anymore (formerly ~/TV Shows from ytdl-sub/Kodi).
#import "SFModel.h"

extern NSString *const SFLibraryDidChangeNotification;

@interface SFShow : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;      // folder in Sofa's storage
@property (nonatomic, copy) NSString *source;    // youtube | zdf | ard | orf | ccc
@property (nonatomic, copy) NSString *poster;
@property (nonatomic, copy) NSString *fanart;
@property (nonatomic, copy) NSArray *episodes;   // SFItem, newest first
@property (nonatomic, strong) NSDate *latest;
@end

@interface SFLibrary : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL ready;
- (void)whenReady:(dispatch_block_t)block;       // main thread
- (NSArray *)showsForSource:(NSString *)source;  // nil = all; sorted by newest episode
- (NSArray *)latestEpisodes:(NSInteger)n source:(NSString *)source;    // newest publication first
- (NSArray *)recentDownloads:(NSInteger)n source:(NSString *)source;   // newest download first
- (SFShow *)showNamed:(NSString *)name;
- (SFShow *)showNamed:(NSString *)name source:(NSString *)source;   // source nil = any
// source of downloads without a source tag (pre-Sofa library); set by the shell
@property (nonatomic, copy) NSString *untaggedSource;
@end
