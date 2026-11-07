#import "SFDevServer.h"
#import "SFFrameMeter.h"
#import <ImageIO/ImageIO.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <ifaddrs.h>

@interface SFDevClient : NSObject
@property (nonatomic) int fd;
@property (nonatomic) BOOL streaming;
@end
@implementation SFDevClient @end

@implementation SFDevServer {
    __weak SFNavigator *_nav;
    uint16_t _port;
    NSMutableArray *_listeners;    // dispatch_source_t
    NSMutableArray *_streams;      // SFDevClient
    dispatch_queue_t _io;
    NSTimer *_frameTimer;
    BOOL _encoding;
}

- (instancetype)initWithNavigator:(SFNavigator *)nav port:(uint16_t)port {
    if ((self = [super init])) {
        _nav = nav; _port = port;
        _listeners = [NSMutableArray new];
        _streams = [NSMutableArray new];
        _io = dispatch_queue_create("sofa.devserver", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

// Tailscale assigns addresses from 100.64.0.0/10.
static NSArray *bindAddresses(void) {
    NSMutableArray *a = [NSMutableArray arrayWithObject:@"127.0.0.1"];
    struct ifaddrs *ifs = NULL;
    if (getifaddrs(&ifs) == 0) {
        for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
            if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
            uint32_t ip = ntohl(((struct sockaddr_in *)i->ifa_addr)->sin_addr.s_addr);
            if ((ip & 0xFFC00000) == 0x64400000) {
                char buf[INET_ADDRSTRLEN];
                inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, buf, sizeof buf);
                [a addObject:@(buf)];
            }
        }
        freeifaddrs(ifs);
    }
    return a;
}

- (void)start {
    for (NSString *addr in bindAddresses()) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in sa = {0};
        sa.sin_len = sizeof sa; sa.sin_family = AF_INET; sa.sin_port = htons(_port);
        inet_pton(AF_INET, addr.UTF8String, &sa.sin_addr);
        if (bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0 || listen(fd, 8) != 0) {
            SFLog(@"devserver: bind %@:%d failed (%s)", addr, _port, strerror(errno));
            close(fd); continue;
        }
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _io);
        dispatch_source_set_event_handler(src, ^{
            int c = accept(fd, NULL, NULL);
            if (c >= 0) [self handleClient:c];
        });
        dispatch_resume(src);
        [_listeners addObject:src];
        SFLog(@"devserver: http://%@:%d/", addr, _port);
    }
}

static BOOL writeAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t w = write(fd, p, len);
        if (w <= 0) { if (errno == EINTR) continue; return NO; }
        p += w; len -= (size_t)w;
    }
    return YES;
}

- (void)respond:(int)fd type:(NSString *)type body:(NSData *)body {
    NSString *h = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
                   type, (unsigned long)body.length];
    NSData *hd = [h dataUsingEncoding:NSUTF8StringEncoding];
    writeAll(fd, hd.bytes, hd.length);
    writeAll(fd, body.bytes, body.length);
    close(fd);
}

- (void)handleClient:(int)fd {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    char buf[4096];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    if (n <= 0) { close(fd); return; }
    buf[n] = 0;
    NSString *req = @(buf) ?: @"";
    NSArray *first = [[req componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
    NSString *path = first.count > 1 ? first[1] : @"/";
    NSString *query = nil;
    NSRange q = [path rangeOfString:@"?"];
    if (q.location != NSNotFound) { query = [path substringFromIndex:q.location + 1]; path = [path substringToIndex:q.location]; }

    if ([path isEqualToString:@"/"]) {
        [self respond:fd type:@"text/html; charset=utf-8" body:[[self page] dataUsingEncoding:NSUTF8StringEncoding]];
    } else if ([path isEqualToString:@"/key"]) {
        NSString *k = [[query stringByReplacingOccurrencesOfString:@"k=" withString:@""] stringByRemovingPercentEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{ if (self.keyHandler && k) self.keyHandler(k); });
        [self respond:fd type:@"text/plain" body:[@"ok" dataUsingEncoding:NSUTF8StringEncoding]];
    } else if ([path isEqualToString:@"/framemeter"]) {   // frame meter on/off (SFFrameMeter): ?on=1 | ?on=0
        BOOL on = [query isEqualToString:@"on=1"];
        dispatch_async(dispatch_get_main_queue(), ^{ SFFrameMeterSetEnabled(on); });
        [self respond:fd type:@"text/plain" body:[@"ok" dataUsingEncoding:NSUTF8StringEncoding]];
    } else if ([path isEqualToString:@"/frame.jpg"]) {
        // asynchronous: main renders, writing in the background (no sync cross with _io)
        dispatch_async(dispatch_get_main_queue(), ^{
            CGImageRef img = [self renderFrame:1.0];
            SFBackground(^{
                NSData *jpg = [self jpeg:img quality:0.85];
                CGImageRelease(img);
                [self respond:fd type:@"image/jpeg" body:jpg ?: [NSData data]];
            });
        });
    } else if ([path isEqualToString:@"/stream"]) {
        NSString *h = @"HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=sofaframe\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
        if (!writeAll(fd, h.UTF8String, strlen(h.UTF8String))) { close(fd); return; }
        SFDevClient *c = [SFDevClient new]; c.fd = fd; c.streaming = YES;
        [_streams addObject:c];
        dispatch_async(dispatch_get_main_queue(), ^{ [self ensureTimer]; });
    } else {
        NSString *h = @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        writeAll(fd, h.UTF8String, strlen(h.UTF8String));
        close(fd);
    }
}

#pragma mark Frames

- (void)ensureTimer {
    if (_frameTimer) return;
    _frameTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 6 target:self selector:@selector(pushFrame) userInfo:nil repeats:YES];
}

- (CGImageRef)renderFrame:(CGFloat)scale CF_RETURNS_RETAINED {
    SFNavigator *nav = _nav;
    CALayer *root = nav.layer;
    CGSize sz = root.bounds.size;
    size_t w = (size_t)(sz.width * scale), h = (size_t)(sz.height * scale);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, scale, -scale);
    SFRenderLayerTree(root, ctx);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

- (NSData *)jpeg:(CGImageRef)img quality:(CGFloat)q {
    if (!img) return nil;
    NSMutableData *d = [NSMutableData new];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)d, CFSTR("public.jpeg"), 1, NULL);
    CGImageDestinationAddImage(dst, img, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @(q)});
    CGImageDestinationFinalize(dst);
    CFRelease(dst);
    return d;
}

