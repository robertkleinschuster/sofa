// Who Sofa says it is (docs/architecture.md "Network identity"). Sofa is a native Mac app on OS X
// 10.9; its requests go out over the system's TLS (SecureTransport) or libcurl - a browser user
// agent would claim something the connection contradicts. So by default every request carries the
// user agent macOS gives every native app (CFNetwork's own, byte for byte - tests/units/useragent.m
// compares it with what NSURLSession sends): "Sofa/<build> CFNetwork/673.6 Darwin/13.4.0 (x86_64)
// (<model>)" - for every host. A source that must speak to its service as a browser does it from
// that browser (YouTube: its engine's Firefox); Sofa's own requests never borrow a browser's user
// agent: they once sent the engine's for youtube.com, ytimg.com, ... over SecureTransport/libcurl,
// a Firefox whose TLS handshake was not Firefox's - a classic bot signal (removed 2026-11-07).
#import <Foundation/Foundation.h>

NSString *SFNativeUserAgent(void);
