// BotGuard's environment in the browser engine: the youtube.com document the engine runs in. The
// challenge comes from that page (no second page load), Google's interpreter loads as a <script> the
// way the page loads it (through the engine's Trusted Types policy), and BotGuard's VM sees the real
// window: DOM, canvas, navigator.
import { attest, FETCH_TIMEOUT_MS } from '../lib/botguard.ts';
import type { MinterSetup } from '../lib/webpo.ts';
import { scriptURL } from './trusted.ts';

function loadScript(url: string): Promise<void> {
  return new Promise((ok, bad) => {
    const s = document.createElement('script');
    const timer = setTimeout(() => { s.remove(); bad(new Error('webpo: interpreter load timed out')); }, FETCH_TIMEOUT_MS);
    s.onload = () => { clearTimeout(timer); ok(); };
    s.onerror = () => { clearTimeout(timer); s.remove(); bad(new Error('webpo: interpreter did not load')); };
    s.src = scriptURL(url);   // Trusted Types (trusted.ts)
    document.head.append(s);
  });
}

/**
 * The page's markup once it is parsed: the challenge sits in a script late in the document, and the
 * engine may start as soon as ytcfg exists (measured 2026-11-07: a page from a warm profile started
 * the engine mid-parse - "challenge not found in page").
 */
async function parsedPage(): Promise<string> {
  if (document.readyState === 'loading') await new Promise<void>((ok) => document.addEventListener('DOMContentLoaded', () => ok(), { once: true }));
  return document.documentElement.outerHTML;
}

export function documentMinter(): Promise<MinterSetup> {
  return attest({
    globalObject: globalThis as unknown as Record<string, unknown>,
    page: parsedPage,
    loadInterpreter: loadScript,
  });
}
