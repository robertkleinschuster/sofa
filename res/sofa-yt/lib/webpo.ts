// WebPO token minter: BotGuard runs in-process (bgutils-js + jsdom), like the real web player.
// No player request is made here: youtube.com page (challenge), interpreter JS, GenerateIT.
// The integrity token lives ~12 h; the minter is renewed before it expires and re-created with
// backoff after failures. Tokens are bound to the video id (content binding) for the player
// request and the SABR stream.
import type { WebPoMinter } from 'bgutils-js/webpo';
import type { WebPoSignalOutput } from 'bgutils-js/shared-types';
import type { DOMWindow } from 'jsdom';
import { errorMessage } from './errors.ts';
import { isRecord, optNumber, optString, parseJson } from './json.ts';
import { log } from './log.ts';
import type { Identity } from './identity.ts';

/** What the provider needs from a minter (a test may pass a fake factory). */
export type Minter = Pick<WebPoMinter, 'mint' | 'mintAsWebsafeString'>;

export interface MinterSetup {
  minter: Minter;
  dispose?: () => void;
  ttlMs: number;          // integrity token lifetime
  refreshMs: number;      // YouTube's refresh threshold
}

export type ProviderState = 'pending' | 'ready' | 'error';

/** The parts of youtube.com's BotGuard challenge (window.ytAtN(...)) used here. */
interface PageChallenge {
  bgChallenge?: {
    interpreterUrl: { privateDoNotAccessOrElseTrustedResourceUrlWrappedValue: string };
    program: string;
    globalName: string;
  };
}

const FETCH_TIMEOUT_MS = 15000;
const RETRY_MIN_MS = 60 * 1000;
const RETRY_MAX_MS = 30 * 60 * 1000;

async function createMinter(identity: Identity): Promise<MinterSetup> {
  const { JSDOM } = await import('jsdom');
  const { BotGuardClient } = await import('bgutils-js/botguard');
  const { WebPoMinter } = await import('bgutils-js/webpo');
  const { getHeaders, buildURL, parseLooseJSON } = await import('bgutils-js/utils');
  const t0 = performance.now();
  const sig = () => AbortSignal.timeout(FETCH_TIMEOUT_MS);
  const dom = new JSDOM('<!DOCTYPE html><html lang="de-AT"><head><title></title></head><body></body></html>', {
    url: 'https://www.youtube.com', referrer: 'https://www.youtube.com/', userAgent: identity.userAgent,
  });
  // a page load: the browser's headers come from the process-wide fetch (identity.ts)
  const pageHtml = await (await fetch('https://www.youtube.com', {
    headers: { accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' }, signal: sig(),
  })).text();
  const ytConfig = pageHtml.match(/ytcfg\.set\(({.+?})\);/s)?.[1];
  if (!ytConfig) throw new Error('webpo: ytcfg not found in page');
  const win = dom.window as DOMWindow & { yt?: { config_: unknown } };
  win.yt = { config_: parseJson(ytConfig) };
  // BotGuard probes a 2d canvas; jsdom has none -> inert stub (as in the googlevideo example), only as
  // much of a CanvasRenderingContext2D as BotGuard touches
  (dom.window.HTMLCanvasElement.prototype as { getContext: (id: string) => object | null }).getContext = function getContext(id: string) {
    if (id !== '2d') return null;
    const n = (): void => {};
    return { fillRect: n, clearRect: n, getImageData: (_x: number, _y: number, w: number, h: number) => ({ data: new Uint8ClampedArray(w * h * 4) }),
      putImageData: n, createImageData: () => [], setTransform: n, drawImage: n, save: n, fillText: n, restore: n,
      beginPath: n, moveTo: n, lineTo: n, closePath: n, stroke: n, translate: n, scale: n, rotate: n, arc: n, fill: n,
      measureText: () => ({ width: 0 }), transform: n, rect: n, clip: n };
  };
  // BotGuard's VM expects browser globals
  Object.assign(globalThis, { yt: win.yt, window: dom.window, document: dom.window.document,
    location: dom.window.location, origin: dom.window.origin });
  if (!('navigator' in globalThis)) Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });

  const att = pageHtml.match(/window\.ytAtN\(\s*({[\s\S]*?})\s*\)/);
  if (!att) throw new Error('webpo: challenge not found in page');
  const loose: unknown = parseLooseJSON(att[1]!).R;
  const challenge = isRecord(loose) ? (loose as PageChallenge) : null;   // BotGuard validates the rest
  if (!challenge?.bgChallenge) throw new Error('webpo: no bgChallenge');
  const interpreterUrl = challenge.bgChallenge.interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue;
  const js = await (await fetch(`https:${interpreterUrl}`, { signal: sig() })).text();
  if (!js) throw new Error('webpo: empty interpreter');
  new Function(js)(); // eslint-disable-line no-new-func -- BotGuard interpreter (Google's VM)

  const bg = await BotGuardClient.create({ program: challenge.bgChallenge.program,
    globalName: challenge.bgChallenge.globalName, globalObject: globalThis });
  const webPoSignalOutput: WebPoSignalOutput = [];
  const bgResponse = await bg.snapshot({ webPoSignalOutput });
  const itRes = await fetch(buildURL('GenerateIT', true), { method: 'POST', headers: getHeaders(),
    body: JSON.stringify(['O43z0dpjhgX20SCx4KAo', bgResponse]), signal: sig() });
  if (!itRes.ok) throw new Error(`webpo: GenerateIT HTTP ${itRes.status}`);
  const it: unknown = await itRes.json();
  const [integrityToken, estimatedTtlSecs, mintRefreshThreshold, websafeFallbackToken] = Array.isArray(it) ? it : [];
  if (typeof integrityToken !== 'string' || !integrityToken) throw new Error('webpo: no integrity token');
  const minter = await WebPoMinter.create({ integrityToken, estimatedTtlSecs: optNumber(estimatedTtlSecs),
    mintRefreshThreshold: optNumber(mintRefreshThreshold), websafeFallbackToken: optString(websafeFallbackToken) },
    webPoSignalOutput);
  log(`webpo: integrity token ttl=${estimatedTtlSecs}s, setup ${(performance.now() - t0).toFixed(0)} ms`);
  // dispose: the renewal (every ~12 h) must not keep the old jsdom window alive (review 2026-11-05)
  return { minter, dispose: () => { try { dom.window.close(); } catch { /* already closed */ } }, ttlMs: (Number(estimatedTtlSecs) || 3600) * 1000, refreshMs: (Number(mintRefreshThreshold) || 100) * 1000 };
}

export class PoTokenProvider {
  factory: () => Promise<MinterSetup>;
  state: ProviderState;
  current: { minter: Minter; dispose?: (() => void) | undefined; expiresAt: number } | null;
  inflight: Promise<Minter> | null;
  retryMs: number;
  nextTry: number;
  lastError: string | null;

  constructor({ identity, factory }: { identity?: Identity; factory?: () => Promise<MinterSetup> } = {}) {
    if (!factory && !identity) throw new Error('PoTokenProvider needs an identity (or a test factory)');
    this.factory = factory ?? (() => createMinter(identity!));
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
    let timer: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([this.inflight, new Promise<never>((_, rej) => {
        timer = setTimeout(() => rej(new Error('PO token setup timed out')), timeoutMs);
      })]);
    } finally {
      clearTimeout(timer);
    }
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
