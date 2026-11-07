// The extension's background: relays between Sofa and the engine page (through bridge.ts) over one
// WebSocket to Sofa's loopback server, held while a page is connected. Commands come as text (a JSON
// array); answers and events go back batched per task - JSON text, or the binary container when they
// carry bytes (protocol.ts encodeUpload). Its connection is the extension's own (host permission) -
// invisible to any page. Sofa writes config.json ({port, token}) into the extension before it
// starts Firefox.
import { encodeUpload } from './protocol.ts';
import type { Answer, Command, EventMessage, Upload } from './protocol.ts';

interface RuntimePort {
  name: string;
  postMessage(m: unknown): void;
  onMessage: { addListener(f: (m: unknown) => void): void };
  onDisconnect: { addListener(f: () => void): void };
}
declare const browser: { runtime: { getURL(path: string): string; onConnect: { addListener(f: (p: RuntimePort) => void): void } } };

interface BridgeConfig { port: number; token: string }

// Sofa unreachable: reconnects at most this far apart - a restarted Sofa takes the running browser
// over (SFYTBrowser) and is back within seconds; loopback retries cost nothing
const RECONNECT_MAX_MS = 2000;
// events kept while Sofa is away (log lines, a block): the newest, up to this many
const MAX_HELD_EVENTS = 500;
const config: Promise<BridgeConfig> = fetch(browser.runtime.getURL('config.json')).then((r) => r.json() as Promise<BridgeConfig>);

let current: RuntimePort | null = null;   // the engine page; a newer one replaces it

browser.runtime.onConnect.addListener((page) => {
  if (page.name !== 'engine') return;
  current = page;
  let connected = true;
  let socket: WebSocket | null = null;
  page.onDisconnect.addListener(() => {
    connected = false;
    if (current === page) current = null;
    socket?.close();
  });

  // Commands go to the page under ids of their own: an answer is Sofa's only on the connection that
  // asked (a restarted Sofa counts from 1 again - the old one's late answer must not answer it)
  let nextId = 1;
  const asked = new Map<number, { id: number; socket: WebSocket }>();
  let held: Upload = { answers: [], events: [] };
  let flushQueued = false;

  const flush = (): void => {
    flushQueued = false;
    if (socket?.readyState !== WebSocket.OPEN || (!held.answers.length && !held.events.length)) return;
    const batch = held;
    held = { answers: [], events: [] };
    socket.send(encodeUpload(batch));
  };
  const queueFlush = (): void => { if (!flushQueued) { flushQueued = true; setTimeout(flush, 0); } };

  page.onMessage.addListener((m) => {
    if (typeof m === 'object' && m !== null && 'event' in m) {
      held.events.push((m as EventMessage).event);
      if (held.events.length > MAX_HELD_EVENTS) held.events.splice(0, held.events.length - MAX_HELD_EVENTS);
    } else {
      const a = m as Answer;
      const to = asked.get(a.id);
      asked.delete(a.id);
      if (!to || to.socket !== socket) return;   // asked on an earlier connection
      held.answers.push({ ...a, id: to.id });
    }
    queueFlush();
  });

  void config.then((cfg) => {
    const url = `ws://127.0.0.1:${cfg.port}/engine/ws?token=${encodeURIComponent(cfg.token)}`;
    let retry = 250;
    const open = (): void => {
      if (!connected || current !== page) return;
      const ws = new WebSocket(url);
      socket = ws;
      ws.onopen = () => { retry = 250; flush(); };
      ws.onmessage = (e: MessageEvent) => {
        if (typeof e.data !== 'string') return;
        let list: unknown;
        try { list = JSON.parse(e.data); } catch { return; }
        for (const c of Array.isArray(list) ? list : []) {
          if (typeof c !== 'object' || c === null || typeof (c as Partial<Command>).id !== 'number') continue;
          const local = nextId++;
          asked.set(local, { id: (c as Command).id, socket: ws });
          // an unknown method goes on too: the page answers it (protocol.ts unknownCommand)
          page.postMessage({ ...(c as object), id: local });
        }
      };
      ws.onclose = () => {
        if (socket !== ws) return;
        socket = null;
        held.answers = [];   // for the Sofa of that connection
        for (const [k, v] of asked) if (v.socket === ws) asked.delete(k);
        setTimeout(open, retry);
        retry = Math.min(RECONNECT_MAX_MS, retry * 2);
      };
    };
    open();
  });
});
