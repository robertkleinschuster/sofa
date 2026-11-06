// The engine's small persistent state (player responses, request budget, visitor) behind one
// key-value interface, so the same code runs in node (FileStore, files in the state directory) and
// in the browser engine (WebStorageStore: localStorage in Sofa's Firefox profile - docs/youtube-engine.md).
// Keys are relative paths ("players/<id>.json", "visitor.json"): the node layout stays as it was.

export interface StateStore {
  get(key: string): string | null;
  set(key: string, value: string): void;
  delete(key: string): void;
  /** Keys directly under a "dir/" prefix. */
  keys(prefix: string): string[];
}

/** State in memory (the browser engine; tests). */
export class MemoryStore implements StateStore {
  readonly data = new Map<string, string>();
  get(key: string): string | null { return this.data.get(key) ?? null; }
  set(key: string, value: string): void { this.data.set(key, value); }
  delete(key: string): void { this.data.delete(key); }
  keys(prefix: string): string[] {
    return [...this.data.keys()].filter((k) => k.startsWith(prefix) && !k.slice(prefix.length).includes('/'));
  }
}

/** The part of a Web Storage (localStorage) the engine uses. */
export interface WebStorageLike {
  readonly length: number;
  key(index: number): string | null;
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

/**
 * State in a Web Storage under a key prefix: the browser engine's localStorage on youtube.com, kept in
 * Sofa's Firefox profile like any site's storage. A full storage (quota) loses the write, logged:
 * every key is a cache or a counter that survives a loss.
 */
export class WebStorageStore implements StateStore {
  readonly storage: WebStorageLike;
  readonly prefix: string;
  readonly onError: (key: string, e: unknown) => void;
  constructor(storage: WebStorageLike, prefix: string, onError: (key: string, e: unknown) => void = () => {}) {
    this.storage = storage; this.prefix = prefix; this.onError = onError;
  }
  get(key: string): string | null { return this.storage.getItem(this.prefix + key); }
  set(key: string, value: string): void {
    try { this.storage.setItem(this.prefix + key, value); } catch (e) { this.onError(key, e); }
  }
  delete(key: string): void { this.storage.removeItem(this.prefix + key); }
  keys(prefix: string): string[] {
    const all = this.prefix + prefix;
    const out: string[] = [];
    for (let i = 0; i < this.storage.length; i++) {
      const k = this.storage.key(i);
      if (k?.startsWith(all) && !k.slice(all.length).includes('/')) out.push(k.slice(this.prefix.length));
    }
    return out;
  }
}
