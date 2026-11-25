// SFTLS - the server side of TLS for SFLocalHTTP (Sofa im Browser, docs/pwa.md): OpenSSL - the one
// bundled for libcurl - with a certificate chain and its key from PEM files. Replaceable while
// serving: a renewed certificate applies from the next connection on. TLS 1.2 and 1.3 only,
// OpenSSL's default server ciphers (forward secrecy).
#import "SFLocalHTTP.h"

@interface SFTLS : NSObject <SFHTTPSecurity>
// NO (and why) when the files don't hold a certificate with its matching key; the earlier stays.
- (BOOL)loadCertificate:(NSString *)certPath key:(NSString *)keyPath error:(NSError **)error;
@property (nonatomic, readonly) BOOL ready;             // a certificate is loaded
@property (nonatomic, readonly) NSDate *expires;        // its notAfter
@property (nonatomic, readonly) NSString *subjectName;  // its first DNS name (or CN)
// A certificate file's notAfter without loading it; nil when unreadable.
+ (NSDate *)expiryOfCertificate:(NSString *)certPath;
@end
