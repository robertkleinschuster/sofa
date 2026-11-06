// The Innertube session of the browser engine: youtubei.js' web build inside the youtube.com page.
// The browser is the identity (user agent, TLS, cookies, languages); the context comes from the
// page's own ytcfg, so InnerTube requests carry what YouTube's page sends (docs/youtube-engine.md).
import { Innertube, UniversalCache, Platform, Log } from 'youtubei.js/web';
import type { SessionFactory } from '../lib/youtube.ts';
import { pageClient, pageString } from './page.ts';
import { compile } from './trusted.ts';

/**
 * youtubei.js sets "Accept-Language: *" on every InnerTube request; YouTube's page sends none of its
 * own, so the browser's configured languages go out. Drop it and let the browser fill in its own.
 */
const pageFetch: typeof fetch = (input, init) => {
  const req = new Request(input, init);
  req.headers.delete('accept-language');
  return fetch(req);
};

export function pageSessions(): SessionFactory {
  return {
    headers: {},   // the browser sends its own
    async create(visitor) {
      Log.setLevel(Log.Level.ERROR);
      // the n/sig transforms of the player, compiled through the engine's Trusted Types policy
      Platform.shim.eval = async (data) => compile(data.output)() as Record<string, unknown> | undefined;
      const yt = await Innertube.create({
        fetch: pageFetch,
        cache: new UniversalCache(true),   // player.js in IndexedDB of the profile
        enable_session_cache: false,
        // the visitor the page's cookie holds wins over the stored one
        visitor_data: pageString('VISITOR_DATA') || visitor,
        retrieve_player: true,
        user_agent: navigator.userAgent,
        lang: pageString('HL') || undefined,
        location: pageString('GL') || undefined,
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      });
      // the page's client context (browser, OS, client version, screen) as YouTube's player sends it
      Object.assign(yt.session.context.client, pageClient());
      return yt;
    },
  };
}
