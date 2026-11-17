#import "SFFanLink.h"
#import "SFCore.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libkern/OSAtomic.h>

NSString *const SFFanContextPlayback = @"playback", *const SFFanContextIdle = @"idle", *const SFFanContextRest = @"ruhe";

static const NSUInteger kMaxDatagram = 4096;

static dispatch_queue_t gQ;          // every socket call
static int gFD = -1;                 // bound to Sofa's own path: the daemon answers there
static dispatch_source_t gRead;
static volatile int32_t gBusy;       // a hint still waiting on gQ: the next one is skipped

static NSString *FanDir(void) {
    NSString *dev = SFDevEnv(@"SOFA_FAND_DIR");
    if (dev.length) return dev;
    return SFDevMode ? nil : @"/var/run/sofa-fand";
}
// Sofa's own end: the real app in its caches, a dev instance/test next to the mock
static NSString *OwnPath(void) {
    NSString *dev = SFDevEnv(@"SOFA_FAND_DIR");
    return dev.length ? [dev stringByAppendingPathComponent:[NSString stringWithFormat:@"sofa-%d.sock", getpid()]]
                      : [SFSharedCacheDir() stringByAppendingPathComponent:@"fand.sock"];
}

static BOOL FillAddr(struct sockaddr_un *a, NSString *path) {
    memset(a, 0, sizeof *a);
    a->sun_family = AF_UNIX;
    const char *p = path.fileSystemRepresentation;
    if (!p || strlen(p) >= sizeof a->sun_path) return NO;
    strcpy(a->sun_path, p);
    return YES;
}

NSDictionary *SFFanParseState(NSData *json) {
    if (!json.length || json.length > kMaxDatagram) return nil;
    id j = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![j isKindOfClass:[NSDictionary class]]) return nil;
    id v = j[@"v"], level = j[@"level"];
    // numbers only: a JSON true is an NSNumber too ([@YES isEqual:@1]) - its objCType tells them apart
    if (![v isKindOfClass:[NSNumber class]] || strcmp([v objCType], @encode(char)) == 0 || [v integerValue] != 1) return nil;
    if (![level isKindOfClass:[NSNumber class]] || strcmp([level objCType], @encode(char)) == 0) return nil;
    NSMutableDictionary *s = [j mutableCopy];
    s[@"level"] = @(MAX(0, MIN(3, [level integerValue])));
    return s;
}

void SFFanStart(void (^state)(NSDictionary *)) {
    NSString *dir = FanDir();
    if (!dir || gQ) return;
    gQ = dispatch_queue_create("sofa.fand", DISPATCH_QUEUE_SERIAL);
    void (^cb)(NSDictionary *) = [state copy];
    dispatch_async(gQ, ^{
        int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
        if (fd < 0) return;
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        struct sockaddr_un a;
        NSString *own = OwnPath();
        if (!FillAddr(&a, own)) { close(fd); return; }
        unlink(a.sun_path);   // left by an earlier Sofa (crash, update)
        if (bind(fd, (struct sockaddr *)&a, (socklen_t)SUN_LEN(&a)) != 0) { SFLog(@"fand: cannot bind %@ (%s)", own, strerror(errno)); close(fd); return; }
        chmod(a.sun_path, 0622);   // the daemon (root) writes, nobody else needs to read
        gFD = fd;
        gRead = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, gQ);
        dispatch_source_set_event_handler(gRead, ^{
            uint8_t buf[kMaxDatagram + 1];
            ssize_t n;
            while ((n = recv(fd, buf, sizeof buf, 0)) > 0) {   // drain; a truncated (too long) one fails to parse
                NSDictionary *s = n <= (ssize_t)kMaxDatagram ? SFFanParseState([NSData dataWithBytes:buf length:(NSUInteger)n]) : nil;
                if (s) dispatch_async(dispatch_get_main_queue(), ^{ cb(s); });
            }
        });
        dispatch_resume(gRead);
    });
}

void SFFanSendHint(NSString *context, float volume, int ttl) {
    NSString *dir = FanDir();
    if (!dir || !context || !gQ) return;
    if (!OSAtomicCompareAndSwap32Barrier(0, 1, &gBusy)) return;   // the last one has not even gone out
    NSString *vol = volume >= 0 ? [NSString stringWithFormat:@"%.2f", MIN(1, volume)] : @"null";
    NSString *line = [NSString stringWithFormat:@"{\"v\":1,\"ctx\":\"%@\",\"vol\":%@,\"ttl\":%d,\"pid\":%d}\n", context, vol, ttl, getpid()];
    NSString *to = [dir stringByAppendingPathComponent:@"hint.sock"];
    dispatch_async(gQ, ^{
        struct sockaddr_un a;
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        // no daemon (ENOENT, ECONNREFUSED) or a full queue (EAGAIN/ENOBUFS): dropped, the next beat tries again
        if (gFD >= 0 && FillAddr(&a, to)) sendto(gFD, d.bytes, d.length, 0, (struct sockaddr *)&a, (socklen_t)SUN_LEN(&a));
        OSAtomicCompareAndSwap32Barrier(1, 0, &gBusy);
    });
}
