// Shared between SFYTEngine.m (lifecycle, API) and SFYTEngine+Media.m (local media routes).
#import "SFYTEngine.h"
#import "SFYTChannel.h"

@interface SFYTEngine ()
@property (nonatomic, readonly) dispatch_queue_t queue;   // the loopback server's: channel + media
@property (nonatomic, readonly) SFYTChannel *channel;
// One engine call with its Reply unwrapped, on the engine queue: done(value, nil), or (nil, error)
// with code = the status the engine answered (504: no answer) and userInfo = its failure body
// (error, bot, ...; "unanswered" when the page did not answer).
- (void)request:(NSString *)method args:(NSArray *)args timeout:(NSTimeInterval)timeout done:(void (^)(id value, NSError *e))done;
@end

@interface SFYTEngine (Media)
// GET|HEAD /s/<sid>/... (SFYTEngine+Media.m). Engine queue.
- (void)serveSession:(SFHTTPExchange *)x;
@end
