// The engine's small persistent state (player responses, request budget, visitor) behind one
// key-value interface, so the same code runs in node (FileStore, files in the state directory) and
// in the browser engine (MemoryStore, seeded and saved by Sofa over BiDi - docs/youtube-engine.md).
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
