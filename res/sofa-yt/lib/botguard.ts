// BotGuard attestation -> WebPO minter, like YouTube's web player: the youtube.com page's challenge,
// Google's interpreter, the BotGuard snapshot, GenerateIT, then a minter for video-bound tokens.
// Runtime-neutral: what differs (a jsdom window in node, the real youtube.com document in the browser
// engine - docs/youtube-engine.md) comes in as an AttestEnv.
import type { WebPoSignalOutput } from 'bgutils-js/shared-types';
import { BotGuardClient } from 'bgutils-js/botguard';
import { WebPoMinter } from 'bgutils-js/webpo';
import { getHeaders, buildURL, parseLooseJSON } from 'bgutils-js/utils';
import { isRecord, optNumber, optString } from './json.ts';
import { log } from './log.ts';
import type { MinterSetup } from './webpo.ts';

/** Where BotGuard runs. */
export interface AttestEnv {
  /** Make the page's globals ready for BotGuard (node: a jsdom window with the page's ytcfg). */
  preparePage(pageHtml: string): void;
  /** Run Google's interpreter so its global exists (node: evaluate it; browser: load it as the page does). */
  loadInterpreter(url: string): Promise<void>;
  /** The global object BotGuard's VM lives in. */
  globalObject: Record<string, unknown>;
  dispose?: () => void;
}

/** The parts of youtube.com's BotGuard challenge (window.ytAtN(...)) used here. */
interface PageChallenge {
  bgChallenge?: {
    interpreterUrl: { privateDoNotAccessOrElseTrustedResourceUrlWrappedValue: string };
    program: string;
    globalName: string;
  };
}

export const FETCH_TIMEOUT_MS = 15000;

export async function attest(env: AttestEnv): Promise<MinterSetup> {
  const t0 = performance.now();
  const sig = () => AbortSignal.timeout(FETCH_TIMEOUT_MS);
  try {
    const pageHtml = await (await fetch('https://www.youtube.com', {
      headers: { accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' }, signal: sig(),
    })).text();
    env.preparePage(pageHtml);
    const att = pageHtml.match(/window\.ytAtN\(\s*({[\s\S]*?})\s*\)/);
    if (!att) throw new Error('webpo: challenge not found in page');
    const loose: unknown = parseLooseJSON(att[1]!).R;
    const challenge = isRecord(loose) ? (loose as PageChallenge) : null;   // BotGuard validates the rest
    if (!challenge?.bgChallenge) throw new Error('webpo: no bgChallenge');
    await env.loadInterpreter(`https:${challenge.bgChallenge.interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue}`);

    const bg = await BotGuardClient.create({ program: challenge.bgChallenge.program,
      globalName: challenge.bgChallenge.globalName, globalObject: env.globalObject });
    const webPoSignalOutput: WebPoSignalOutput = [];
    const bgResponse = await bg.snapshot({ webPoSignalOutput });
    const itRes = await fetch(buildURL('GenerateIT', true), { method: 'POST', headers: getHeaders(),
      body: JSON.stringify(['O43z0dpjhgX20SCx4KAo', bgResponse]), signal: sig() });
    if (!itRes.ok) throw new Error(`webpo: GenerateIT HTTP ${itRes.status}`);
    const it: unknown = await itRes.json();
    const [integrityToken, estimatedTtlSecs, mintRefreshThreshold, websafeFallbackToken] = Array.isArray(it) ? it : [];
    if (typeof integrityToken !== 'string' || !integrityToken) throw new Error('webpo: no integrity token');
    const minter = await WebPoMinter.create({ integrityToken, estimatedTtlSecs: optNumber(estimatedTtlSecs),
      mintRefreshThreshold: optNumber(mintRefreshThreshold), websafeFallbackToken: optString(websafeFallbackToken) },
      webPoSignalOutput);
    log(`webpo: integrity token ttl=${estimatedTtlSecs}s, setup ${(performance.now() - t0).toFixed(0)} ms`);
    return { minter, dispose: env.dispose, ttlMs: (Number(estimatedTtlSecs) || 3600) * 1000, refreshMs: (Number(mintRefreshThreshold) || 100) * 1000 };
  } catch (e) {
    env.dispose?.();
    throw e;
  }
}
