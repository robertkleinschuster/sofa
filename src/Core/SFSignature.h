// Signature verification for Sofa updates (RSA PKCS#1 v1.5, SHA-256), natively via SecTransform (10.9).
// tools/make-release signs with ~/.config/sofa/release-signing-key.pem
// (openssl dgst -sha256 -sign); the public key ships as res/sofa-release-public.pem in the
// bundle. Replaces TLS as proof of authenticity: Sofa downloads without certificate verification (SFCurlNew).
#import <Foundation/Foundation.h>

// YES only if sig is a valid signature of file with the key in pemPath.
BOOL SFVerifyFileSignature(NSString *file, NSData *sig, NSString *pemPath);
