// SABR pumps for the engine's sessions: a pre-minted video-bound PO token per video (reused for
// restarts within 30 min, dropped when SABR rejects it), and the reload path through YouTube (breaker,
// budget). Runtime-neutral: the browser engine and the tests wire the same factory.
import type { ReloadPlaybackContext } from 'googlevideo/protos';
import { errorMessage, toError } from './errors.ts';
import { log } from './log.ts';
import { startSabrPump } from './sabrpump.ts';
import type { PumpHandle } from './session.ts';
import type { EngineStartPump } from './engine.ts';
import type { PoTokenProvider } from './webpo.ts';
import type { YouTube } from './youtube.ts';

const TOKEN_REUSE_MS = 30 * 60 * 1000;
const TOKEN_CACHE_MAX = 32;

export function sabrPumps({ youtube, po }: { youtube: Pick<YouTube, 'reload' | 'cached'>; po: Pick<PoTokenProvider, 'mintString' | 'mintBytes' | 'renew'> }): EngineStartPump {
  async function preMint(videoId: string): Promise<string | undefined> {
    const t0 = Date.now();
    try {
      return await po.mintString(videoId);
    } catch (e) { log('PO token for SABR unavailable:', errorMessage(e)); return undefined; } finally {
      // a start waits for it: where a slow start's seconds go
      if (Date.now() - t0 > 500) log(`PO token for ${videoId}: ${Date.now() - t0} ms`);
    }
  }
  const tokenCache = new Map<string, { token: string; at: number }>(); // videoId -> one pre-minted token per video, reused for restarts
  return (info, formats, opts) => {
    let handle: PumpHandle | null = null;
    let aborted = false;
    const tc = tokenCache.get(info.id);
    const launch = (poToken: string | undefined): void => {
      if (aborted) return;
      try {
        handle = startSabrPump({
          ...opts, info, formats, poToken,
          mintPoToken: () => po.mintBytes(info.id),
          // a rejected token must not start the next run again; a fresh attestation for new ones
          onTokenRejected: () => { tokenCache.delete(info.id); po.renew(); },
          reload: async (ctx?: ReloadPlaybackContext) => {
            const r = await youtube.reload(info.id, ctx, { bg: !!opts.bg });
            // the session keeps the info object: point it at the fresh URL for future runs
            const fresh = youtube.cached(info.id);
            if (fresh && fresh.kind !== 'hls') { info.sabrUrl = fresh.sabrUrl; info.ustreamer = fresh.ustreamer; info.expires = fresh.expires; }
            return r;
          },
        });
      } catch (e) {
        opts.onEnd(toError(e), 'error');
      }
    };
    if (tc && Date.now() - tc.at < TOKEN_REUSE_MS) launch(tc.token);
    else {
      preMint(info.id).then((token) => {
        if (token) {
          if (tokenCache.size > TOKEN_CACHE_MAX) tokenCache.delete(tokenCache.keys().next().value!); // bounded
          tokenCache.set(info.id, { token, at: Date.now() });
        }
        launch(token);
      });
    }
    // diag: what SABR's server last said (stall reports); the wrapper must pass it on
    return { abort() { aborted = true; handle?.abort(); }, diag: () => handle?.diag?.() ?? '[waiting for the PO token]' };
  };
}
