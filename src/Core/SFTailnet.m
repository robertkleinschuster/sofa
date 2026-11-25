#import "SFTailnet.h"
#import "SFRuntime.h"
#import "SFJSON.h"
#include <netinet/in.h>
#include <sys/stat.h>

static const NSTimeInterval kStatusTimeout = 15;
static const NSTimeInterval kCertTimeout = 180;   // ACME through the coordination server

@implementation SFTailnet

+ (NSString *)cliPath {
    for (NSString *p in @[@"/opt/local/bin/tailscale", @"/usr/local/bin/tailscale",
                          @"/Applications/Tailscale.app/Contents/MacOS/Tailscale"])
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
    return nil;
}

+ (NSDictionary *)status {
    NSString *cli = [self cliPath];
    if (!cli) return nil;
    NSData *out = nil;
    if (SFRunProcess(cli, @[@"status", @"--json"], kStatusTimeout, NO, &out) != 0 || !out.length) return nil;
    NSDictionary *j = dict([NSJSONSerialization JSONObjectWithData:out options:0 error:nil]);
    if (![str(j[@"BackendState"]) isEqualToString:@"Running"]) return nil;
    NSDictionary *me = dict(j[@"Self"]);
    NSString *dns = str(me[@"DNSName"]);
    if ([dns hasSuffix:@"."]) dns = [dns substringToIndex:dns.length - 1];
    NSMutableDictionary *r = [NSMutableDictionary new];
    if (dns.length) r[@"dnsName"] = dns;
    NSString *cert = str(arr(j[@"CertDomains"]).firstObject);
    if (cert.length) r[@"certDomain"] = cert;
    r[@"ips"] = arr(me[@"TailscaleIPs"]) ?: @[];
    return r;
}

+ (BOOL)fetchCertificateFor:(NSString *)domain cert:(NSString *)certPath key:(NSString *)keyPath error:(NSString **)why {
    NSString *cli = [self cliPath];
    if (!cli || !domain.length) { if (why) *why = @"no tailscale CLI"; return NO; }
    // written next to the targets first: a failed or partial run never replaces a working pair
    NSString *tmpCert = [certPath stringByAppendingString:@".new"], *tmpKey = [keyPath stringByAppendingString:@".new"];
    NSData *out = nil;
    int rc = SFRunProcess(cli, @[@"cert", @"--cert-file", tmpCert, @"--key-file", tmpKey, domain], kCertTimeout, YES, &out);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (rc != 0 || ![fm fileExistsAtPath:tmpCert] || ![fm fileExistsAtPath:tmpKey]) {
        if (why) *why = [NSString stringWithFormat:@"tailscale cert exited %d: %@", rc,
                         [[[NSString alloc] initWithData:out ?: [NSData data] encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        [fm removeItemAtPath:tmpCert error:nil]; [fm removeItemAtPath:tmpKey error:nil];
        return NO;
    }
    chmod(tmpKey.fileSystemRepresentation, 0600);
    BOOL ok = rename(tmpKey.fileSystemRepresentation, keyPath.fileSystemRepresentation) == 0
           && rename(tmpCert.fileSystemRepresentation, certPath.fileSystemRepresentation) == 0;
    if (!ok && why) *why = [NSString stringWithFormat:@"could not move the certificate into place (%s)", strerror(errno)];
    return ok;
}
@end

BOOL SFIsTailnetAddress(const struct sockaddr *a) {
    if (!a) return NO;
    uint32_t v4 = 0;
    if (a->sa_family == AF_INET) v4 = ntohl(((const struct sockaddr_in *)a)->sin_addr.s_addr);
    else if (a->sa_family == AF_INET6) {
        const struct in6_addr *x = &((const struct sockaddr_in6 *)a)->sin6_addr;
        if (IN6_IS_ADDR_V4MAPPED(x)) memcpy(&v4, &x->s6_addr[12], 4), v4 = ntohl(v4);
        else {
            static const uint8_t prefix[6] = {0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0};   // fd7a:115c:a1e0::/48
            return memcmp(x->s6_addr, prefix, sizeof prefix) == 0;
        }
    } else return NO;
    return (v4 & 0xFFC00000u) == 0x64400000u;   // 100.64.0.0/10
}

BOOL SFIsLoopbackAddress(const struct sockaddr *a) {
    if (!a) return NO;
    if (a->sa_family == AF_INET) return (ntohl(((const struct sockaddr_in *)a)->sin_addr.s_addr) >> 24) == 127;
    if (a->sa_family != AF_INET6) return NO;
    const struct in6_addr *x = &((const struct sockaddr_in6 *)a)->sin6_addr;
    if (IN6_IS_ADDR_LOOPBACK(x)) return YES;
    return IN6_IS_ADDR_V4MAPPED(x) && x->s6_addr[12] == 127;
}
