// Sofa's end of the YouTube engine's channel (docs/youtube-engine.md "Channel"): the engine
// extension's background long-polls GET /engine/poll for commands and POSTs answers and events to
// /engine/post, both with the channel's token (other local processes can't talk to the engine).
// Commands are {id, method, args}; answers {id, value} or {id, error}; events are JSON strings
// ({type: ready|log|block, ...}). Mirrors tests/sofa-yt/enginehost.ts, which plays this role in
// the engine's own tests.
#import "SFLocalHTTP.h"

// Calls that got no answer (domain SFYTChannelErrorDomain): TimedOut = nothing within the call's
// timeout (slow, or a hung page); PageGone = the document that had it is gone (the engine fails
// its calls with failAll) - as opposed to an error the page answered.
extern NSString *const SFYTChannelErrorDomain;
enum { SFYTChannelTimedOut = 1, SFYTChannelPageGone = 2 };

@interface SFYTChannel : NSObject
// `queue` (serial, the HTTP server's) runs everything: requests, events, call completions.
- (instancetype)initWithQueue:(dispatch_queue_t)queue;
@property (nonatomic, readonly) NSString *token;
@property (nonatomic, copy) void (^onEvent)(NSDictionary *event);
// YES when the exchange was a channel request (answered or held); NO: not the channel's path.
- (BOOL)handle:(SFHTTPExchange *)x;
// One engine call: done(value, nil) with the engine's answer, or (nil, error) - the page answered
// an error, or nothing came within `timeout` (SFYTChannelTimedOut: the call is slow, or the page
// is gone or hangs).
- (void)call:(NSString *)method args:(NSArray *)args timeout:(NSTimeInterval)timeout done:(void (^)(id value, NSError *e))done;
// Every pending call fails with `error`; queued commands are dropped (the page they were for is gone).
- (void)failAll:(NSError *)error;
@end
