// Sofa's YouTube engine in Firefox (docs/youtube-engine.md): the API object of one youtube.com page.
// Loaded by the extension's page script (page-main.ts: commands from Sofa through the extension's
// bridge) or, in offline tests, by a BiDi preload script (bidi-main.ts). connect() gets the channel
// back to Sofa (ready, log lines, breaker changes).
//
// The engine core (lib/engine.ts) runs here on the page's own environment: youtubei.js' web build with the page's context (pagesession.ts), BotGuard in
// the real document (pagebotguard.ts), state in the profile's localStorage, the breaker state Sofa's.
import { Innertube } from 'youtubei.js/web';
import { SabrStream } from 'googlevideo/sabr-stream';
import { BotGuardClient } from 'bgutils-js/botguard';
import { WebPoMinter } from 'bgutils-js/webpo';
import { createEngine, EngineError } from '../lib/engine.ts';
import type { Engine, EngineHealth, OpenAnswer, OpenRequest } from '../lib/engine.ts';
import type { PlayerState } from '../lib/report.ts';
import { pageReporting } from './pagereport.ts';
import { sabrPumps } from '../lib/pump.ts';
import { YouTube, PlayerBudget } from '../lib/youtube.ts';
import { PoTokenProvider } from '../lib/webpo.ts';
import { Breaker, MemoryBlocks } from '../lib/breaker.ts';
import type { BlockState } from '../lib/breaker.ts';
import { WebStorageStore } from '../lib/store.ts';
import { errorMessage } from '../lib/errors.ts';
import { log, setDebug, setLogSink } from '../lib/log.ts';
import type { SessionConfig } from '../lib/session.ts';
import { pageSessions } from './pagesession.ts';
import { documentMinter } from './pagebotguard.ts';
import { onYouTubePage } from './page.ts';
import { initTrustedTypes } from './trusted.ts';
import { createLounge } from '../lib/lounge.ts';
import type { LoungeEvent } from '../lib/lounge.ts';
import { watchConsent } from './consent.ts';
import type { ConsentTarget } from './consent.ts';

/** How Sofa starts the engine. */
export interface EngineConfig {
  /** Sofa's loopback server for /s/<sid>/... (the URLs of open answers). */
  base: string;
  /** Sofa's breaker file (SFYTBreaker), null if there is none. */
  block: BlockState | null;
  maxPlayerRequests?: number;
  budgetWindowS?: number;
  /** pacing window in seconds of media ahead of the reader */
  aheadLowS?: number;
  aheadHighS?: number;
  debug?: boolean;
}

/** What the engine tells Sofa on its own (the channel's events). */
export type EngineEvent =
  // injected into a document (preload script ran); late: after document_start, navigation: how the
  // document was loaded (navigate, reload, back_forward) - both for the log of an unexpected new page
  | { type: 'ready'; userAgent: string; url: string; late: boolean; navigation: string }
  | { type: 'log'; line: string }
  | { type: 'block'; state: BlockState }
  | ({ type: 'consent' } & ConsentTarget)   // the consent dialog's accept button, for Sofa to click (consent.ts)
  | LoungeEvent;   // a lounge poll's bytes and end (lib/lounge.ts)

/** Every call's answer: a value or the status + body an HTTP server would answer with. */
export type Reply<T> = { ok: true; value: T } | { ok: false; status: number; body: { error: string } & Record<string, unknown> };

export interface MediaChunk {
  total: number;
  mimeType: string;
  /** bytes [offset, offset + n) */
  data: Uint8Array;
}

/** What Sofa can ask the engine (docs/youtube-engine.md "Engine API"). */
export interface SofaEngine {
  health(): { libraries: boolean; userAgent: string; origin: string; onYouTube: boolean; engine: EngineHealth | null };
  /** The page script (or a test's preload script) hands over the channel: `send` posts one event. */
  connect(send: (e: EngineEvent) => void): void;
  start(cfg: EngineConfig): Reply<{ userAgent: string }>;
  block(state: BlockState): void;
  open(req: OpenRequest): Promise<Reply<OpenAnswer>>;
  read(sid: string, key: string, offset: number, maxBytes: number): Promise<Reply<MediaChunk>>;
  playlist(sid: string): Promise<Reply<string>>;
  segment(sid: string, n: number): Promise<Reply<{ mimeType: string; data: Uint8Array }>>;
  subtitles(sid: string, key: string): Promise<Reply<string>>;
  status(sid: string): Reply<object>;
  /** Sofa's player state for a session: the view's stats pings (lib/report.ts); `closed` ends the view. */
  report(sid: string, state: PlayerState | { state: 'closed' }): Promise<Reply<boolean>>;
  close(sid: string): Reply<boolean>;
  innertube(endpoint: string, body: unknown, opts: { bg: boolean }): Promise<Reply<object>>;
  suggest(q: string): Promise<Reply<object>>;
  availability(v: string): Promise<Reply<number>>;
  image(url: string): Promise<Reply<{ mimeType: string; data: Uint8Array }>>;
  /** The lounge's requests from this page (lib/lounge.ts): status + body. */
  loungeRequest(method: string, url: string, body: string | null): Promise<Reply<{ status: number; data: Uint8Array }>>;
  /** Starts the bind channel's long poll; bytes and end come as `lounge` events. */
  loungePoll(id: string, url: string): Reply<boolean>;
  stop(): void;
}

const STORE_PREFIX = 'sofa-engine:';

