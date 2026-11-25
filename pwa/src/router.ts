// Hash routes (GitHub Pages serves one static page): what a location means, pure.

export type Route =
  | { name: 'home' }
  | { name: 'app'; id: string }
  | { name: 'page'; handle: string; title?: string; theme?: string }
  | { name: 'show'; ref: string; title?: string }
  | { name: 'search'; app: string; q?: string }
  | { name: 'connect' }
  | { name: 'pair' }
  | { name: 'settings' };

export function parseRoute(hash: string): Route {
  const raw = hash.replace(/^#/, '');
  if (!raw.startsWith('/')) return { name: 'home' };   // "#host=..." and the like are no routes
  const [path = '', query = ''] = raw.split('?', 2);
  const parts = path.split('/').filter(Boolean).map(safeDecode);
  const q = new URLSearchParams(query);
  const opt = (k: string): { [key: string]: string } => { const v = q.get(k); return v ? { [k]: v } : {}; };
  switch (parts[0]) {
    case undefined: return { name: 'home' };
    case 'app': return parts[1] ? { name: 'app', id: parts[1] } : { name: 'home' };
    case 'page': return parts[1] ? { name: 'page', handle: parts[1], ...opt('title'), ...opt('theme') } : { name: 'home' };
    case 'show': { const ref = q.get('ref'); return ref ? { name: 'show', ref, ...opt('title') } : { name: 'home' }; }
    case 'search': return parts[1] ? { name: 'search', app: parts[1], ...opt('q') } : { name: 'home' };
    case 'connect': return { name: 'connect' };
    case 'pair': return { name: 'pair' };
    case 'settings': return { name: 'settings' };
    default: return { name: 'home' };
  }
}

export function routeHash(r: Route): string {
  const qs = (o: Record<string, string | undefined>): string => {
    const p = new URLSearchParams();
    for (const [k, v] of Object.entries(o)) if (v) p.set(k, v);
    const s = p.toString();
    return s ? `?${s}` : '';
  };
  switch (r.name) {
    case 'home': return '#/';
    case 'app': return `#/app/${encodeURIComponent(r.id)}`;
    case 'page': return `#/page/${encodeURIComponent(r.handle)}${qs({ title: r.title, theme: r.theme })}`;
    case 'show': return `#/show${qs({ ref: r.ref, title: r.title })}`;
    case 'search': return `#/search/${encodeURIComponent(r.app)}${qs({ q: r.q })}`;
    default: return `#/${r.name}`;
  }
}

function safeDecode(s: string): string { try { return decodeURIComponent(s); } catch { return s; } }
