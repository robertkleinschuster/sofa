// Sparse virtual file of one SABR track.
//
// The SABR byte stream of a track is byte-identical to the original googlevideo file: every media
// segment carries its absolute byte offset (MediaHeader.segmentByteRangeStart) and length, and the init
// segment covers [0, indexRange.end] (header + Cues/sidx). So a track is exposed as a file of
// format.contentLength bytes in which only the fetched segments are present. Entries never overlap;
// the init entry and the parsed index are kept for the lifetime of the track.
import { parseIndex, indexLookup } from './mediaindex.ts';
import type { MediaIndex } from './mediaindex.ts';

/** A stored segment: bytes [start, end) of the file, media time [startMs, endMs). */
export interface Entry {
  start: number;
  end: number;
  startMs: number;
  endMs: number;
  buf: Buffer;
  init: boolean;
}

/** A segment as a SABR pump delivers it. */
export interface Segment {
  start: number;
  buf: Buffer;
  startMs?: number;
  durationMs?: number;
  init?: boolean;
}

export type AddResult = 'added' | 'dup' | 'overlap';

export interface ContiguousRun {
  end: number;
  endMs: number;
  toEof: boolean;
}

interface Waiter {
  check: () => void;
}

export class VirtualFile {
  total: number;
  durationMs: number;
  mimeType: string | undefined;
  entries: Entry[];
  bytes: number;
  index: MediaIndex | null;
  waiters: Set<Waiter>;
  failed: Error | null;

  /**
   * @param {object} o
   * @param {number} o.total       contentLength of the format (file size)
   * @param {number} o.durationMs  track duration
   * @param {string} o.mimeType
   */
  constructor({ total, durationMs, mimeType }: { total: number; durationMs: number; mimeType?: string | undefined }) {
    this.total = total;
    this.durationMs = durationMs;
    this.mimeType = mimeType;
    this.entries = []; // sorted by start: {start, end, startMs, endMs, buf, init}
    this.bytes = 0;
    this.index = null;
    this.waiters = new Set();
    this.failed = null; // Error once the track can no longer be fed (waiters reject)
  }

  get init(): Entry | null { return this.entries.length && this.entries[0]!.init ? this.entries[0]! : null; }
  get initEnd(): number { return this.init ? this.init.end : 0; }

