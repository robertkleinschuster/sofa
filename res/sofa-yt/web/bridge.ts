// The extension's content script in the isolated world (document_start): joins the engine page's
// private MessagePort (page-main.ts) to the extension's background (background.ts) over a
// runtime.Port. Both ends are private: the page's own scripts see neither. Network traffic to Sofa
// is the background's - a content script's request would be the page's (CORS, page-visible).
import { HELLO } from './protocol.ts';

interface RuntimePort {
  postMessage(m: unknown): void;
  onMessage: { addListener(f: (m: unknown) => void): void };
  onDisconnect: { addListener(f: () => void): void };
}
declare const browser: { runtime: { connect(info: { name: string }): RuntimePort } };

function receivePort(): Promise<MessagePort> {
  return new Promise((ok) => {
    const take = (e: MessageEvent): void => {
      if (e.source !== window || typeof e.data !== 'object' || e.data === null || !(HELLO in e.data) || !e.ports[0]) return;
      e.stopImmediatePropagation();
      window.removeEventListener('message', take, true);
      ok(e.ports[0]);
    };
    window.addEventListener('message', take, true);
  });
}

if (window === window.top) {
  void receivePort().then((page) => {
    const ext = browser.runtime.connect({ name: 'engine' });
    page.onmessage = (e: MessageEvent) => ext.postMessage(e.data);
    ext.onMessage.addListener((m) => page.postMessage(m));
    ext.onDisconnect.addListener(() => page.close());
  });
}
