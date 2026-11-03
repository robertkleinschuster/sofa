// Bibliothek = Sicht auf die Offline-Schicht (SFDownloads), gruppiert nach Quelle + Sendung/Kanal.
// Kein eigener Speicher und kein Scan mehr (früher ~/TV Shows von ytdl-sub/Kodi).
#import "SFModel.h"

extern NSString *const SFLibraryDidChangeNotification;

@interface SFShow : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;      // Ordner im Sofa-Speicher
@property (nonatomic, copy) NSString *source;    // youtube | zdf | ard | orf | ccc
@property (nonatomic, copy) NSString *poster;
@property (nonatomic, copy) NSString *fanart;
@property (nonatomic, copy) NSArray *episodes;   // SFItem, neueste zuerst
@property (nonatomic, strong) NSDate *latest;
@end

@interface SFLibrary : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL ready;
- (void)whenReady:(dispatch_block_t)block;       // Main-Thread
- (NSArray *)showsForSource:(NSString *)source;  // nil = alle; sortiert nach neuester Folge
- (NSArray *)latestEpisodes:(NSInteger)n source:(NSString *)source;
- (SFShow *)showNamed:(NSString *)name;
- (SFItem *)episodeForYouTubeID:(NSString *)vid;  // heruntergeladene Kopie eines YouTube-Videos
@end
