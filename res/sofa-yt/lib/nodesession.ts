// The Innertube session of the node sidecar: youtubei.js' node build under the Chrome identity of
// identity.ts (user agent, client hints, Austria). Node only - in the browser engine the browser
// itself is the identity (docs/youtube-engine.md).
import path from 'node:path';
import { LANG, LOCATION, TIMEZONE, browserContext } from './identity.ts';
import type { Identity } from './identity.ts';
import type { SessionFactory } from './youtube.ts';

export function nodeSessions(identity: Identity, stateDir: string): SessionFactory {
  return {
    headers: identity.headers,
    async create(visitor) {
      const { Innertube, UniversalCache, Platform, Log } = await import('youtubei.js');
      Log.setLevel(Log.Level.ERROR);
      // youtubei.js 18 ships no JS evaluator for node; the n/sig transforms need one.
      Platform.shim.eval = async (data) => new Function(data.output)() as Record<string, unknown> | undefined; // eslint-disable-line no-new-func
      const yt = await Innertube.create({
        cache: new UniversalCache(true, path.join(stateDir, 'ytjs-cache')), // player.js
        // No cached session: youtubei.js would restore the old context (browser/OS fields of the UA
        // it was made with) and pin clientVersion to its built-in constant. Fresh, like a page load:
        // sw.js_data gives the current clientVersion and YouTube's reading of our UA. Only the
        // visitor stays, as the browser's cookie does.
        enable_session_cache: false,
        visitor_data: visitor,
        retrieve_player: true,
        user_agent: identity.userAgent, // the one browser identity (identity.ts), also BotGuard's
        lang: LANG, location: LOCATION, timezone: TIMEZONE,
      });
      // sw.js_data no longer names the browser (2026-11-06: undefined); the page's own context
      // carries it - the identity's, not a guess
      const bc = browserContext(identity);
      yt.session.context.client.browserName ||= bc.browserName;
      yt.session.context.client.browserVersion ||= bc.browserVersion;
      return yt;
    },
  };
}
