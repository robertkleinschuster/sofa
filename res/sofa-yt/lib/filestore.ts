// State on files (node only), written atomically: the StateStore (one private file per key below the
// state directory) and the breaker file shared with Sofa. Not part of the browser engine.
import fs from 'node:fs';
import path from 'node:path';
import type { StateStore } from './store.ts';
import type { BlockState, BlockStore } from './breaker.ts';
import { parseJson, record } from './json.ts';
import { errorMessage } from './errors.ts';
import { log } from './log.ts';

/** Write `value` to `file` atomically (temp file + rename). */
function writeAtomic(file: string, value: string, mode?: number): void {
  const tmp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, value, mode === undefined ? undefined : { mode });
  fs.renameSync(tmp, file);
}

export class FileStore implements StateStore {
  readonly dir: string;
  constructor(dir: string) { this.dir = dir; }

  private file(key: string): string { return path.join(this.dir, key); }

  get(key: string): string | null {
    try { return fs.readFileSync(this.file(key), 'utf8'); } catch { return null; }
  }

  set(key: string, value: string): void {
    const f = this.file(key);
    try {
      fs.mkdirSync(path.dirname(f), { recursive: true });
      writeAtomic(f, value, 0o600);
    } catch (e) { log(`state: cannot write ${key}:`, errorMessage(e)); }
  }

  delete(key: string): void {
    try { fs.unlinkSync(this.file(key)); } catch { /* not there */ }
  }

  keys(prefix: string): string[] {
    try { return fs.readdirSync(this.file(prefix)).filter((f) => !f.includes('.tmp.')).map((f) => `${prefix}${f}`); }
    catch { return []; }
  }
}

/** The breaker file Sofa (SFYTBreaker) reads; re-read on every check (other instances write it too). */
export class FileBlocks implements BlockStore {
  readonly file: string;
  constructor(file: string) { this.file = file; }

  read(): BlockState | null {
    try {
      const b = parseJson(fs.readFileSync(this.file, 'utf8'));
      if (b === null) return null;   // unusable: as if unreadable
      const r = record(b);
      return { until: Number(r.until) || 0, backoff: Number(r.backoff) || 0 };
    } catch {
      return null;
    }
  }

  write(b: BlockState): void {
    try { writeAtomic(this.file, JSON.stringify(b)); } catch (e) { log('breaker: cannot write', this.file, errorMessage(e)); }
  }
}
