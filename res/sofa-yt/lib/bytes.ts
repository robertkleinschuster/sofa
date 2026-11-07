// Byte helpers that work the same in node and in the browser engine (docs/youtube-engine.md):
// plain Uint8Array and the Web Crypto / atob globals instead of node's Buffer and crypto modules.

/** n random bytes as lowercase hex (session ids). */
export function randomHex(n: number): string {
  const b = globalThis.crypto.getRandomValues(new Uint8Array(n));
  return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
}

/** A client playback nonce as youtube.com's player makes one: 16 characters of the base64url alphabet. */
export function clientNonce(): string {
  const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  return Array.from(globalThis.crypto.getRandomValues(new Uint8Array(16)), (x) => abc[x & 63]).join('');
}

/** Bytes of a base64 or base64url string. */
export function fromBase64(s: string): Uint8Array {
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/'));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Bytes [start, end) as a latin1 string (box / element type codes). */
export function latin1(buf: Uint8Array, start: number, end: number): string {
  return String.fromCharCode(...buf.subarray(start, end));
}

/** Bytes as base64 (media handed to Sofa over BiDi): the native encoder where there is one (Firefox 133+). */
export function toBase64(buf: Uint8Array): string {
  const native = (buf as Uint8Array & { toBase64?: () => string }).toBase64;
  if (native) return native.call(buf);
  let bin = '';
  for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
  return btoa(bin);
}
