// Talking to Sofa (docs/pwa.md, API). Every call but hello/pair carries the device token.

import { baseURL, type Connection } from './connection.ts';
import type { Info, Item, MarkChange, MoreAnswer, Page, PlayAnswer, Status, TvState } from './types.ts';

export class ApiError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
  // Sofa could not be reached at all (offline, not on the tailnet, the Mac asleep, a blocked
  // local-network permission) - as opposed to an answer with an error.
  get unreachable(): boolean { return this.status === 0; }
}

const TIMEOUT_MS = 60_000;   // the server bounds page loaders at 45 s

export class Api {
  constructor(readonly connection: Connection) {}

  url(path: string): string { return baseURL(this.connection) + path; }

  // `signal`: the caller may give up (a long poll when the page hides) - that rejects with an AbortError
  async request<T>(method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<T> {
    const headers: Record<string, string> = {};
    if (this.connection.token) headers['Authorization'] = `Bearer ${this.connection.token}`;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
    if (signal?.aborted) ctl.abort(); else signal?.addEventListener('abort', () => ctl.abort(), { once: true });
    let res: Response;
    try {
      res = await fetch(this.url(path), {
        method, headers, signal: ctl.signal, cache: 'no-store', credentials: 'omit',
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      });
    } catch (e) {
      if (signal?.aborted) throw e;
      throw new ApiError(0, 'Sofa ist gerade nicht erreichbar.');
    } finally {
      clearTimeout(timer);
    }
    let json: unknown = null;
    try { json = await res.json(); } catch { /* an empty or non-JSON answer */ }
    if (!res.ok) {
      const msg = json && typeof json === 'object' && typeof (json as { error?: unknown }).error === 'string'
        ? (json as { error: string }).error : `Sofa antwortet mit Fehler ${res.status}.`;
      throw new ApiError(res.status, msg);
    }
    return json as T;
  }

  hello(): Promise<{ name: string; version: string; paired: boolean }> { return this.request('GET', '/api/hello'); }
  pair(code: string, name: string): Promise<{ token: string; device: string }> { return this.request('POST', '/api/pair', { code, name }); }
  unpair(): Promise<unknown> { return this.request('DELETE', '/api/pair'); }
  info(): Promise<Info> { return this.request('GET', '/api/info'); }
  home(): Promise<Page> { return this.request('GET', '/api/home'); }
  app(id: string): Promise<Page> { return this.request('GET', `/api/app/${encodeURIComponent(id)}`); }
  page(handle: string): Promise<Page> { return this.request('GET', `/api/page/${encodeURIComponent(handle)}`); }
  more(handle: string): Promise<MoreAnswer> { return this.request('GET', `/api/more/${encodeURIComponent(handle)}`); }
  show(ref: string, title?: string): Promise<Page> {
    return this.request('GET', `/api/show?ref=${encodeURIComponent(ref)}${title ? `&title=${encodeURIComponent(title)}` : ''}`);
  }
  recentSearches(app: string): Promise<{ recent: string[] }> { return this.request('GET', `/api/search?app=${encodeURIComponent(app)}`); }
  search(app: string, q: string): Promise<Page> { return this.request('GET', `/api/search?app=${encodeURIComponent(app)}&q=${encodeURIComponent(q)}`); }
  suggest(app: string, q: string): Promise<{ list: string[] }> { return this.request('GET', `/api/suggest?app=${encodeURIComponent(app)}&q=${encodeURIComponent(q)}`); }
  play(item: Item): Promise<PlayAnswer> { return this.request('POST', '/api/play', { item: item.d }); }
  report(stream: string, state: StreamReport): Promise<unknown> { return this.request('POST', `/api/stream/${stream}`, state); }
  // marks and the item's download; a started download also says what the TV would tell
  mark(item: Item, change: MarkChange): Promise<{ item: Item; message?: string }> {
    return this.request('POST', '/api/state', { item: item.d, ...change });
  }
  // the TV (docs/pwa.md §6): 409 = another video plays there (`replace` replaces it)
  tvPlay(item: Item, opts: { fromStart?: boolean; at?: number; replace?: boolean }): Promise<{ tv: TvState | null; already?: boolean }> {
    return this.request('POST', '/api/tv/play', { item: item.d, ...opts });
  }
  tvControl(action: 'play' | 'pause' | 'stop'): Promise<{ tv: TvState | null }> { return this.request('POST', '/api/tv/control', { action }); }
  // answers when Sofa's state is not `since` any more (at once for another), else after at most 25 s
  status(since: string, signal: AbortSignal): Promise<Status> {
    return this.request('GET', `/api/status?since=${encodeURIComponent(since)}`, undefined, signal);
  }

  // A picture through Sofa's image route, sized for its box in device pixels.
  image(path: string | undefined, cssWidth: number): string | undefined {
    if (!path) return undefined;
    const px = Math.min(1920, Math.ceil(cssWidth * Math.min(3, globalThis.devicePixelRatio || 1) / 40) * 40);
    return `${this.url(path)}&w=${px}`;
  }

  // The last report of a playback, sent as the page goes away: a beacon on the stream's capability
  // path (no headers possible; text/plain keeps it a simple CORS request).
  beacon(stream: string, state: StreamReport): boolean {
    try {
      return navigator.sendBeacon(this.url(`/m/${stream}/state`), new Blob([JSON.stringify(state)], { type: 'text/plain' }));
    } catch { return false; }
  }
}

export interface StreamReport {
  state: 'playing' | 'paused' | 'buffering' | 'ended' | 'closed';
  position?: number;
  duration?: number;
  lactMs?: number;
}
