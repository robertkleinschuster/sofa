// Signaturprüfung für Sofa-Updates (RSA PKCS#1 v1.5, SHA-256), nativ über SecTransform (10.9).
// Signiert wird bei tools/make-release mit ~/.config/sofa/release-signing-key.pem
// (openssl dgst -sha256 -sign); der öffentliche Schlüssel liegt als res/sofa-release-public.pem im
// Bundle. Ersetzt TLS als Echtheitsnachweis: Sofa lädt ohne Zertifikatsprüfung (SFCurlNew).
#import <Foundation/Foundation.h>

// YES nur, wenn sig eine gültige Signatur von file mit dem Schlüssel in pemPath ist.
BOOL SFVerifyFileSignature(NSString *file, NSData *sig, NSString *pemPath);