let core: Engine | null = null;
let blocks: MemoryBlocks | null = null;
let channel: ((e: EngineEvent) => void) | null = null;
const send = (e: EngineEvent): void => { channel?.(e); };
const lounge = createLounge({ fetch: (input, init) => fetch(input, init), emit: send });

function reply<T>(f: () => T): Reply<T> {
  try {
    if (!core) throw new EngineError(503, { error: 'engine not started' });
    return { ok: true, value: f() };
  } catch (e) {
    return failure(e);
  }
}
async function replyAsync<T>(f: () => Promise<T>): Promise<Reply<T>> {
  try {
    if (!core) throw new EngineError(503, { error: 'engine not started' });
    return { ok: true, value: await f() };
  } catch (e) {
    return failure(e);
  }
}
function failure(e: unknown): { ok: false; status: number; body: { error: string } & Record<string, unknown> } {
  if (e instanceof EngineError) return { ok: false, status: e.status, body: e.body };
  log('call failed:', e instanceof Error ? e.stack || e.message : errorMessage(e));
  return { ok: false, status: 500, body: { error: errorMessage(e) } };
}

/** The engine of this page (one per document). */
export const sofaEngine: SofaEngine = {
  health: () => ({
    libraries: [Innertube, SabrStream, BotGuardClient, WebPoMinter, createEngine, sabrPumps, YouTube, PoTokenProvider]
      .every((c) => typeof c === 'function'),
    userAgent: navigator.userAgent,
    origin: location.origin,
    onYouTube: onYouTubePage(),
    engine: core?.health() ?? null,
  }),

  connect(post) {
    channel = post;
    if (location.origin === 'https://www.youtube.com') initTrustedTypes();   // before the page's scripts
    // what the page's CSP refuses is what YouTube can see in its reports: never silent
    document.addEventListener('securitypolicyviolation', (e) => {
      log(`csp: ${e.disposition} ${e.violatedDirective} blocked ${e.blockedURI || '?'} ${(e.sample || '').slice(0, 80)}`);
    });
    setLogSink((line) => send({ type: 'log', line }));
    const nav = performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming | undefined;
    send({ type: 'ready', userAgent: navigator.userAgent, url: location.href, late: document.readyState !== 'loading', navigation: nav?.type ?? '?' });
    watchConsent((target) => send({ type: 'consent', ...target }));
  },

  start(cfg) {
    try {
      if (core) throw new EngineError(409, { error: 'engine already started' });
      if (!onYouTubePage()) throw new EngineError(412, { error: `not on a youtube.com page (${location.origin})` });
      if (cfg.debug) setDebug(true);
      blocks = new MemoryBlocks(cfg.block, (state) => send({ type: 'block', state }));
      const breaker = new Breaker(blocks);
      const store = new WebStorageStore(localStorage, STORE_PREFIX, (key, e) => log(`state: cannot write ${key}:`, errorMessage(e)));
      const po = new PoTokenProvider({ factory: documentMinter });
      const max = cfg.maxPlayerRequests ?? 60;
      const budget = new PlayerBudget({ store, max: max > 0 ? max : Infinity, windowS: cfg.budgetWindowS ?? 3600 });
      const youtube = new YouTube({ store, sessions: pageSessions(), breaker, po, budget });
      const sessionCfg: Partial<SessionConfig> = {};
      if (cfg.aheadLowS) sessionCfg.LOW_MS = cfg.aheadLowS * 1000;
      if (cfg.aheadHighS) sessionCfg.HIGH_MS = cfg.aheadHighS * 1000;
      const base = cfg.base.replace(/\/+$/, '');
      core = createEngine({ youtube, po, breaker, startPump: sabrPumps({ youtube, po }), sessionCfg, base: () => base, reporting: pageReporting() });
      log(`engine started on ${location.origin} (${navigator.userAgent})`);
      return { ok: true, value: { userAgent: navigator.userAgent } };
    } catch (e) {
      return failure(e);
    }
  },

  block(state) { if (blocks) blocks.state = state; },   // Sofa's file changed: no echo back

  open: (req) => replyAsync(() => core!.open(req)),
  read: (sid, key, offset, maxBytes) => replyAsync(async () => {
    const r = await core!.read(sid, key, offset, maxBytes);
    return { total: r.total, mimeType: r.mimeType, data: r.bytes };
  }),
  playlist: (sid) => replyAsync(() => core!.playlist(sid)),
  segment: (sid, n) => replyAsync(async () => {
    const r = await core!.segment(sid, n);
    return { mimeType: r.mimeType, data: r.bytes };
  }),
  subtitles: (sid, key) => replyAsync(() => core!.subtitles(sid, key)),
  status: (sid) => reply(() => core!.status(sid)),
  report: (sid, state) => replyAsync(() => core!.report(sid, state)),
  close: (sid) => reply(() => core!.close(sid)),
  innertube: (endpoint, body, opts) => replyAsync(() => core!.innertube(endpoint, body, opts)),
  suggest: (q) => replyAsync(() => core!.suggest(q)),
  availability: (v) => replyAsync(() => core!.availability(v)),
  image: (url) => replyAsync(async () => {
    const r = await core!.image(url);
    return { mimeType: r.mimeType, data: r.bytes };
  }),

  loungeRequest: (method, url, body) => replyAsync(() => lounge.request(method, url, body)),
  loungePoll: (id, url) => reply(() => { lounge.poll(id, url); return true; }),

  stop() {
    lounge.stop();
    core?.shutdown();
    core = null;
    blocks = null;
  },
};

