// Lokale Bibliothek: ~/TV Shows (Sendung/tvshow.nfo + Season/*.mp4/.nfo/-thumb.jpg).
// Scan im Hintergrund mit mtime-Cache; meldet Änderungen per Notification.
#import "SFModel.h"

extern NSString *const SFLibraryDidChangeNotification;

@interface SFShow : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *source;    // youtube | zdf | ard | orf | ccc
@property (nonatomic, copy) NSString *poster;
@property (nonatomic, copy) NSString *fanart;
@property (nonatomic, copy) NSArray *episodes;   // SFItem, neueste zuerst
@property (nonatomic, strong) NSDate *latest;
@end

@interface SFLibrary : NSObject
+ (instancetype)shared;
@property (nonatomic, copy, readonly) NSString *root;
@property (nonatomic, readonly) BOOL ready;
- (void)scan;                                    // asynchron
- (void)whenReady:(dispatch_block_t)block;       // Main-Thread, nach erstem Scan
- (NSArray *)showsForSource:(NSString *)source;  // nil = alle; sortiert nach neuester Folge
- (NSArray *)latestEpisodes:(NSInteger)n source:(NSString *)source;
- (SFShow *)showNamed:(NSString *)name;
- (SFItem *)episodeForPath:(NSString *)path;
- (SFItem *)episodeForYouTubeID:(NSString *)vid;  // heruntergeladene Kopie eines YouTube-Videos
@end
