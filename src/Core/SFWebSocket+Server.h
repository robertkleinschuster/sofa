// SFLocalHTTP's side of SFWebSocket: an accepted upgrade hands its connection over.
#import "SFWebSocket.h"

@interface SFWebSocket (Server)
// `fd` is the socket's from now on (it closes it); `io` the connection's serial queue, `queue` the server's.
- (instancetype)initWithFD:(int)fd queue:(dispatch_queue_t)queue io:(dispatch_queue_t)io maxMessage:(NSUInteger)max;
- (void)startReading;   // on `io`, once the 101 answer is written
@end
