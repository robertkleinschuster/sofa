// The extension's background: relays between Sofa's loopback server and the engine page (through
// bridge.ts). Long-polls Sofa for commands while a page is connected; posts answers and events in
// batches. Its requests are the extension's own (host permission, no CORS) - invisible to any page.
// Sofa writes config.json ({port, token}) into the extension before it starts Firefox.
import type { Answer, Command, Upload } from './protocol.ts';

interface RuntimePort {
  name: string;
  postMessage(m: unknown): void;
  onMessage: { addListener(f: (m: unknown) => void): void };
  onDisconnect: { addListener(f: () => void): void };
}
declare const browser: { runtime: { getURL(path: string): string; onConnect: { addListener(f: (p: RuntimePort) => void): void } } };

interface BridgeConfig { port: number; token: string }

const POLL_RETRY_MAX_MS = 10000;
const config: Promise<BridgeConfig> = fetch(browser.runtime.getURL('config.json')).then((r) => r.json() as Promise<BridgeConfig>);

let current: RuntimePort | null = null;   // the engine page; a newer one replaces it

browser.runtime.onConnect.addListener((page) => {
  if (page.name !== 'engine') return;
  current = page;
  let connected = true;
  page.onDisconnect.addListener(() => { connected = false; if (current === page) current = null; });

  void config.then((cfg) => {
    const base = `http://127.0.0.1:${cfg.port}/engine`;
    const q = `token=${encodeURIComponent(cfg.token)}`;

    // page -> Sofa, batched per task
    let pending: Upload = { answers: [], events: [] };
    let flushing = false;
    const flush = async (): Promise<void> => {
      if (flushing) return;
      flushing = true;
      try {
        while (pending.answers.length || pending.events.length) {
          const batch = pending;
          pending = { answers: [], events: [] };
          await fetch(`${base}/post?${q}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(batch) })
            .catch(() => { /* Sofa gone: it restarts Firefox */ });
        }
      } finally { flushing = false; }
    };
    page.onMessage.addListener((m) => {
      const msg = m as Answer | { event: string };
      if ('event' in msg) pending.events.push(msg.event); else pending.answers.push(msg);
      setTimeout(() => { void flush(); }, 0);
    });

    // Sofa -> page: long poll while this page is the connected one
    void (async () => {
      let retry = 500;
      while (connected && current === page) {
        try {
          const r = await fetch(`${base}/poll?${q}`, { cache: 'no-store' });
          if (!r.ok) throw new Error(`poll: HTTP ${r.status}`);
          for (const c of await r.json() as Command[]) page.postMessage(c);
          retry = 500;
        } catch {
          await new Promise((res) => setTimeout(res, retry));
          retry = Math.min(POLL_RETRY_MAX_MS, retry * 2);
        }
      }
    })();
  });
});
