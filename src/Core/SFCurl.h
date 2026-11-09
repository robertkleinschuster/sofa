// TLS bridge: servers that only speak modern TLS ciphers (e.g. ORF: TLS 1.2 AES-GCM only,
// TLS 1.3) are unreachable with 10.9's SecureTransport. For these hosts
// Sofa uses libcurl from MacPorts (OpenSSL).
//  * SFCurlFetch: synchronous fetch (call in the background only)
//  * SFCurlStream: a streamed range GET (the media proxy's source reads, SFMediaProxy)
#import "SFCore.h"

NSData *SFCurlFetch(NSString *url, NSString *method, NSDictionary *headers, NSData *body,
                    NSInteger *status, NSError **error);
// A GET that also tells where it ended up after redirects (relative URIs of a playlist resolve there)
// Optional gate runs before bytes are retained and with 0 during idle progress checks.
// NO aborts immediately; the redirect URL is preserved.
NSData *SFCurlFetchLimitedFinal(NSString *url, NSInteger *status, NSString **effective, NSError **error,
                               BOOL (^accept)(NSUInteger bytes));
NSData *SFCurlFetchFinal(NSString *url, NSInteger *status, NSString **effectiveURL, NSError **error);

// curl_easy_init() without TLS certificate verification (see .m). Returns a CURL * (void *,
// so this header does without curl.h).
// curl/OpenSSL global init; call once at launch on main (lazy init on a worker raced with
// exit()'s OpenSSL cleanup -> crash on quit, 2026-11-05). Idempotent.
void SFCurlGlobalInit(void);
void *SFCurlNew(void);

// A streamed GET of the bytes [start, end) (end < 0: to the end), redirects followed: head(status,
// total length, type) once the answer's head is in (NO: stop), then chunk(bytes) as they arrive (NO:
// stop; it may block - backpressure). maxRate: bytes/s (0: unlimited). Background only. NO on a
// transport error (a stop asked for by a block is no error).
BOOL SFCurlStream(NSString *url, long long start, long long end, long long maxRate,
                  BOOL (^head)(NSInteger status, long long total, NSString *mime),
                  BOOL (^chunk)(NSData *bytes), NSError **error);

// The same, with an optional liveness gate polled even when the origin sends no chunks.
BOOL SFCurlStreamWhile(NSString *url, long long start, long long end, long long maxRate,
                       BOOL (^continuing)(void),
                       BOOL (^head)(NSInteger status, long long total, NSString *mime),
                       BOOL (^chunk)(NSData *bytes), NSError **error);

// Download a large file straight to disk (follows redirects, HTTP error = failure). Background only.
BOOL SFCurlDownload(NSString *url, NSString *path, NSError **error);

// Hosts that need the curl path (learned automatically on SSL errors).
BOOL SFHostNeedsCurl(NSString *host);
void SFMarkHostNeedsCurl(NSString *host);
// an app declares the hosts it knows need curl (e.g. TLS 1.3 / AES-GCM only) - exact host, or
// ".domain" for every host below it; called from the app's +start
void SFMarkDomainNeedsCurl(NSString *domain);
BOOL SFIsTLSError(NSError *e);

