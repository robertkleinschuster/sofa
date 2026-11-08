#import "SFWebSocket.h"
#import "SFWebSocket+Server.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/socket.h>

NSString *SFWSAccept(NSString *key) {
    NSString *s = [key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, digest);
    return [[NSData dataWithBytes:digest length:sizeof digest] base64EncodedStringWithOptions:0];
}

NSData *SFWSFrame(SFWSOpcode op, NSData *payload) {
    NSUInteger n = payload.length;
    NSMutableData *f = [NSMutableData dataWithCapacity:n + 10];
    uint8_t h[10];
    size_t hl = 2;
    h[0] = 0x80 | (op & 0x0f);
    if (n < 126) h[1] = (uint8_t)n;
    else if (n <= 0xffff) { h[1] = 126; h[2] = (uint8_t)(n >> 8); h[3] = (uint8_t)n; hl = 4; }
    else { h[1] = 127; for (int i = 0; i < 8; i++) h[2 + i] = (uint8_t)((uint64_t)n >> (56 - 8 * i)); hl = 10; }
    [f appendBytes:h length:hl];
    if (n) [f appendData:payload];
    return f;
}

@implementation SFWSReader {
    NSUInteger _max;
    NSMutableData *_buf;        // bytes not yet a complete frame
    NSMutableData *_message;    // fragments of the message in progress (nil: none)
    SFWSOpcode _messageOp;
}

- (instancetype)initWithMaxMessage:(NSUInteger)max {
    if ((self = [super init])) { _max = max; _buf = [NSMutableData new]; }
    return self;
}

- (BOOL)feed:(NSData *)bytes message:(void (^)(SFWSOpcode, NSData *))message {
    [_buf appendData:bytes];
    NSUInteger used = 0;
    while (YES) {
        const uint8_t *p = (const uint8_t *)_buf.bytes + used;
        NSUInteger left = _buf.length - used;
        if (left < 2) break;
        BOOL fin = p[0] & 0x80, masked = p[1] & 0x80;
        SFWSOpcode op = p[0] & 0x0f;
        uint64_t len = p[1] & 0x7f;
        NSUInteger hl = 2;
        if (len == 126) { if (left < 4) break; len = ((uint64_t)p[2] << 8) | p[3]; hl = 4; }
        else if (len == 127) { if (left < 10) break; len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | p[2 + i]; hl = 10; }
        if (!masked || (p[0] & 0x70)) return NO;                       // clients mask; no extensions
        if (len > _max || len + _message.length > _max) return NO;
        BOOL control = op >= SFWSClose;
        if (control && (!fin || len > 125)) return NO;
        if (left < hl + 4 + len) break;
        const uint8_t *key = p + hl, *src = p + hl + 4;
        NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)len];
        uint8_t *dst = payload.mutableBytes;
        for (uint64_t i = 0; i < len; i++) dst[i] = src[i] ^ key[i & 3];
        used += hl + 4 + (NSUInteger)len;
        if (control) { message(op, payload); continue; }
        if (op == SFWSContinuation) {
            if (!_message) return NO;
            [_message appendData:payload];
        } else {
            if (_message || (op != SFWSText && op != SFWSBinary)) return NO;
            _message = payload;
            _messageOp = op;
        }
        if (fin) { NSData *m = _message; _message = nil; message(_messageOp, m); }
    }
    if (used) [_buf replaceBytesInRange:NSMakeRange(0, used) withBytes:NULL length:0];
    return YES;
}
@end

static BOOL WriteAll(int fd, NSData *d) {
    const uint8_t *p = d.bytes;
    size_t left = d.length;
    while (left) {
        ssize_t w = write(fd, p, left);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return NO;
        p += w; left -= (size_t)w;
    }
    return YES;
}

// State on the server's queue (`_queue`); the socket only on the connection's serial queue (`_io`).
@implementation SFWebSocket {
    int _fd;
    dispatch_queue_t _queue, _io;
    dispatch_source_t _read;
    SFWSReader *_reader;
    BOOL _ioDone;   // on _io: the fd is closed (or closing) - its number may already be another file's
}

- (instancetype)initWithFD:(int)fd queue:(dispatch_queue_t)queue io:(dispatch_queue_t)io maxMessage:(NSUInteger)max {
    if ((self = [super init])) {
        _fd = fd; _queue = queue; _io = io;
        _reader = [[SFWSReader alloc] initWithMaxMessage:max];
    }
    return self;
}

// On _io, after the 101 answer is written: frames are read from here on.
- (void)startReading {
    _read = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_fd, 0, _io);
    int fd = _fd;
    __weak SFWebSocket *ws = self;
    dispatch_source_set_event_handler(_read, ^{
        SFWebSocket *s = ws;
        uint8_t chunk[65536];
        ssize_t n = recv(fd, chunk, sizeof chunk, 0);
        if (n < 0 && errno == EINTR) return;
        if (!s) return;
        if (n <= 0) { [s ended]; return; }
        BOOL ok = [s->_reader feed:[NSData dataWithBytesNoCopy:chunk length:(NSUInteger)n freeWhenDone:NO] message:^(SFWSOpcode op, NSData *payload) {
            if (op == SFWSPing) { WriteAll(fd, SFWSFrame(SFWSPong, payload)); return; }
            if (op == SFWSPong) return;
            if (op == SFWSClose) { WriteAll(fd, SFWSFrame(SFWSClose, [NSData data])); [s ended]; return; }
            NSData *copy = [payload copy];
            dispatch_async(s->_queue, ^{ if (!s->_closed && s.onMessage) s.onMessage(op == SFWSBinary, copy); });
        }];
        if (!ok) { WriteAll(fd, SFWSFrame(SFWSClose, [NSData dataWithBytes:"\x03\xea" length:2])); [s ended]; }   // 1002 protocol error
    });
    dispatch_source_set_cancel_handler(_read, ^{ close(fd); });
    dispatch_resume(_read);
}

// On _io: the connection is over (once).
- (void)ended {
    if (_ioDone) return;
    _ioDone = YES;
    if (_read) dispatch_source_cancel(_read);   // closes the fd (none yet: the handover never happened)
    _read = nil;
    dispatch_async(_queue, ^{
        if (self->_closed) return;
        self->_closed = YES;
        void (^f)(void) = self.onClose;
        self.onClose = nil;
        self.onMessage = nil;
        if (f) f();
    });
}

- (void)send:(NSData *)frame {
    if (_closed) return;
    dispatch_async(_io, ^{ if (!self->_ioDone && !WriteAll(self->_fd, frame)) [self ended]; });
}

- (void)sendText:(NSString *)text { [self send:SFWSFrame(SFWSText, [text dataUsingEncoding:NSUTF8StringEncoding])]; }
- (void)sendBinary:(NSData *)data { [self send:SFWSFrame(SFWSBinary, data)]; }

- (void)close {
    if (_closed) return;
    dispatch_async(_io, ^{
        if (self->_ioDone) return;
        WriteAll(self->_fd, SFWSFrame(SFWSClose, [NSData dataWithBytes:"\x03\xe8" length:2]));   // 1000 normal
        shutdown(self->_fd, SHUT_RDWR);   // the read source sees the end
    });
}
@end
