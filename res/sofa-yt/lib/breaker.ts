// Bot-check circuit breaker in a file shared with Sofa (SFYTBreaker) and every instance on this IP
// ({"until": epoch_seconds, "backoff": seconds}). After "Sign in to confirm you're not a bot" the
// background (preload, downloads) sends no player request until `until`: 1 h, doubling up to 8 h,
// reset by the first success - a probe every few minutes met the same block and kept it alive
// (2026-11-06: 27 refused requests, probes after 5/10/20/40 min). Playback the user starts still
// tries, except within FG_HOLD_S of the check: retries from the phone went straight into the block
// (7 player requests in 15 min). The file is re-read on every check because another instance
// (another sidecar) may update it too.
import fs from 'node:fs';
import { parseJson, record } from './json.ts';
import { errorMessage } from './errors.ts';
import { log } from './log.ts';

export const BLOCK_MIN = 3600;
export const BLOCK_MAX = 8 * 3600;
export const FG_HOLD_S = 180;

/** The breaker file: `until` epoch seconds, `backoff` seconds. */
export interface BlockState {
  until: number;
  backoff: number;
}

export class Breaker {
  file: string | null;
  now: () => number;
  mem: BlockState;

  constructor(file: string | null, now = (): number => Date.now() / 1000) {
    this.file = file;
    this.now = now;
    this.mem = { until: 0, backoff: 0 }; // used when no file is configured / unreadable
  }

  read(): BlockState {
    if (!this.file) return this.mem;
    try {
      const b = parseJson(fs.readFileSync(this.file, 'utf8'));
      if (b === null) return this.mem;   // unusable: as if unreadable
      const r = record(b);
      return { until: Number(r.until) || 0, backoff: Number(r.backoff) || 0 };
    } catch {
      return this.mem;
    }
  }

  write(b: BlockState): void {
    this.mem = b;
    if (!this.file) return;
    try {
      const tmp = `${this.file}.tmp.${process.pid}`;
      fs.writeFileSync(tmp, JSON.stringify(b));
      fs.renameSync(tmp, this.file);
    } catch (e) {
      log('breaker: cannot write', this.file, errorMessage(e));
    }
  }

  /** Epoch seconds until which background requests are paused, 0 if not blocked. */
  blockedUntil(): number {
    const b = this.read();
    return b.until > this.now() ? b.until : 0;
  }

  /** Epoch seconds until which even user playback sends nothing (right after a bot check), 0 if not. */
  heldUntil(): number {
    const b = this.read();
    if (!b.until || !b.backoff) return 0;
    const hold = b.until - b.backoff + FG_HOLD_S;   // the check happened at until - backoff
    return hold > this.now() ? hold : 0;
  }

  note(botCheck: boolean): void {
    const b = this.read();
    if (botCheck) {
      const backoff = Math.min(BLOCK_MAX, Math.max(BLOCK_MIN, b.backoff * 2));
      this.write({ until: this.now() + backoff, backoff });
      log(`bot check - background requests paused for ${Math.floor(backoff / 60)} min`);
    } else if (b.backoff || b.until) {
      this.write({ until: 0, backoff: 0 });
      log('requests succeed again - pause lifted');
    }
  }
}

/** Does a playability status / error text mean YouTube's bot check? */
export function isBotCheck(text: string | null | undefined): boolean {
  const m = String(text || '').toLowerCase();
  return m.includes('not a bot') || m.includes('sign in to confirm');
}