  /** Position of the first entry with start > off (binary search). */
  upperBound(off: number): number {
    let lo = 0; let hi = this.entries.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.entries[mid]!.start <= off) lo = mid + 1; else hi = mid;
    }
    return lo;
  }

  /** Entry containing byte `off`, or null. */
  entryAt(off: number): Entry | null {
    const i = this.upperBound(off) - 1;
    if (i < 0) return null;
    const e = this.entries[i]!;
    return off < e.end ? e : null;
  }

  /** Media entry (not init) whose time span contains `ms`, or null. */
  entryAtTime(ms: number): Entry | null {
    for (const e of this.entries) {
      if (!e.init && e.startMs <= ms && ms < e.endMs) return e;
      if (!e.init && e.startMs > ms) break;
    }
    // last segment: its end is the track end, accept ms == endMs there
    const last = this.entries[this.entries.length - 1];
    if (last && !last.init && last.end >= this.total && ms >= last.startMs && ms <= Math.max(last.endMs, this.durationMs)) return last;
    return null;
  }

  /**
   * Add a segment. Returns 'added', 'dup' (already present) or 'overlap' (inconsistent, dropped).
   * The init segment must start at 0; its index is parsed right away.
   */
  add({ start, buf, startMs = 0, durationMs = 0, init = false }: Segment): AddResult {
    const end = start + buf.length;
    if (init && start !== 0) return 'overlap';
    if (end > this.total || buf.length === 0) return 'overlap';
    const i = this.upperBound(start);
    const prev = this.entries[i - 1];
    const next = this.entries[i];
    if (prev && prev.start === start && prev.end === end) return 'dup';
    if ((prev && prev.end > start) || (next && next.start < end)) return 'overlap';
    const e: Entry = { start, end, startMs, endMs: startMs + durationMs, buf, init };
    this.entries.splice(i, 0, e);
    this.bytes += buf.length;
    if (init && !this.index) this.index = parseIndex(buf, this.mimeType);
    this.wake();
    return 'added';
  }

  /**
   * Media time for byte `off`: from the stored segment containing it, else the index (Cues/sidx),
   * else a proportional estimate (only before the init segment arrived).
   */
  timeAt(off: number): number {
    if (off < this.initEnd) return 0;
    const e = this.entryAt(off);
    if (e && !e.init) return e.startMs;
    const ix = indexLookup(this.index, off);
    if (ix) return ix.ms;
    if (this.index && this.index.length) return 0; // before the first cluster
    return this.total > 0 ? Math.floor((off / this.total) * this.durationMs) : 0;
  }

  /** Byte offset where the media for time `ms` starts according to the index (or null). */
  offsetAtTime(ms: number): number | null {
    if (!this.index) return null;
    let best: { off: number } | null = null;
    for (const e of this.index) { if (e.ms <= ms) best = e; else break; }
    return best ? best.off : this.index[0]!.off;
  }

  /**
   * End of the contiguous run starting at the entry that contains `off`:
   * {end (bytes), endMs, toEof}. Null if `off` is not buffered.
   */
  contiguousFrom(off: number): ContiguousRun | null {
    let i = this.upperBound(off) - 1;
    if (i < 0 || off >= this.entries[i]!.end) return null;
    let e = this.entries[i]!;
    while (i + 1 < this.entries.length && this.entries[i + 1]!.start === e.end) e = this.entries[++i]!;
    const toEof = e.end >= this.total;
    return { end: e.end, endMs: toEof ? Math.max(e.endMs, this.durationMs) : e.endMs, toEof };
  }

  /** Copy-free view of [s, e) restricted to the entry that contains s. */
  sliceAt(s: number, e: number): Buffer | null {
    const en = this.entryAt(s);
    if (!en) return null;
    return en.buf.subarray(s - en.start, Math.min(e, en.end) - en.start);
  }

  /**
   * Drop media entries to bound memory. Keeps the init entry, everything within
   * [keepFromMs, +inf) and, if over `maxBytes`, removes the entries farthest from `readOff` first.
   * Returns the number of bytes freed.
   */
  evict({ keepFromMs, readOff, maxBytes }: { keepFromMs: number; readOff: number; maxBytes: number }): number {
    let freed = 0;
    const keep: Entry[] = [];
    for (const e of this.entries) {
      if (!e.init && e.endMs < keepFromMs) { freed += e.buf.length; continue; }
      keep.push(e);
    }
    this.entries = keep;
    this.bytes -= freed;
    if (maxBytes && this.bytes > maxBytes) {
      const victims = this.entries.filter((e) => !e.init)
        .map((e) => ({ e, dist: e.end <= readOff ? (readOff - e.end) * 4 : e.start - readOff })) // behind costs more
        .sort((a, b) => b.dist - a.dist);
      const drop = new Set<Entry>();
      for (const v of victims) {
        if (this.bytes <= maxBytes) break;
        if (v.e.start <= readOff && readOff < v.e.end) continue; // never the one being read
        drop.add(v.e);
        this.bytes -= v.e.buf.length;
        freed += v.e.buf.length;
      }
      this.entries = this.entries.filter((e) => !drop.has(e));
    }
    return freed;
  }

  /** Resolves when byte `off` becomes available; rejects on timeout or failure. */
  waitFor(off: number, timeoutMs: number, signal?: AbortSignal): Promise<void> {
    if (this.entryAt(off)) return Promise.resolve();
    if (this.failed) return Promise.reject(this.failed);
    return new Promise((resolve, reject) => {
      const w: Waiter = {
        check: () => {
          if (this.entryAt(off)) { done(); resolve(); } else if (this.failed) { done(); reject(this.failed); }
        },
      };
      const onAbort = () => { done(); reject(new Error('aborted')); };
      const timer = setTimeout(() => { done(); reject(new Error('timeout')); }, timeoutMs);
      const done = () => { clearTimeout(timer); this.waiters.delete(w); signal?.removeEventListener('abort', onAbort); };
      signal?.addEventListener('abort', onAbort);
      this.waiters.add(w);
    });
  }

  wake(): void { for (const w of [...this.waiters]) w.check(); }

  /** Mark the track as broken (or healthy again with null) and release waiters. */
  setFailed(err: Error | null): void { this.failed = err; if (err) this.wake(); }

  /** Free everything (session closed). */
  clear(): void {
    this.entries = []; this.bytes = 0;
    this.setFailed(this.failed || new Error('closed'));
  }
}
