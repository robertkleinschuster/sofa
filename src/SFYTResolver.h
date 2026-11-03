// YouTube-Stream-Auflösung über einen langlebigen yt-dlp-Prozess (res/ytresolver.py,
// eigenes venv in ~/Library/Application Support/Sofa/ytdlp). JSON-Zeilen über Pipes,
// Neustart bei Absturz, Ergebnis-Cache bis kurz vor Ablauf der URLs (6 h, IP-gebunden).
#import "SFCore.h"

@interface SFYTResolver : NSObject
+ (instancetype)shared;
+ (NSString *)cookieFile;      // Netscape-cookies.txt (0600), von SFYouTube geschrieben
- (void)start;                 // idempotent; wärmt den Player-JS-Cache vor
- (void)restart;               // z.B. nach Cookie-Erneuerung
// r: url, alt (Array), height, live, duration, title
- (void)resolve:(NSString *)videoID live:(BOOL)live done:(void (^)(NSDictionary *r, NSError *e))done;
@end
