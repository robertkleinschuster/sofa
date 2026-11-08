// Shared between SFYTEngine.m (lifecycle, API), SFYTEngine+Media.m (local media routes) and
// SFYTEngine+Lounge.m (the phone lounge's transport).
#import "SFYTEngine.h"
#import "SFYTChannel.h"

@interface SFYTEngine ()
@property (nonatomic, readonly) dispatch_queue_t queue;   // the loopback server's: channel + media
@property (nonatomic, readonly) SFYTChannel *channel;
// One engine call with its Reply unwrapped, on the engine queue: done(value, nil), or (nil, error)
// with code = the status the engine answered (504: no answer) and userInfo = its failure body
// (error, bot, ...; "unanswered" when the page did not answer).
- (void)request:(NSString *)method args:(NSArray *)args timeout:(NSTimeInterval)timeout done:(void (^)(id value, NSError *e))done;
// The page's engine answers calls - readable from any queue (mirrors the main-queue state).
@property (atomic) BOOL ready;
@end

@interface SFYTEngine (LoungeEvents)   // implemented in SFYTEngine+Lounge.m
- (void)loungeEvent:(NSDictionary *)e;   // a `lounge` event of the page (main queue)
- (void)endLoungePolls;                  // the page went away: every running poll ends (status 0)
@end

@interface SFYTEngine (Media)
// GET|HEAD /s/<sid>/... (SFYTEngine+Media.m). Engine queue.
- (void)serveSession:(SFHTTPExchange *)x;
// An opened session's tracks (local key -> id, total, mimeType): what the media store may serve
- (void)noteTracks:(NSDictionary *)tracks session:(NSString *)sid;
@end
