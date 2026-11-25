#import "SFTLS.h"
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

static NSString *LastError(void) {
    unsigned long e = ERR_get_error();
    char buf[256];
    if (!e) return @"unknown";
    ERR_error_string_n(e, buf, sizeof buf);
    ERR_clear_error();
    return @(buf);
}

static NSDate *NotAfter(X509 *x) {
    struct tm t = {0};
    const ASN1_TIME *na = x ? X509_get0_notAfter(x) : NULL;
    if (!na || ASN1_TIME_to_tm(na, &t) != 1) return nil;
    return [NSDate dateWithTimeIntervalSince1970:timegm(&t)];
}

static NSString *FirstName(X509 *x) {
    GENERAL_NAMES *names = X509_get_ext_d2i(x, NID_subject_alt_name, NULL, NULL);
    NSString *out = nil;
    for (int i = 0; names && i < sk_GENERAL_NAME_num(names) && !out; i++) {
        GENERAL_NAME *g = sk_GENERAL_NAME_value(names, i);
        if (g->type == GEN_DNS) out = [[NSString alloc] initWithBytes:ASN1_STRING_get0_data(g->d.dNSName)
                                                               length:(NSUInteger)ASN1_STRING_length(g->d.dNSName) encoding:NSASCIIStringEncoding];
    }
    if (names) GENERAL_NAMES_free(names);
    if (out) return out;
    char cn[256] = {0};
    X509_NAME_get_text_by_NID(X509_get_subject_name(x), NID_commonName, cn, sizeof cn);
    return cn[0] ? @(cn) : nil;
}

@implementation SFTLS {
    SSL_CTX *_ctx;   // the current one; a connection holds its own reference (SSL_new)
}

- (void)dealloc { if (_ctx) SSL_CTX_free(_ctx); }

- (BOOL)loadCertificate:(NSString *)certPath key:(NSString *)keyPath error:(NSError **)error {
    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
    BOOL ok = ctx && SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) == 1
        && SSL_CTX_use_certificate_chain_file(ctx, certPath.fileSystemRepresentation) == 1
        && SSL_CTX_use_PrivateKey_file(ctx, keyPath.fileSystemRepresentation, SSL_FILETYPE_PEM) == 1
        && SSL_CTX_check_private_key(ctx) == 1;
    if (!ok) {
        NSString *why = LastError();
        if (ctx) SSL_CTX_free(ctx);
        if (error) *error = [NSError errorWithDomain:@"SFTLS" code:1 userInfo:@{NSLocalizedDescriptionKey: [@"TLS: " stringByAppendingString:why]}];
        return NO;
    }
    SSL_CTX_set_options(ctx, SSL_OP_CIPHER_SERVER_PREFERENCE | SSL_OP_NO_RENEGOTIATION);
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_SERVER);   // resumption: one request per connection
    X509 *x = SSL_CTX_get0_certificate(ctx);
    NSDate *expires = NotAfter(x);
    NSString *name = FirstName(x);
    @synchronized (self) {
        if (_ctx) SSL_CTX_free(_ctx);
        _ctx = ctx;
        _expires = expires;
        _subjectName = name;
    }
    return YES;
}

- (BOOL)ready { @synchronized (self) { return _ctx != NULL; } }

+ (NSDate *)expiryOfCertificate:(NSString *)certPath {
    FILE *f = fopen(certPath.fileSystemRepresentation, "r");
    if (!f) return nil;
    X509 *x = PEM_read_X509(f, NULL, NULL, NULL);
    fclose(f);
    NSDate *d = NotAfter(x);
    if (x) X509_free(x);
    return d;
}

- (void *)acceptOn:(int)fd {
    SSL *ssl = NULL;
    @synchronized (self) { if (_ctx) ssl = SSL_new(_ctx); }
    if (!ssl) return NULL;
    SSL_set_fd(ssl, fd);
    if (SSL_accept(ssl) != 1) {   // a client that refused the certificate, a scanner, a timeout
        ERR_clear_error();
        SSL_free(ssl);
        return NULL;
    }
    return ssl;
}

// SSL_read/SSL_write outcome -> recv/send convention (errno EAGAIN: nothing for now)
static ssize_t Outcome(SSL *ssl, int r) {
    if (r > 0) return r;
    int e = SSL_get_error(ssl, r);
    ERR_clear_error();
    if (e == SSL_ERROR_ZERO_RETURN) return 0;
    if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) { errno = EAGAIN; return -1; }
    if (e == SSL_ERROR_SYSCALL && errno == 0) return 0;   // the peer closed without close_notify
    if (errno == 0 || errno == EAGAIN || errno == EINTR) errno = EIO;
    return -1;
}

- (ssize_t)read:(void *)session into:(void *)buf max:(size_t)n {
    errno = 0;
    return Outcome(session, SSL_read(session, buf, (int)MIN(n, (size_t)INT_MAX)));
}

- (ssize_t)write:(void *)session from:(const void *)buf length:(size_t)n {
    errno = 0;
    return Outcome(session, SSL_write(session, buf, (int)MIN(n, (size_t)INT_MAX)));
}

- (void)end:(void *)session {
    SSL *ssl = session;
    if (!ssl) return;
    SSL_shutdown(ssl);   // our close_notify; theirs is not waited for (SO_NOSIGPIPE: a gone peer is no signal)
    ERR_clear_error();
    SSL_free(ssl);
}
@end
