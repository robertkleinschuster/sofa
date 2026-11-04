// TLS bridge: servers that only speak modern TLS ciphers (e.g. ORF: TLS 1.2 AES-GCM only,
// TLS 1.3) are unreachable with 10.9's SecureTransport. For these hosts
// Sofa uses libcurl from MacPorts (OpenSSL).
//  * SFCurlFetch: synchronous fetch (call in the background only)
//  * SFStreamProxy: local HTTP proxy (127.0.0.1) for AVFoundation incl. HLS rewriting
#import "SFCore.h"

NSData *SFCurlFetch(NSString *url, NSString *method, NSDictionary *headers, NSData *body,
                    NSInteger *status, NSError **error);

// curl_easy_init() without TLS certificate verification (see .m). Returns a CURL * (void *,
// so this header does without curl.h).
void *SFCurlNew(void);

// Download a large file straight to disk (follows redirects, HTTP error = failure). Background only.
BOOL SFCurlDownload(NSString *url, NSString *path, NSError **error);

// Hosts that need the curl path (learned automatically on SSL errors).
BOOL SFHostNeedsCurl(NSString *host);
void SFMarkHostNeedsCurl(NSString *host);
BOOL SFIsTLSError(NSError *e);

@interface SFStreamProxy : NSObject
+ (instancetype)shared;
// Returns a local proxy URL for https URLs of a curl host, otherwise the URL itself.
// YouTube HLS playlists also go through the proxy (segments stay direct), see .m.
- (NSURL *)playableURLFor:(NSURL *)url;
// Preload a YouTube playlist in the background (after resolving) so playback starts locally right away.
- (void)warmPlaylist:(NSURL *)url;
@end
