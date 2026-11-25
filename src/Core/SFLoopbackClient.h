// SFLoopbackClient - requests to Sofa's own loopback services (the media proxy, the YouTube engine's
// routes) as their other readers make them: one GET per connection, the answer to its end. Used by
// Sofa im Browser (docs/pwa.md) to relay a stream's local routes to the browser. Background queues.
#import "SFLocalHTTP.h"

@interface SFLoopbackResponse : NSObject
@property (nonatomic, readonly) NSInteger status;          // 0: no answer
@property (nonatomic, readonly, copy) NSDictionary *headers;   // lower-case names
@property (nonatomic, readonly, copy) NSData *body;
@end

@interface SFLoopbackClient : NSObject
// `url` must be http://127.0.0.1:<port>/... Blocking: the whole answer (playlists, header ranges).
+ (SFLoopbackResponse *)get:(NSURL *)url range:(NSString *)range timeout:(NSTimeInterval)timeout;
// The answer streamed into `x` as it arrives: the status, the media headers (type, length, range),
// the body with backpressure (the reader's pace); the reader going away ends the request. The
// request's method (GET/HEAD) and Range are passed on. No answer: 502.
+ (void)relay:(NSURL *)url to:(SFHTTPExchange *)x;
@end
