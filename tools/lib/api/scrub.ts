// Recorded answers as examples for api/examples/: everything that differs between runs or machines is
// replaced by a stable placeholder - tokens, ids, handles, signatures, ports, times, the disk's free
// space, a download's moving progress, Sofa's version - so a run that changes nothing in the API writes
// the same files (git shows a diff only when the API changed). Pure.

export interface ScrubContext { name: string; port: number; tmp: string }

const HEX64 = /^[0-9a-f]{64}$/, HEX32 = /^[0-9a-f]{32}$/, HEX16 = /^[0-9a-f]{16}$/;
export const EXAMPLE_HOST = 'sofa.tailnet.example';

function scrubString(s: string, key: string, ctx: ScrubContext): string {
  if (HEX64.test(s)) return '<token>';
  if (key === 'device' && HEX16.test(s)) return '<device>';
  if (key === 'stream' && HEX32.test(s)) return '<stream>';
  if ((key === 'page' || key === 'more') && HEX32.test(s)) return '<handle>';
  if (key === 'gen') return '<gen>';
  let out = s
    .replace(/\/m\/[0-9a-f]{32}\//g, '/m/<stream>/')
    .replace(/\/img\/[0-9a-f]{32}\?/g, '/img/<signature>?')
    .split(encodeURIComponent(ctx.tmp)).join(encodeURIComponent('/tmp/sofa-api'))
    .split(ctx.tmp).join('/tmp/sofa-api')
    .split(`${ctx.name}:${ctx.port}`).join(`${EXAMPLE_HOST}:7443`)
    .replace(/127\.0\.0\.1:[0-9]+/g, '127.0.0.1:8000')
    .replace(/[0-9]+(?:[.,][0-9]+)? (MB|GB|TB) (belegt|frei)/g, (_m, unit: string, what: string) => `${what === 'frei' ? '100' : '12'} ${unit} ${what}`)
    .replace(/↓ [0-9]+ %/g, '↓ 50 %');
  if (key === 'message') out = out.replace(/[0-9]+(?:[.,][0-9]+)? (MB|GB)/g, '340 $1');
  if (s === ctx.name) out = EXAMPLE_HOST;
  return out;
}

export function scrub(v: unknown, ctx: ScrubContext, key = '', parent: Record<string, unknown> | null = null): unknown {
  // the TV's player as an answer caught it (opening, playing, paused): shown playing
  if (typeof v === 'string' && key === 'state' && parent && 'item' in parent && 'position' in parent) return 'playing';
  if (typeof v === 'string') return scrubString(v, key, ctx);
  if (typeof v === 'number') {
    if (key === 'port') return 7443;
    // a programme's times (now/next): fixed, an hour long
    if ((key === 'start' || key === 'end') && parent && 'start' in parent && 'end' in parent) return key === 'start' ? 1800000000 : 1800003600;
    if (key === 'date' || key === 'paired' || key === 'seen') return 1800000000;
    if (key === 'progress' && parent && 'state' in parent) return 0.5;   // a running download's
    if (key === 'position' && parent && 'state' in parent && 'item' in parent) return 12;   // the TV's player, still moving
    if (key === 'duration' && parent && 'position' in parent && 'item' in parent) {   // not known yet while it opens: the item's
      const d = (parent.item as Record<string, unknown> | null)?.duration;
      return typeof d === 'number' ? d : v;
    }
    return v;
  }
  if (Array.isArray(v)) return v.map((x) => scrub(x, ctx, key, parent));
  if (v && typeof v === 'object') {
    const o = v as Record<string, unknown>, out: Record<string, unknown> = {};
    for (const k of Object.keys(o).sort()) {
      if (key === '' && k === 'version' && 'features' in o) { out[k] = '0.0.0'; continue; }   // Sofa's version in hello
      out[k] = scrub(o[k], ctx, k, o);
    }
    return out;
  }
  return v;
}
