// The connection a current desktop Chrome opens (docs/youtube.md "One identity"): the identity's
// headers say "Chrome", so the TLS handshake underneath should say so too. Node's defaults offered
// 52 cipher suites, X448/P-521/ffdhe groups and ALPN "http/1.1" before "h2" - a fingerprint no
// browser has (JA4 t13d5212h1_b262b3658495, measured 2026-11-06). With Chrome's suites, groups,
// signature algorithms and ALPN order the cipher part of the fingerprint is Chrome's exactly
// (t13d1512h2_8daaf6152771). Left over: OpenSSL lacks some of Chrome's extensions (certificate
// compression, ALPS, ECH GREASE), so the extension part still differs.
// Installed as the global dispatcher (main.ts): every fetch of the process - InnerTube, BotGuard,
// SABR media, captions - goes through it.
import type { ConnectionOptions } from 'node:tls';
import { Agent } from 'undici';

/** Chrome's cipher suites in its order (TLS 1.3 first, then its TLS 1.2 list). */
export const CHROME_CIPHERS = [
  'TLS_AES_128_GCM_SHA256', 'TLS_AES_256_GCM_SHA384', 'TLS_CHACHA20_POLY1305_SHA256',
  'ECDHE-ECDSA-AES128-GCM-SHA256', 'ECDHE-RSA-AES128-GCM-SHA256', 'ECDHE-ECDSA-AES256-GCM-SHA384',
  'ECDHE-RSA-AES256-GCM-SHA384', 'ECDHE-ECDSA-CHACHA20-POLY1305', 'ECDHE-RSA-CHACHA20-POLY1305',
  'ECDHE-RSA-AES128-SHA', 'ECDHE-RSA-AES256-SHA', 'AES128-GCM-SHA256', 'AES256-GCM-SHA384', 'AES128-SHA', 'AES256-SHA',
].join(':');
/** Chrome's key exchange groups (post-quantum hybrid first). */
export const CHROME_GROUPS = 'X25519MLKEM768:X25519:P-256:P-384';
/** Chrome's signature algorithms. */
export const CHROME_SIGALGS = [
  'ecdsa_secp256r1_sha256', 'rsa_pss_rsae_sha256', 'rsa_pkcs1_sha256', 'ecdsa_secp384r1_sha384',
  'rsa_pss_rsae_sha384', 'rsa_pkcs1_sha384', 'rsa_pss_rsae_sha512', 'rsa_pkcs1_sha512',
].join(':');

/** The TLS options of a Chrome connection (also what tests check OpenSSL accepts). */
export const CHROME_TLS = { ciphers: CHROME_CIPHERS, ecdhCurve: CHROME_GROUPS, sigalgs: CHROME_SIGALGS, minVersion: 'TLSv1.2' } as const;

/** A dispatcher that connects like Chrome: HTTP/2 preferred, Chrome's TLS offer. `extra`: tests
 *  (a test server's CA). */
export function chromeAgent(extra: ConnectionOptions = {}): Agent {
  return new Agent({ allowH2: true, connect: { ...extra, ...CHROME_TLS, preferH2: true } });
}
