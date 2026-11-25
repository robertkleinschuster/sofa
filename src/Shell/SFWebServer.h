// SFWebServer - Sofa im Browser (docs/pwa.md): the HTTPS API and media routes the PWA (GitHub Pages)
// talks to over the tailnet. TLS with the tailnet's certificate for this machine's MagicDNS name
// (SFTailnet, SFTLS), only on tailnet addresses; plain HTTP on the same port answers only the
// connect redirect that teaches the PWA the full name. Every route but `hello`, `pair` and the
// capability routes (/m/<stream>, signed /img) needs a paired device's token (SFWebDevices).
#import "SFCore.h"

extern NSString *const SFWebServerStatusDidChangeNotification;   // address/problem changed (main thread)

@interface SFWebServer : NSObject
+ (instancetype)shared;
// Main thread, once at launch: the real app always; a dev instance only with SOFA_WEB_PORT
// (SOFA_WEB_CERT + SOFA_WEB_KEY: its own certificate, SOFA_WEB_LOOPBACK=1: also on 127.0.0.1,
// SOFA_WEB_ORIGINS: allowed browser origins, comma separated).
- (void)start;
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly, copy) NSString *shortName;   // what to type ("imac"); nil until known
@property (nonatomic, readonly, copy) NSString *fullName;    // the certificate's name
@property (nonatomic, readonly, copy) NSString *problem;     // why it can't be reached (German, for the TV); nil = fine
+ (NSString *)appURL;                                        // where the PWA lives
@end
