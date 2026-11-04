#import "SFSignature.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

static NSData *SFSHA256Raw(NSString *path) {
    NSInputStream *in = [NSInputStream inputStreamWithFileAtPath:path];
    if (!in) return nil;
    [in open];
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    uint8_t buf[1 << 16]; NSInteger n;
    while ((n = [in read:buf maxLength:sizeof buf]) > 0) CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
    [in close];
    if (n < 0) return nil;
    unsigned char md[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(md, &ctx);
    return [NSData dataWithBytes:md length:sizeof md];
}

BOOL SFVerifyFileSignature(NSString *file, NSData *sig, NSString *pemPath) {
    NSData *pem = pemPath ? [NSData dataWithContentsOfFile:pemPath] : nil;
    NSData *digest = SFSHA256Raw(file);
    if (!pem || !digest || sig.length < 64) return NO;
    SecExternalFormat fmt = kSecFormatPEMSequence;
    SecExternalItemType type = kSecItemTypePublicKey;
    CFArrayRef items = NULL;
    if (SecItemImport((__bridge CFDataRef)pem, CFSTR(".pem"), &fmt, &type, 0, NULL, NULL, &items) != errSecSuccess || !items) return NO;
    BOOL ok = NO;
    if (CFArrayGetCount(items) == 1 && CFGetTypeID(CFArrayGetValueAtIndex(items, 0)) == SecKeyGetTypeID()) {
        SecKeyRef key = (SecKeyRef)CFArrayGetValueAtIndex(items, 0);
        CFErrorRef err = NULL;
        SecTransformRef v = SecVerifyTransformCreate(key, (__bridge CFDataRef)sig, &err);
        if (v && SecTransformSetAttribute(v, kSecTransformInputAttributeName, (__bridge CFDataRef)digest, &err) &&
            SecTransformSetAttribute(v, kSecInputIsAttributeName, kSecInputIsDigest, &err) &&
            SecTransformSetAttribute(v, kSecDigestTypeAttribute, kSecDigestSHA2, &err) &&
            SecTransformSetAttribute(v, kSecDigestLengthAttribute, (__bridge CFNumberRef)@256, &err)) {
            CFTypeRef r = SecTransformExecute(v, &err);
            ok = r && CFGetTypeID(r) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)r);
            if (r) CFRelease(r);
        }
        if (v) CFRelease(v);
        if (err) CFRelease(err);
    }
    CFRelease(items);
    return ok;
}
