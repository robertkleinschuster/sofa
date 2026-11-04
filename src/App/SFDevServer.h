// Dev viewer: small HTTP server (Tailscale IP + localhost only) with an MJPEG live view
// of the UI and remote control in the browser. Only active in dev mode.
#import "SFScreen.h"

@interface SFDevServer : NSObject
- (instancetype)initWithNavigator:(SFNavigator *)nav port:(uint16_t)port;
- (void)start;
@property (nonatomic, copy) void (^keyHandler)(NSString *key);
@end
