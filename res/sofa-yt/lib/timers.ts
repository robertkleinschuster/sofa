// Timer helpers for node and the browser engine alike.

/** A timer that must not keep a node process alive (node: unref; the browser has no such notion). */
export function background<T extends ReturnType<typeof setTimeout>>(t: T): T {
  (t as { unref?: () => void }).unref?.();
  return t;
}