- (void)pushFrame {
    __block NSUInteger n;
    dispatch_sync(_io, ^{ n = self->_streams.count; });
    if (!n) { [_frameTimer invalidate]; _frameTimer = nil; return; }
    if (_encoding) return;   // encoder behind: skip the frame
    _encoding = YES;
    CGImageRef img = [self renderFrame:2.0 / 3.0];   // 1280x720 at 1920x1080
    dispatch_async(_io, ^{
        NSData *jpg = [self jpeg:img quality:0.7];
        CGImageRelease(img);
        NSString *hdr = [NSString stringWithFormat:@"--sofaframe\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\n\r\n", (unsigned long)jpg.length];
        for (SFDevClient *c in [self->_streams copy]) {
            BOOL ok = writeAll(c.fd, hdr.UTF8String, strlen(hdr.UTF8String)) && writeAll(c.fd, jpg.bytes, jpg.length) && writeAll(c.fd, "\r\n", 2);
            if (!ok) { close(c.fd); [self->_streams removeObject:c]; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ self->_encoding = NO; });
    });
}

#pragma mark Page

- (NSString *)page {
    return @"<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<title>Sofa dev viewer</title><style>"
    "body{margin:0;background:#0b0c10;color:#ddd;font:15px -apple-system,Helvetica,Arial,sans-serif;display:flex;flex-direction:column;align-items:center;padding:16px}"
    "img{width:min(100%,1280px);aspect-ratio:16/9;background:#000;border-radius:8px;box-shadow:0 10px 40px #0008}"
    ".pad{display:grid;grid-template-columns:repeat(3,64px);gap:8px;margin:18px auto}"
    "button{height:52px;border:0;border-radius:12px;background:#22252d;color:#fff;font-size:20px;cursor:pointer}"
    "button:active{background:#3a3f4b}.row{display:flex;gap:10px;flex-wrap:wrap;justify-content:center}"
    ".row button{padding:0 18px;font-size:15px}p{color:#888;max-width:760px;text-align:center}h3{color:#777;font-weight:500;font-size:13px;margin:16px 0 0;text-transform:uppercase;letter-spacing:.08em}"
    "</style></head><body><img id=v src=/stream alt='Sofa'>"
    "<h3>Apple Remote (Aluminium, 2011)</h3>"
    "<div class=pad><span></span><button data-k=up>&#9650;</button><span></span>"
    "<button data-k=left>&#9664;</button><button data-k=select>&#9679;</button><button data-k=right>&#9654;</button>"
    "<span></span><button data-k=down>&#9660;</button><span></span></div>"
    "<div class=row><button data-k=menu>MENU</button><button data-k=play>&#9654;&#10074;&#10074;</button></div>"
    "<div class=row style='margin-top:10px'><button data-k=menuhold>MENU long</button><button data-k=selecthold>&#9679; long</button>"
    "<button data-k=prev>&#9664; long</button><button data-k=next>&#9654; long</button>"
    "<button data-k=uphold>&#9650; long</button><button data-k=downhold>&#9660; long</button></div>"
    "<p>Keyboard: arrows, Enter = centre, Esc = MENU, Space = play/pause; long: I = centre, H = MENU, ,/. = left/right.</p>"
    "<script>"
    "function k(x){fetch('/key?k='+x)}"
    "document.querySelectorAll('[data-k]').forEach(b=>b.onclick=()=>k(b.dataset.k));"
    "const m={ArrowUp:'up',ArrowDown:'down',ArrowLeft:'left',ArrowRight:'right',Enter:'select',Escape:'menu',Backspace:'menu',' ':'play',i:'selecthold',h:'menuhold',',':'prev','.':'next'};"
    "addEventListener('keydown',e=>{const x=m[e.key];if(x){e.preventDefault();k(x)}});"
    "const v=document.getElementById('v');v.onerror=()=>setTimeout(()=>v.src='/stream?'+Date.now(),1500);"
    "</script></body></html>";
}
@end
