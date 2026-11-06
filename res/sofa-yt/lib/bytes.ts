// Byte helpers that work the same in node and in the browser engine (docs/youtube-engine.md):
// plain Uint8Array and the Web Crypto / atob globals instead of node's Buffer and crypto modules.

/** n random bytes as lowercase hex (session ids). */
export function randomHex(n: number): string {
  const b = globalThis.crypto.getRandomValues(new Uint8Array(n));
  return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
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
