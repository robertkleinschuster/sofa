// TLS-Brücke: Server, die nur moderne TLS-Chiffren sprechen (z.B. ORF: TLS 1.2 nur
// AES-GCM, TLS 1.3), sind mit SecureTransport von 10.9 nicht erreichbar. Für diese Hosts
// nutzt Sofa libcurl aus MacPorts (OpenSSL).
//  * SFCurlFetch: synchroner Abruf (nur im Hintergrund aufrufen)
//  * SFStreamProxy: lokaler HTTP-Proxy (127.0.0.1) für AVFoundation inkl. HLS-Umschreibung
#import "SFCore.h"

NSData *SFCurlFetch(NSString *url, NSString *method, NSDictionary *headers, NSData *body,
                    NSInteger *status, NSError **error);

// curl_easy_init() ohne TLS-Zertifikatsprüfung (siehe .m). Rückgabe ist ein CURL * (void *,
// damit dieser Header ohne curl.h auskommt).
void *SFCurlNew(void);

// Große Datei direkt auf Platte laden (Redirects folgen, HTTP-Fehler = Fehlschlag). Nur im Hintergrund.
BOOL SFCurlDownload(NSString *url, NSString *path, NSError **error);

// Hosts, die den curl-Weg brauchen (wird bei SSL-Fehlern automatisch gelernt).
BOOL SFHostNeedsCurl(NSString *host);
void SFMarkHostNeedsCurl(NSString *host);
BOOL SFIsTLSError(NSError *e);

@interface SFStreamProxy : NSObject
+ (instancetype)shared;
// Liefert für https-URLs eines curl-Hosts eine lokale Proxy-URL, sonst die URL selbst.
// YouTube-HLS-Playlists laufen ebenfalls über den Proxy (Segmente bleiben direkt), siehe .m.
- (NSURL *)playableURLFor:(NSURL *)url;
// YouTube-Playlist im Hintergrund vorladen (nach der Auflösung), damit der Start sofort lokal kommt.
- (void)warmPlaylist:(NSURL *)url;
@end
