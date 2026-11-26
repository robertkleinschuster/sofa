// What is going on at Sofa (docs/pwa.md §6): one long poll of /api/status - Sofa answers when its
// state is not the generation we have (what the TV plays, the downloads on their way), else after at
// most 25 s. Runs while the page is visible and paired; stops while hidden (no request in the
// background), and waits longer after each failure (Sofa unreachable) up to half a minute.

import { ApiError, type Api } from './api.ts';
import type { Status } from './types.ts';

const RETRY_MS = [2_000, 5_000, 10_000, 30_000];

export class StatusFeed {
  private gen = '';
  private ctl: AbortController | null = null;
  private running = false;
  private failures = 0;
  private retry: ReturnType<typeof setTimeout> | null = null;
  private onVisibility = (): void => { if (document.hidden) this.pause(); else this.resume(); };
  last: Status | null = null;

  constructor(private api: Api, private changed: (s: Status) => void, private lost: () => void) {}

  start(): void {
    if (this.running) return;
    this.running = true;
    document.addEventListener('visibilitychange', this.onVisibility);
    if (!document.hidden) this.poll();
  }

  stop(): void {
    this.running = false;
    document.removeEventListener('visibilitychange', this.onVisibility);
    this.pause();
  }

  // after an action of our own: ask at once instead of waiting for the running poll's answer
  refresh(): void {
    if (!this.running || document.hidden) return;
    this.pause();
    this.gen = '';
    this.poll();
  }

  private pause(): void {
    this.ctl?.abort();
    this.ctl = null;
    if (this.retry) { clearTimeout(this.retry); this.retry = null; }
  }

  private resume(): void {
    if (!this.running || this.ctl || this.retry) return;
    this.gen = '';   // the state may have changed while hidden: the first answer comes at once
    this.poll();
  }

  private poll(): void {
    const ctl = new AbortController();
    this.ctl = ctl;
    this.api.status(this.gen, ctl.signal).then((s) => {
      if (this.ctl !== ctl) return;
      this.ctl = null;
      this.failures = 0;
      this.gen = s.gen;
      this.last = s;
      this.changed(s);
      if (this.running && !document.hidden) this.poll();
    }, (e: unknown) => {
      if (this.ctl !== ctl) return;   // aborted on purpose
      this.ctl = null;
      if (e instanceof ApiError && e.status === 401) { this.stop(); this.lost(); return; }
      const wait = RETRY_MS[Math.min(this.failures++, RETRY_MS.length - 1)]!;
      this.retry = setTimeout(() => { this.retry = null; if (this.running && !document.hidden) this.poll(); }, wait);
    });
  }
}
