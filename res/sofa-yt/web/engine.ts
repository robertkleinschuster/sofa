// Sofa's YouTube engine in Firefox (docs/youtube-engine.md): bundled by tools/build-yt-engine into
// build/sofa-yt-web/engine.js and injected into a hidden youtube.com tab. Sofa calls
// globalThis.sofaEngine over WebDriver BiDi. Migration step 1: the bundle and its libraries load in
// the browser (youtubei.js web build, googlevideo SABR, BotGuard/WebPO in the real DOM); the API of
// docs/youtube-engine.md grows here as the sidecar's modules move over.
import { Innertube } from 'youtubei.js/web';
import { SabrStream } from 'googlevideo/sabr-stream';
import { BotGuardClient } from 'bgutils-js/botguard';
import { WebPoMinter } from 'bgutils-js/webpo';
import { PlaybackSession } from '../lib/session.ts';
import { startSabrPump } from '../lib/sabrpump.ts';
import { describeFormats } from '../lib/formats.ts';
import { parseIndex } from '../lib/mediaindex.ts';

/** What Sofa can ask the engine (BiDi script.callFunction on globalThis.sofaEngine). */
export interface SofaEngine {
  /** The engine's libraries are usable in this page. */
  health(): { libraries: boolean; userAgent: string; origin: string };
}

const engine: SofaEngine = {
  health: () => ({
    libraries: [Innertube, SabrStream, BotGuardClient, WebPoMinter, PlaybackSession, startSabrPump, describeFormats, parseIndex]
      .every((c) => typeof c === 'function'),
    userAgent: navigator.userAgent,
    origin: location.origin,
  }),
};

(globalThis as typeof globalThis & { sofaEngine?: SofaEngine }).sofaEngine = engine;
