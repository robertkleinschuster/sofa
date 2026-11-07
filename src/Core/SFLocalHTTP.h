// A loopback HTTP/1.1 server for Sofa's local readers and helpers (mpv, ffmpeg, the YouTube
// engine's Firefox extension): 127.0.0.1 only, a free port, one request per connection
// (Connection: close - every reader here opens a connection per request anyway), or a WebSocket
// on it (SFWebSocket).
// A request is read on its connection's own queue; the handler runs on the server's queue and
// answers whenever it likes: at once, after a long poll, or as a stream of pieces with
// backpressure (each write reports when its bytes are on the wire, or that the reader is gone).
#import "SFCore.h"

@class SFWebSocket;

@interface SFHTTPRequest : NSObject
@property (nonatomic, readonly) NSString *method;                         // GET, HEAD, POST, ...
@property (nonatomic, readonly) NSArray *pathParts;           // decoded, empty parts dropped
@property (nonatomic, readonly) NSDictionary *query;   // decoded; a repeated key: the last
@property (nonatomic, readonly) NSData *body;                             // empty without one
- (NSString *)header:(NSString *)name;                                    // case-insensitive; nil when absent
@end

@interface SFHTTPExchange : NSObject
@property (nonatomic, readonly) SFHTTPRequest *request;
// The reader closed the connection before the answer was complete (a released long poll, a seek).
// Called once, on the server's queue; never after the answer is complete.
@property (nonatomic, copy) void (^onClose)(void);
@property (nonatomic, readonly) BOOL closed;
// A complete answer (HEAD: the headers only).
- (void)respond:(NSInteger)status type:(NSString *)type body:(NSData *)body;
- (void)respondJSON:(NSInteger)status object:(id)object;
// A WebSocket upgrade (GET, Upgrade: websocket, version 13, a key): answered 101 and the connection
// handed to the socket (messages up to `max` bytes). Not an upgrade: answered 400, nil.
- (SFWebSocket *)acceptWebSocket:(NSUInteger)max;
// A streamed answer: the head, pieces, then finish. done(NO): the reader is gone - stop producing.
- (void)begin:(NSInteger)status headers:(NSDictionary *)headers;
- (void)write:(NSData *)piece done:(void (^)(BOOL ok))done;
// Ends the answer. Before all promised bytes (Content-Length) were written the reader sees a short
// body - a premature end it reconnects after, as it should.
- (void)finish;
@end

typedef void (^SFHTTPHandler)(SFHTTPExchange *x);

@interface SFLocalHTTP : NSObject
// `queue` (serial) runs the handler and every callback; a request body above `maxBody` gets 413.
- (instancetype)initWithName:(NSString *)name queue:(dispatch_queue_t)queue maxBody:(NSUInteger)maxBody
                     handler:(SFHTTPHandler)handler;
// binds 127.0.0.1:<preferred>, or a free port when that one is taken (or 0); NO when it can't
- (BOOL)startPreferringPort:(uint16_t)preferred;
@property (nonatomic, readonly) uint16_t port;      // 0 until started
- (void)stop;                                       // no new connections; open ones run out
@end
