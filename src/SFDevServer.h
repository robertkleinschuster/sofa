// Dev-Viewer: kleiner HTTP-Server (nur Tailscale-IP + localhost) mit MJPEG-Livebild
// der Oberfläche und Fernsteuerung im Browser. Nur im Dev-Modus aktiv.
#import "SFScreen.h"

@interface SFDevServer : NSObject
- (instancetype)initWithNavigator:(SFNavigator *)nav port:(uint16_t)port;
- (void)start;
@property (nonatomic, copy) void (^keyHandler)(NSString *key);
@end
