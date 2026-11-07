// A WebSocket (RFC 6455) on a loopback HTTP connection: SFHTTPExchange acceptWebSocket: answers the
// upgrade and hands its connection over. Server side only - the client (the YouTube engine's
// extension) masks its frames, Sofa does not. One connection, both directions, text and binary
// messages: the engine channel's transport (docs/youtube-engine.md "Channel").
#import "SFCore.h"

typedef NS_ENUM(uint8_t, SFWSOpcode) { SFWSContinuation = 0, SFWSText = 1, SFWSBinary = 2, SFWSClose = 8, SFWSPing = 9, SFWSPong = 10 };

// Codec (pure; tests/units/websocket.m)
// The Sec-WebSocket-Accept value for a client's Sec-WebSocket-Key.
NSString *SFWSAccept(NSString *key);
// One complete server frame (FIN, not masked).
NSData *SFWSFrame(SFWSOpcode op, NSData *payload);

// Client frames in, messages out: fragments joined, control frames as they come, unmasked.
@interface SFWSReader : NSObject
- (instancetype)initWithMaxMessage:(NSUInteger)max;
// Feeds received bytes (any split); `message` per complete message or control frame. NO: a protocol
// error (an unmasked or oversized frame, a stray continuation, a fragmented control frame) - close.
- (BOOL)feed:(NSData *)bytes message:(void (^)(SFWSOpcode op, NSData *payload))message;
@end

@interface SFWebSocket : NSObject
// Both on the queue of the server that accepted it. onMessage: text (UTF-8) or binary payload.
@property (nonatomic, copy) void (^onMessage)(BOOL binary, NSData *payload);
@property (nonatomic, copy) void (^onClose)(void);   // once: the peer closed, the connection broke, or close
@property (nonatomic, readonly) BOOL closed;
- (void)sendText:(NSString *)text;
- (void)sendBinary:(NSData *)data;
- (void)close;
@end
