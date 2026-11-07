// Bot-check circuit breaker; its state ({"until": epoch_seconds, "backoff": seconds, "calm"?}) is shared with
// Sofa (SFYTBreaker) and every instance on this IP. After "Sign in to confirm you're not a bot" the
// background (preload, downloads) sends no player request until `until`: 1 h, doubling up to 8 h,
// reset by the first success, followed by a calm period for the background (CALM_S) - a probe every few minutes met the same block and kept it alive
// (2026-11-06: 27 refused requests, probes after 5/10/20/40 min). Playback the user starts still
// tries, except within FG_HOLD_S of the check: retries from the phone went straight into the block
// (7 player requests in 15 min). Sofa keeps the state in one file every instance reads; the
// engine holds it in memory (a BlockStore: seeded by Sofa, every change reported back to it).
import { log } from './log.ts';

export const BLOCK_MIN = 3600;
export const BLOCK_MAX = 8 * 3600;
export const FG_HOLD_S = 180;
/**
 * After the first success lifts a pause the background stays quiet this long (`calm`): an identity
 * that just got through again sends what a viewer sends - playback, search, the phone - not 80
 * queued downloads and a round of channel checks (2026-11-07 20:52: lifted, downloads were due
 * 35 min later). Playback the user starts is not held.
 */
export const CALM_S = 6 * 3600;

/** The breaker state: `until` epoch seconds, `backoff` seconds; `calm`: `until` is the calm period
 * after a lifted pause (background only, no escalation kept). */
export interface BlockState {
  until: number;
  backoff: number;
  calm?: boolean;
}

/** Where the breaker state lives. read(): null = none or unreadable. */
export interface BlockStore {
  read(): BlockState | null;
  write(b: BlockState): void;
}

/** Breaker state in memory; `onWrite` sees every change (the browser engine tells Sofa). */
export class MemoryBlocks implements BlockStore {
  state: BlockState | null;
  onWrite: ((b: BlockState) => void) | null;
  constructor(state: BlockState | null = null, onWrite: ((b: BlockState) => void) | null = null) { this.state = state; this.onWrite = onWrite; }
  read(): BlockState | null { return this.state; }
  write(b: BlockState): void { this.state = b; this.onWrite?.(b); }
}

export class Breaker {
  store: BlockStore;
  now: () => number;
  mem: BlockState;

  constructor(store: BlockStore = new MemoryBlocks(), now = (): number => Date.now() / 1000) {
    this.store = store;
    this.now = now;
    this.mem = { until: 0, backoff: 0 }; // the last state written, used while the store has none / is unreadable
  }

  read(): BlockState { return this.store.read() ?? this.mem; }

  write(b: BlockState): void {
    this.mem = b;
    this.store.write(b);
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
    } else if (b.backoff) {
      this.write({ until: this.now() + CALM_S, backoff: 0, calm: true });
      log(`requests succeed again - pause lifted; background stays calm for ${CALM_S / 3600} h`);
    } else if (b.until && !b.calm) {
      this.write({ until: 0, backoff: 0 });
      log('requests succeed again - pause lifted');
    }
  }
}
