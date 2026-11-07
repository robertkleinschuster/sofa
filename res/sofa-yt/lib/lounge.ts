// The lounge's transport (phone pairing, docs/youtube.md "Lounge"): the requests YouTube's TV web
// app (youtube.com/tv) makes to www.youtube.com/api/lounge, made by the youtube.com page itself -
// same origin, the profile's cookies, Firefox's connection. Sofa keeps the protocol (session,
// frames, messages, SFLounge.m); the page only carries its bytes. Bytes, not text: the bind
// channel's frame lengths are Sofa's to count.
import { EngineError } from './engine.ts';
import { errorMessage } from './errors.ts';

export const LOUNGE_API = 'https://www.youtube.com/api/lounge/';
/** The bind channel sends a noop about every 28 s: this long without bytes = a dead poll. */
export const POLL_SILENCE_MS = 70000;
const REQUEST_TIMEOUT_MS = 20000;

/** What a poll streams to Sofa, in order: data chunks, then one end (status, or error without one). */
export type LoungeEvent =
  | { type: 'lounge'; id: string; data: Uint8Array }
  | { type: 'lounge'; id: string; end: true; status: number; error?: string };

export interface LoungeOptions {
  fetch: typeof fetch;
  emit: (e: LoungeEvent) => void;
  silenceMs?: number;
}

export interface Lounge {
  /** One request (pairing, token, session open, send): its status and body. */
  request(method: string, url: string, body: string | null): Promise<{ status: number; data: Uint8Array }>;
  /** Starts the bind channel's long poll `id`; its bytes and end arrive as events. One poll at a
   * time - a new one ends the earlier (a restarted Sofa's poll replaces the old Sofa's). */
  poll(id: string, url: string): void;
  stop(): void;
}

function checked(url: string): URL {
  let u: URL;
  try { u = new URL(url); } catch { throw new EngineError(400, { error: 'not a URL' }); }
  if (!u.href.startsWith(LOUNGE_API)) throw new EngineError(400, { error: 'not a lounge URL' });
  return u;
}

const FORM = { 'content-type': 'application/x-www-form-urlencoded' };

export function createLounge({ fetch: pageFetch, emit, silenceMs = POLL_SILENCE_MS }: LoungeOptions): Lounge {
  let current: AbortController | null = null;

  return {
    async request(method, url, body) {
      const u = checked(url);
      if (method !== 'GET' && method !== 'POST') throw new EngineError(400, { error: `method ${method}` });
      let r: Response;
      try {
        r = await pageFetch(u, { method, headers: body === null ? {} : FORM, body, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
      } catch (e) { throw new EngineError(502, { error: errorMessage(e) }); }
      return { status: r.status, data: new Uint8Array(await r.arrayBuffer()) };
    },

    poll(id, url) {
      const u = checked(url);
      current?.abort();
      const abort = new AbortController();
      current = abort;
      let silence: ReturnType<typeof setTimeout> | undefined;
      const quiet = () => {
        clearTimeout(silence);
        silence = setTimeout(() => abort.abort(new Error(`no bytes for ${silenceMs / 1000} s`)), silenceMs);
      };
      void (async () => {
        let status = 0;
        try {
          quiet();
          const r = await pageFetch(u, { signal: abort.signal, cache: 'no-store' });
          status = r.status;
          const reader = r.body?.getReader();
          while (reader) {
            const { done, value } = await reader.read();
            if (done) break;
            quiet();
            if (value?.length) emit({ type: 'lounge', id, data: value });
          }
          if (abort.signal.aborted) throw abort.signal.reason;   // a stream that stops on abort: still cut off
          emit({ type: 'lounge', id, end: true, status });
        } catch (e) {
          // a poll cut off mid-stream is no clean end (Sofa: status 200 means "ended normally")
          emit({ type: 'lounge', id, end: true, status: 0, error: errorMessage(abort.signal.reason ?? e) });
        } finally {
          clearTimeout(silence);
          if (current === abort) current = null;
        }
      })();
    },

    stop() { current?.abort(); current = null; },
  };
}
