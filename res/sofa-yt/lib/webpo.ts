// WebPO tokens: keeps a BotGuard minter (botguard.ts) ready - the integrity token lives ~12 h; the
// minter is renewed before it expires, after a rejected token (renew), and re-created with backoff
// after failures. Nothing waits without a deadline: an attestation or a mint that hangs (BotGuard's
// VM, incident 2026-11-07: every open stalled after a page reload) fails, and the next attempt
// starts afresh instead of waiting on the hung one. Tokens are bound to the video id (content binding) for the player request and the
// SABR stream. Runtime-neutral: the factory brings the environment (node: nodebotguard.ts / jsdom).
import type { WebPoMinter } from 'bgutils-js/webpo';
import { errorMessage } from './errors.ts';
import { log } from './log.ts';
import { withTimeout } from './timers.ts';

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
const SETUP_TIMEOUT_MS = 30 * 1000;    // one attestation (measured 1-4 s, the first ~10 s)
const MINT_TIMEOUT_MS = 10 * 1000;     // one token (measured: milliseconds)

export interface ProviderOptions {
  /** one attestation in this runtime (browser: documentMinter) */
  factory: () => Promise<MinterSetup>;
  setupTimeoutMs?: number;
  mintTimeoutMs?: number;
  retryMinMs?: number;
}

export class PoTokenProvider {
  factory: () => Promise<MinterSetup>;
  state: ProviderState;
  current: { minter: Minter; dispose?: (() => void) | undefined; expiresAt: number } | null;
  inflight: Promise<Minter> | null;
  retryMs: number;
  nextTry: number;
  lastError: string | null;
  lastRenew = 0;
  readonly setupTimeoutMs: number;
  readonly mintTimeoutMs: number;
  readonly retryMinMs: number;

  constructor({ factory, setupTimeoutMs = SETUP_TIMEOUT_MS, mintTimeoutMs = MINT_TIMEOUT_MS, retryMinMs = RETRY_MIN_MS }: ProviderOptions) {
    this.factory = factory;
    this.setupTimeoutMs = setupTimeoutMs;
    this.mintTimeoutMs = mintTimeoutMs;
    this.retryMinMs = retryMinMs;
    this.state = 'pending';
    this.current = null; // {minter, expiresAt}
    this.inflight = null;
    this.retryMs = retryMinMs;
    this.nextTry = 0;
    this.lastError = null;
  }

  /** Start (or renew) in the background; never throws. */
  warm(): void { this.ensure().catch(() => {}); }

  /** The current minter, or a new attestation (at most setupTimeoutMs). */
  async ensure(): Promise<Minter> {
    const now = Date.now();
    if (this.current && now < this.current.expiresAt) return this.current.minter;
    if (!this.inflight) {
      if (now < this.nextTry) throw new Error(`PO token unavailable (${this.lastError}); retry in ${Math.ceil((this.nextTry - now) / 1000)} s`);
      if (!this.current) this.state = 'pending';
      this.inflight = (async () => {
        const attempt = this.factory();
        try {
          const { minter, ttlMs, refreshMs, dispose } = await withTimeout(attempt, this.setupTimeoutMs, 'PO token setup');
          const old = this.current;
          // renew a little before YouTube's refresh threshold
          this.current = { minter, dispose, expiresAt: Date.now() + Math.max(60000, ttlMs - refreshMs - 5 * 60000) };
          this.state = 'ready';
          old?.dispose?.();
          this.retryMs = this.retryMinMs;
          this.lastError = null;
          return minter;
        } catch (e) {
          attempt.then((late) => late.dispose?.(), () => {});   // a hung attestation that finishes later is not used
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
    return this.inflight;
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
    return this.mintWith((m) => m.mintAsWebsafeString(contentBinding));
  }

  /** Raw token bytes (googlevideo's onMintPoToken). */
  async mintBytes(contentBinding: string): Promise<Uint8Array> {
    return this.mintWith((m) => m.mint(contentBinding));
  }

  /** One mint within mintTimeoutMs; a minter that hangs is dropped - the next token re-attests. */
  private async mintWith<T>(mint: (m: Minter) => Promise<T>): Promise<T> {
    const m = await this.ensure();
    try {
      return await withTimeout(mint(m), this.mintTimeoutMs, 'PO token mint');
    } catch (e) {
      if (this.current?.minter === m) {
        log('webpo: minter dropped:', errorMessage(e));
        this.current.expiresAt = 0;
      }
      throw e;
    }
  }
}
