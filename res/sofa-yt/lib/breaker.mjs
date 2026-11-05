// Bot-check circuit breaker, shared with res/ytresolver.py through the same file
// ({"until": epoch_seconds, "backoff": seconds}). After "Sign in to confirm you're not a bot" the
// background (preload, downloads) sends no player request until `until`: 5 min, doubling up to 1 h,
// reset by the first success. Playback the user starts still tries. The file is re-read on every
// check because the resolver process updates it too.
import fs from 'node:fs';
import { log } from './log.mjs';

export const BLOCK_MIN = 300;
export const BLOCK_MAX = 3600;

export class Breaker {
  constructor(file, now = () => Date.now() / 1000) {
    this.file = file;
    this.now = now;
    this.mem = { until: 0, backoff: 0 }; // used when no file is configured / unreadable
  }

  read() {
    if (!this.file) return this.mem;
    try {
      const b = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      return { until: Number(b.until) || 0, backoff: Number(b.backoff) || 0 };
    } catch {
      return this.mem;
    }
  }

  write(b) {
    this.mem = b;
    if (!this.file) return;
    try {
      const tmp = `${this.file}.tmp.${process.pid}`;
      fs.writeFileSync(tmp, JSON.stringify(b));
      fs.renameSync(tmp, this.file);
    } catch (e) {
      log('breaker: cannot write', this.file, e.message);
    }
  }

  /** Epoch seconds until which background requests are paused, 0 if not blocked. */
  blockedUntil() {
    const b = this.read();
    return b.until > this.now() ? b.until : 0;
  }

  note(botCheck) {
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
export function isBotCheck(text) {
  const m = String(text || '').toLowerCase();
  return m.includes('not a bot') || m.includes('sign in to confirm');
}
