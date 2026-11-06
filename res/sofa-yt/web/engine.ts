// Sofa's YouTube engine in Firefox (docs/youtube-engine.md): bundled by tools/build-yt-engine into
// build/sofa-yt-web/engine.js and injected into a hidden youtube.com tab with BiDi
// script.addPreloadScript, whose function gets a BiDi channel and hands it to connect(). Sofa calls
// globalThis.sofaEngine with script.callFunction; the engine talks back over the channel (ready,
// log lines, breaker changes).
//
// The engine core (lib/engine.ts) is the one the node sidecar serves over HTTP; here it runs on the
// page's own environment: youtubei.js' web build with the page's context (pagesession.ts), BotGuard in
// the real document (pagebotguard.ts), state in the profile's localStorage, the breaker state Sofa's.
import { Innertube } from 'youtubei.js/web';
import { SabrStream } from 'googlevideo/sabr-stream';
import { BotGuardClient } from 'bgutils-js/botguard';
import { WebPoMinter } from 'bgutils-js/webpo';
import { createEngine, EngineError } from '../lib/engine.ts';
import type { Engine, EngineHealth, OpenAnswer, OpenRequest } from '../lib/engine.ts';
import { sabrPumps } from '../lib/pump.ts';
import { YouTube, PlayerBudget } from '../lib/youtube.ts';
import { PoTokenProvider } from '../lib/webpo.ts';
import { Breaker, MemoryBlocks } from '../lib/breaker.ts';
import type { BlockState } from '../lib/breaker.ts';
import { WebStorageStore } from '../lib/store.ts';
import { toBase64 } from '../lib/bytes.ts';
import { errorMessage } from '../lib/errors.ts';
import { log, setDebug, setLogSink } from '../lib/log.ts';
import type { SessionConfig } from '../lib/session.ts';
import { pageSessions } from './pagesession.ts';
import { documentMinter } from './pagebotguard.ts';
import { onYouTubePage } from './page.ts';

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

/** What the engine tells Sofa over the BiDi channel (each one JSON-encoded, one message per event). */
export type EngineEvent =
  | { type: 'ready'; userAgent: string; url: string }   // injected into a document (preload script ran)
  | { type: 'log'; line: string }
  | { type: 'block'; state: BlockState };

/** Every call's answer: a value or the status + body the HTTP sidecar would have answered with. */
export type Reply<T> = { ok: true; value: T } | { ok: false; status: number; body: { error: string } & Record<string, unknown> };

export interface MediaChunk {
  total: number;
  mimeType: string;
  /** base64 of bytes [offset, offset + n) */
  data: string;
}

/** What Sofa can ask the engine (docs/youtube-engine.md "Engine API"). */
export interface SofaEngine {
  health(): { libraries: boolean; userAgent: string; origin: string; onYouTube: boolean; engine: EngineHealth | null };
  /** The preload script hands over its BiDi channel: `send` posts one JSON string to Sofa. */
  connect(send: (json: string) => void): void;
  start(cfg: EngineConfig): Reply<{ userAgent: string }>;
  block(state: BlockState): void;
  open(req: OpenRequest): Promise<Reply<OpenAnswer>>;
  read(sid: string, key: string, offset: number, maxBytes: number): Promise<Reply<MediaChunk>>;
  playlist(sid: string): Promise<Reply<string>>;
  subtitles(sid: string, key: string): Promise<Reply<string>>;
  status(sid: string): Reply<object>;
  close(sid: string): Reply<boolean>;
  innertube(endpoint: string, body: unknown, opts: { bg: boolean }): Promise<Reply<object>>;
  suggest(q: string): Promise<Reply<object>>;
  stop(): void;
}

const STORE_PREFIX = 'sofa-engine:';

let core: Engine | null = null;
let blocks: MemoryBlocks | null = null;
let channel: ((json: string) => void) | null = null;
const send = (e: EngineEvent): void => { channel?.(JSON.stringify(e)); };

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

const engine: SofaEngine = {
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
    setLogSink((line) => send({ type: 'log', line }));
    send({ type: 'ready', userAgent: navigator.userAgent, url: location.href });
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
      core = createEngine({ youtube, po, breaker, startPump: sabrPumps({ youtube, po }), sessionCfg, base: () => base });
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
    return { total: r.total, mimeType: r.mimeType, data: toBase64(r.bytes) };
  }),
  playlist: (sid) => replyAsync(() => core!.playlist(sid)),
  subtitles: (sid, key) => replyAsync(() => core!.subtitles(sid, key)),
  status: (sid) => reply(() => core!.status(sid)),
  close: (sid) => reply(() => core!.close(sid)),
  innertube: (endpoint, body, opts) => replyAsync(() => core!.innertube(endpoint, body, opts)),
  suggest: (q) => replyAsync(() => core!.suggest(q)),

  stop() {
    core?.shutdown();
    core = null;
    blocks = null;
  },
};

(globalThis as typeof globalThis & { sofaEngine?: SofaEngine }).sofaEngine = engine;
