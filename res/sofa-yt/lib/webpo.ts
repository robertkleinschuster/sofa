// WebPO tokens: keeps a BotGuard minter (botguard.ts) ready - the integrity token lives ~12 h; the
// minter is renewed before it expires, after a rejected token (renew), and re-created with backoff
// after failures. Tokens are bound to the video id (content binding) for the player request and the
// SABR stream. Runtime-neutral: the factory brings the environment (node: nodebotguard.ts / jsdom).
import type { WebPoMinter } from 'bgutils-js/webpo';
import { errorMessage } from './errors.ts';
import { log } from './log.ts';

/** What the provider needs from a minter (a test may pass a fake factory). */
export type Minter = Pick<WebPoMinter, 'mint' | 'mintAsWebsafeString'>;

export interface MinterSetup {
  minter: Minter;
  dispose?: () => void;
  ttlMs: number;          // integrity token lifetime
  refreshMs: number;      // YouTube's refresh threshold
}

export type ProviderState = 'pending' | 'ready' | 'error';

const RETRY_MIN_MS = 60 * 1000;
const RETRY_MAX_MS = 30 * 60 * 1000;
const RENEW_MIN_MS = 10 * 60 * 1000;   // renew() at most this often

export class PoTokenProvider {
  factory: () => Promise<MinterSetup>;
  state: ProviderState;
  current: { minter: Minter; dispose?: (() => void) | undefined; expiresAt: number } | null;
  inflight: Promise<Minter> | null;
  retryMs: number;
  nextTry: number;
  lastError: string | null;
  lastRenew = 0;

  /** factory: one attestation in this runtime (node: () => jsdomMinter(identity)) */
  constructor({ factory }: { factory: () => Promise<MinterSetup> }) {
    this.factory = factory;
    this.state = 'pending';
    this.current = null; // {minter, expiresAt}
    this.inflight = null;
    this.retryMs = RETRY_MIN_MS;
    this.nextTry = 0;
    this.lastError = null;
  }

  /** Start (or renew) in the background; never throws. */
  warm(): void { this.ensure().catch(() => {}); }

  async ensure(timeoutMs = 30000): Promise<Minter> {
    const now = Date.now();
    if (this.current && now < this.current.expiresAt) return this.current.minter;
    if (!this.inflight) {
      if (now < this.nextTry) throw new Error(`PO token unavailable (${this.lastError}); retry in ${Math.ceil((this.nextTry - now) / 1000)} s`);
      if (!this.current) this.state = 'pending';
      this.inflight = (async () => {
        try {
          const { minter, ttlMs, refreshMs, dispose } = await this.factory();
          const old = this.current;
          // renew a little before YouTube's refresh threshold
          this.current = { minter, dispose, expiresAt: Date.now() + Math.max(60000, ttlMs - refreshMs - 5 * 60000) };
          this.state = 'ready';
          old?.dispose?.();
          this.retryMs = RETRY_MIN_MS;
          this.lastError = null;
          return minter;
        } catch (e) {
          this.lastError = errorMessage(e);
          this.nextTry = Date.now() + this.retryMs;
          this.retryMs = Math.min(RETRY_MAX_MS, this.retryMs * 2);
          if (!this.current || Date.now() >= this.current.expiresAt) { this.current = null; this.state = 'error'; }
          log('webpo: minter setup failed:', errorMessage(e));
          throw e;
        } finally {
          this.inflight = null;
        }
      })();
    }
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([this.inflight, new Promise<never>((_, rej) => {
        timer = setTimeout(() => rej(new Error('PO token setup timed out')), timeoutMs);
      })]);
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * A fresh BotGuard attestation for the next tokens - after YouTube rejected a token (stream
   * protection status 3; 2026-11-06 every stall stopped at 60 s with SPS 3). At most once per
   * RENEW_MIN_MS: every renewal is a BotGuard request of its own.
   */
  renew(): void {
    const now = Date.now();
    if (!this.current || this.inflight || now - this.lastRenew < RENEW_MIN_MS) return;
    this.lastRenew = now;
    this.current.expiresAt = 0;   // ensure() creates a new minter; the old one is disposed then
    log('webpo: renewing the attestation after a rejected token');
    this.warm();
  }

  /** Websafe base64 token bound to `contentBinding` (video id). */
  async mintString(contentBinding: string): Promise<string> {
    const m = await this.ensure();
    return m.mintAsWebsafeString(contentBinding);
  }

  /** Raw token bytes (googlevideo's onMintPoToken). */
  async mintBytes(contentBinding: string): Promise<Uint8Array> {
    const m = await this.ensure();
    return m.mint(contentBinding);
  }
}
