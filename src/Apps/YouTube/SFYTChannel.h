// Sofa's end of the YouTube engine's channel (docs/youtube-engine.md "Channel"): the engine
// extension's background holds a WebSocket to /engine/ws with the channel's token (other local
// processes can't talk to the engine). Sofa sends commands [{id, method, args}] as text; the
// extension sends {answers: [{id, value} | {id, error}], events: [JSON strings]} as text, or as a
// binary message when values carry bytes (media, pictures: no base64). Mirrors
// tests/sofa-yt/enginehost.ts, which plays this role in the engine's own tests.
#import "SFLocalHTTP.h"

// Calls that got no answer (domain SFYTChannelErrorDomain): TimedOut = nothing within the call's
// timeout (slow, or a hung page); PageGone = the document that had it is gone (the engine fails
// its calls with failAll, or the connection a call went out on ended before its answer) - as opposed
// to an error the page answered.
extern NSString *const SFYTChannelErrorDomain;
enum { SFYTChannelTimedOut = 1, SFYTChannelPageGone = 2 };

// 128 random bits, hex.
NSString *SFYTChannelNewToken(void);
// A binary channel message -> its JSON with every {"$blob": n} replaced by the bytes (NSData); nil
// when malformed (tests/units/localhttp.m).
id SFYTChannelDecodeBinary(NSData *message);

@interface SFYTChannel : NSObject
// `queue` (serial, the HTTP server's) runs everything: requests, events, call completions.
// `token`: the one the extension sends (SFYTChannelNewToken() for a new profile); `max`: the largest
// message the extension may send.
- (instancetype)initWithQueue:(dispatch_queue_t)queue token:(NSString *)token maxMessage:(NSUInteger)max;
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
