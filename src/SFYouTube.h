// YouTube: Browsing 100 % nativ über InnerTube (WEB-Client), Login über die Cookies des
// Firefox-Profils (SAPISIDHASH), Wiedergabe über SFYTResolver (yt-dlp, HLS 1080p).
// Referenz: docs/youtube.md. Lokale Downloads (~/TV Shows, genre YouTube) werden
// bevorzugt abgespielt, wenn dasselbe Video schon da ist.
#import "SFModel.h"

@interface SFYouTube : NSObject
+ (void)setup;                       // Resolver registrieren, Cookies laden, yt-dlp vorwärmen
+ (SFPageLoader)homeLoader;
+ (BOOL)loggedIn;
+ (SFPageLoader)channelLoader:(NSString *)channelID title:(NSString *)title;
+ (SFPageLoader)playlistLoader:(NSString *)playlistID title:(NSString *)title;
+ (SFPageLoader)searchLoader:(NSString *)query;
+ (SFItem *)itemForVideoID:(NSString *)vid;                     // Platzhalter (lokale Kopie, falls vorhanden)
+ (void)fillDetails:(SFItem *)item done:(dispatch_block_t)done; // Titel/Kanal/Dauer per InnerTube "player"
@end
