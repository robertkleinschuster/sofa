// Who Sofa says it is (docs/architecture.md "Network identity"). Sofa is a native Mac app on OS X
// 10.9; its requests go out over the system's TLS (SecureTransport) or libcurl - a browser user
// agent would claim something the connection contradicts. So by default every request carries the
// user agent macOS gives every native app (CFNetwork's own, byte for byte - tests/units/useragent.m
// compares it with what NSURLSession sends): "Sofa/<build> CFNetwork/673.6 Darwin/13.4.0 (x86_64)
// (<model>)". A source that speaks to its service as a browser registers that browser for its
// domains (YouTube: the sidecar's one Chrome identity for youtube.com, ytimg.com, ...).
#import <Foundation/Foundation.h>

NSString *SFNativeUserAgent(void);
// The user agent for a request to `host`: a registered one for its domain, else SFNativeUserAgent.
NSString *SFUserAgentForHost(NSString *host);
// `ua` for these domains and their subdomains (nil removes); any thread.
void SFSetUserAgentForDomains(NSString *ua, NSArray *domains);
