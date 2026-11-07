// What the youtube.com page the engine runs in already knows: its ytcfg (YouTube's own configuration
// for this browser - InnerTube context, language, region, visitor). The engine takes these instead
// of choosing its own, so its requests carry what the page's would.
import { isRecord } from '../lib/json.ts';

interface YtCfg { get(key: string): unknown }

function ytcfg(): YtCfg | null {
  const c = (globalThis as { ytcfg?: unknown }).ytcfg;
  return isRecord(c) && typeof c.get === 'function' ? (c as unknown as YtCfg) : null;
}

/** A ytcfg value as it is (undefined when the page has none). */
export function pageValue(key: string): unknown {
  return ytcfg()?.get(key);
}

/** A ytcfg value as a string ('' when the page has none). */
export function pageString(key: string): string {
  const v = ytcfg()?.get(key);
  return typeof v === 'string' ? v : '';
}

/** The page's InnerTube client context (INNERTUBE_CONTEXT.client), {} without one. */
export function pageClient(): Record<string, unknown> {
  const ctx = ytcfg()?.get('INNERTUBE_CONTEXT');
  return isRecord(ctx) && isRecord(ctx.client) ? ctx.client : {};
}

/** The engine runs in a youtube.com page with YouTube's configuration loaded. */
export function onYouTubePage(): boolean {
  return location.origin === 'https://www.youtube.com' && !!ytcfg();
}
