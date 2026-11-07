// Sofa's side of the engine channel, for tests (docs/youtube-engine.md "Channel"; Sofa's own is
// ObjC): a loopback HTTP server the extension's bridge long-polls for commands and posts answers and
// events to, plus installing the extension into a Firefox profile.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import type { Answer, Command, Method, Upload } from '../../res/sofa-yt/web/protocol.ts';

const POLL_HOLD_MS = 20000;
export const EXTENSION_ID = 'youtube-engine@sofa';

export interface EngineHost {
  port: number;
  token: string;
  /** decoded engine events in arrival order */
  events: { type: string; [k: string]: unknown }[];
  /** One engine call; rejects after `timeoutMs` without an answer (a page that went away). */
  call<T>(method: Method, ...args: unknown[]): Promise<T>;
  callWithin<T>(timeoutMs: number, method: Method, ...args: unknown[]): Promise<T>;
  close(): Promise<void>;
}

const CALL_TIMEOUT_MS = 120000;   // read() waits for SABR like a player; longer means the page is gone

export async function startEngineHost({ onEvent }: { onEvent?: (e: EngineHost['events'][number]) => void } = {}): Promise<EngineHost> {
  const token = randomBytes(16).toString('hex');
  const queue: Command[] = [];
  const waiting = new Map<number, { ok: (v: unknown) => void; bad: (e: Error) => void }>();
  const events: EngineHost['events'] = [];
  let poller: (() => void) | null = null;
  let nextId = 1;

  const server = http.createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    if (url.searchParams.get('token') !== token) { res.writeHead(403).end(); return; }
    if (req.method === 'GET' && url.pathname === '/engine/poll') {
      const answer = (): void => {
        poller = null;
        clearTimeout(timer);
        const body = JSON.stringify(queue.splice(0));
        res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' }).end(body);
      };
      const timer = setTimeout(answer, POLL_HOLD_MS);
      if (queue.length) answer(); else poller = answer;
      req.on('close', () => { if (poller === answer) { poller = null; clearTimeout(timer); } });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/engine/post') {
      let body = '';
      req.on('data', (d) => { body += d; });
      req.on('end', () => {
        const up = JSON.parse(body) as Upload;
        for (const e of up.events) { const ev = JSON.parse(e) as EngineHost['events'][number]; events.push(ev); onEvent?.(ev); }
        for (const a of up.answers as Answer[]) {
          const w = waiting.get(a.id);
          if (!w) continue;
          waiting.delete(a.id);
          if ('error' in a) w.bad(new Error(a.error)); else w.ok(a.value);
        }
        res.writeHead(204).end();
      });
      return;
    }
    res.writeHead(404).end();
  });
  function callWithin<T>(timeoutMs: number, method: Method, ...args: unknown[]): Promise<T> {
    const id = nextId++;
    return new Promise<T>((ok, bad) => {
      const timer = setTimeout(() => { waiting.delete(id); bad(new Error(`engine: no answer to ${method} within ${timeoutMs} ms`)); }, timeoutMs);
      waiting.set(id, { ok: (v) => { clearTimeout(timer); (ok as (v: unknown) => void)(v); }, bad: (e) => { clearTimeout(timer); bad(e); } });
      queue.push({ id, method, args });
      poller?.();
    });
  }
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const addr = server.address();
  const port = addr !== null && typeof addr === 'object' ? addr.port : 0;
  return {
    port, token, events,
    call: <T>(method: Method, ...args: unknown[]): Promise<T> => callWithin<T>(CALL_TIMEOUT_MS, method, ...args),
    callWithin,
    async close() { server.closeAllConnections(); await new Promise((r) => server.close(r)); },
  };
}

/**
 * Install the built extension (build/sofa-yt-web/extension) unpacked into `profile`, configured for
 * `host`: a copy with config.json, referenced by a proxy file in the profile's extensions directory.
 */
export function installExtension(profile: string, built: string, host: Pick<EngineHost, 'port' | 'token'>): string {
  const dir = path.join(profile, '..', `${path.basename(profile)}-extension`);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(built, dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'config.json'), JSON.stringify({ port: host.port, token: host.token }));
  fs.mkdirSync(path.join(profile, 'extensions'), { recursive: true });
  fs.writeFileSync(path.join(profile, 'extensions', EXTENSION_ID), dir);
  return dir;
}

/** Prefs a profile with Sofa's unsigned, sideloaded extension needs (Firefox ESR honours them). */
export const EXTENSION_PREFS = { 'xpinstall.signatures.required': false, 'extensions.autoDisableScopes': 0, 'extensions.enabledScopes': 15 };
