// StateStore on files (node only): one file per key below the state directory, written atomically
// and private (0600). Not part of the browser engine.
import fs from 'node:fs';
import path from 'node:path';
import type { StateStore } from './store.ts';
import { errorMessage } from './errors.ts';
import { log } from './log.ts';

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
      const tmp = `${f}.tmp.${process.pid}`;
      fs.writeFileSync(tmp, value, { mode: 0o600 });
      fs.renameSync(tmp, f);
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
