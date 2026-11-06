// BotGuard's environment in node: a jsdom window on youtube.com under the identity's user agent, a
// 2d-canvas stub, the interpreter evaluated in-process. Node only - the browser engine runs BotGuard
// in the real youtube.com document (docs/youtube-engine.md).
import type { DOMWindow } from 'jsdom';
import { parseJson } from './json.ts';
import { attest, FETCH_TIMEOUT_MS } from './botguard.ts';
import type { MinterSetup } from './webpo.ts';
import type { Identity } from './identity.ts';

export async function jsdomMinter(identity: Identity): Promise<MinterSetup> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html lang="de-AT"><head><title></title></head><body></body></html>', {
    url: 'https://www.youtube.com', referrer: 'https://www.youtube.com/', userAgent: identity.userAgent,
  });
  const win = dom.window as DOMWindow & { yt?: { config_: unknown } };
  return attest({
    globalObject: globalThis as unknown as Record<string, unknown>,
    // dispose: the renewal (every ~12 h) must not keep the old jsdom window alive (review 2026-11-05)
    dispose: () => { try { dom.window.close(); } catch { /* already closed */ } },
    preparePage(pageHtml) {
      const ytConfig = pageHtml.match(/ytcfg\.set\(({.+?})\);/s)?.[1];
      if (!ytConfig) throw new Error('webpo: ytcfg not found in page');
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
    },
    async loadInterpreter(url) {
      const js = await (await fetch(url, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) })).text();
      if (!js) throw new Error('webpo: empty interpreter');
      new Function(js)(); // eslint-disable-line no-new-func -- BotGuard interpreter (Google's VM)
    },
  });
}
