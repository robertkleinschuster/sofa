// Timer helpers for node and the browser engine alike.

/** A timer that must not keep a node process alive (node: unref; the browser has no such notion). */
export function background<T extends ReturnType<typeof setTimeout>>(t: T): T {
  (t as { unref?: () => void }).unref?.();
  return t;
}

/** `p`, or a rejection "<what> timed out" after `ms` - whatever `p` does later is ignored. */
export function withTimeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  let t: ReturnType<typeof setTimeout> | undefined;
  return Promise.race([p, new Promise<never>((_, rej) => { t = setTimeout(() => rej(new Error(`${what} timed out`)), ms); })])
    .finally(() => clearTimeout(t));
}
