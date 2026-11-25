// An HTTP/1.1 server. Mostly loopback, for Sofa's local readers and helpers (mpv, the media proxy,
// the YouTube engine's Firefox extension): 127.0.0.1, a free port. One request per connection
// (Connection: close - every reader here opens a connection per request anyway), or a WebSocket
// on it (SFWebSocket). Sofa im Browser (docs/pwa.md) listens on every address with an accept filter
// (the tailnet's) and TLS through an SFHTTPSecurity; a connection that does not start with a TLS
// handshake is still read, as a plain request (`secure` NO), for the handler to refuse or redirect.
// A request is read on its connection's own queue; the handler runs on the server's queue and
// answers whenever it likes: at once, after a long poll, or as a stream of pieces with
// backpressure (each write reports when its bytes are on the wire, or that the reader is gone).
#import "SFCore.h"
#include <sys/socket.h>

@class SFWebSocket;

@interface SFHTTPRequest : NSObject
@property (nonatomic, readonly) NSString *method;                         // GET, HEAD, POST, ...
@property (nonatomic, readonly) NSArray *pathParts;           // decoded, empty parts dropped
@property (nonatomic, readonly) NSDictionary *query;   // decoded; a repeated key: the last
@property (nonatomic, readonly) NSData *body;                             // empty without one
@property (nonatomic, readonly) BOOL secure;                              // came over TLS (servers with security only)
- (NSString *)header:(NSString *)name;                                    // case-insensitive; nil when absent
@end

@interface SFHTTPExchange : NSObject
@property (nonatomic, readonly) SFHTTPRequest *request;
@property (nonatomic, readonly) dispatch_queue_t queue;   // the server's: every call on the exchange is made there
// The reader closed the connection before the answer was complete (a released long poll, a seek).
// Called once, on the server's queue; never after the answer is complete.
@property (nonatomic, copy) void (^onClose)(void);
@property (nonatomic, readonly) BOOL closed;
// Headers every answer of this exchange carries besides its own (CORS of Sofa im Browser). Set before answering.
@property (nonatomic, copy) NSDictionary *extraHeaders;
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

// TLS for a server (SFTLS): sessions are opaque pointers, used on one connection's queue only.
@protocol SFHTTPSecurity <NSObject>
- (void *)acceptOn:(int)fd;                                          // after the handshake; NULL = failed
- (ssize_t)read:(void *)session into:(void *)buf max:(size_t)n;      // like recv: > 0, 0 = closed, < 0 = error
- (ssize_t)write:(void *)session from:(const void *)buf length:(size_t)n;   // like send
- (void)end:(void *)session;                                         // close_notify (best effort) + free; the fd stays the server's
@end

// A single "bytes=" Range header against `total`: [start, end) and whether it was partial (206). No
// header or an unsupported form: all of it. NO when unsatisfiable (416).
BOOL SFHTTPParseRange(NSString *header, long long total, long long *start, long long *end, BOOL *partial);

@interface SFLocalHTTP : NSObject
// `queue` (serial) runs the handler and every callback; a request body above `maxBody` gets 413.
- (instancetype)initWithName:(NSString *)name queue:(dispatch_queue_t)queue maxBody:(NSUInteger)maxBody
                     handler:(SFHTTPHandler)handler;
// binds 127.0.0.1:<preferred>, or a free port when that one is taken (or 0); NO when it can't
- (BOOL)startPreferringPort:(uint16_t)preferred;
// Every address (IPv6 dual stack) on `port`, TLS through `security` (nil: plain). `accept` sees the
// address a connection came in on (the machine's own: which interface) and its peer; NO closes it
// at once. NO when the port can't be bound.
- (BOOL)startOnAllAddresses:(uint16_t)port security:(id<SFHTTPSecurity>)security
                     accept:(BOOL (^)(const struct sockaddr *local, const struct sockaddr *peer))accept;
@property (nonatomic, readonly) uint16_t port;      // 0 until started
- (void)stop;                                       // no new connections; open ones run out
@end
