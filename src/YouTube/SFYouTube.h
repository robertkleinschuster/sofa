// YouTube: Browsing 100 % nativ über InnerTube (WEB-Client), ohne Anmeldung; Wiedergabe über
// SFYTResolver (yt-dlp, HLS 1080p). Kanäle folgen = Sofas eigene Liste (SFFollows).
// Referenz: docs/youtube.md. Lokale Downloads (~/TV Shows, genre YouTube) werden
// bevorzugt abgespielt, wenn dasselbe Video schon da ist.
#import "SFModel.h"

@interface SFYouTube : NSObject
+ (void)setup;                       // Resolver registrieren, yt-dlp vorwärmen
+ (SFPageLoader)homeLoader;
+ (SFPageLoader)channelLoader:(NSString *)channelID title:(NSString *)title;
+ (SFPageLoader)playlistLoader:(NSString *)playlistID title:(NSString *)title;
+ (SFPageLoader)searchLoader:(NSString *)query;
// Autovervollständigung (suggestqueries-clients6.youtube.com, schlichtes GET); done auf Main, nie nil
+ (void)suggestions:(NSString *)prefix done:(void (^)(NSArray *list))done;
+ (SFItem *)itemForVideoID:(NSString *)vid;                     // Platzhalter (lokale Kopie, falls vorhanden)
+ (void)upNextFor:(NSString *)videoID done:(void (^)(SFItem *next))done;   // „Als Nächstes“ (Empfehlung, ohne Shorts/Live/Gesehenes)
// Related videos of the watch page (no Shorts < 90 s, not the video itself); done on main, never nil
+ (void)relatedFor:(NSString *)videoID done:(void (^)(NSArray *items))done;
// Watch page in one request (the same cached InnerTube "next" call as related/up next):
// related = as relatedFor; details = description, channel, channelID (UC…), avatar, date (NSDate) –
// keys only present when found. done on main; related empty + details nil = request failed.
+ (void)watchPageFor:(NSString *)videoID done:(void (^)(NSArray *related, NSDictionary *details))done;
+ (void)resolveChannelURL:(NSString *)url done:(void (^)(NSString *channelID))done;   // @handle-URL -> UC…
+ (void)fillDetails:(SFItem *)item done:(dispatch_block_t)done; // Titel/Kanal/Dauer per InnerTube "player"
@end
