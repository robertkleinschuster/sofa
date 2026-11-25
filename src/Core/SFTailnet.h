// SFTailnet - what Sofa im Browser needs from Tailscale (docs/pwa.md): this machine's MagicDNS name -
// the one the tailnet issues its certificate for - and that certificate. Only the CLI's read-only
// `status --json` and `cert` are run: never anything that changes, stops or restarts the tunnel
// (on some machines Tailscale is the only way in). Blocking: background queues only.
#import "SFCore.h"
#include <sys/socket.h>

@interface SFTailnet : NSObject
+ (NSString *)cliPath;   // the tailscale CLI; nil = Tailscale is not installed
// The running node: @{certDomain (nil = HTTPS certificates are off for the tailnet), dnsName, ips};
// nil when Tailscale is missing, not running or not logged in.
+ (NSDictionary *)status;
// `tailscale cert` for `domain` into the two files (the key 0600). tailscaled answers with its
// cached certificate until it nears expiry; a new one takes a while (ACME, ~40 s measured).
+ (BOOL)fetchCertificateFor:(NSString *)domain cert:(NSString *)certPath key:(NSString *)keyPath error:(NSString **)why;
@end

// A tailnet address: 100.64.0.0/10 (also IPv4-mapped) or Tailscale's IPv6 range fd7a:115c:a1e0::/48.
BOOL SFIsTailnetAddress(const struct sockaddr *a);
BOOL SFIsLoopbackAddress(const struct sockaddr *a);
