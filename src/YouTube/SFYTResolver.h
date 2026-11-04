// YouTube-Stream-Auflösung über einen langlebigen yt-dlp-Prozess (res/ytresolver.py, yt-dlp als
// signiert geprüftes Zipapp: Bundle bzw. ~/Library/Application Support/Sofa/yt-dlp). JSON-Zeilen über Pipes,
// Neustart bei Absturz, Ergebnis-Cache bis kurz vor Ablauf der URLs (6 h, IP-gebunden).
#import "SFCore.h"

@interface SFYTResolver : NSObject
+ (instancetype)shared;
- (void)saveCache;             // vor einem Update-Neustart: Ergebnisse für den neuen Prozess sichern
- (void)start;                 // idempotent; wärmt den Player-JS-Cache vor
- (void)restart;
// r: url, alt (Array), height, live, duration, title
- (void)resolve:(NSString *)videoID live:(BOOL)live done:(void (^)(NSDictionary *r, NSError *e))done;
// Hintergrund (Vorladen bei Fokus, Downloads): eigener Resolver-Pool, blockiert nie eine Wiedergabe
- (void)prefetch:(NSString *)videoID done:(void (^)(NSDictionary *r, NSError *e))done;
- (void)forget:(NSString *)videoID;   // Ergebnis verwerfen (Streams abgelehnt) -> nächster Aufruf löst frisch auf
@end
