// A small DOM builder: h('div.tile', {onclick}, child, 'text').

type Child = Node | string | null | undefined | false;
type Props = Record<string, unknown>;

export function h<K extends keyof HTMLElementTagNameMap>(tag: K | `${K}.${string}`, props?: Props | null, ...children: Child[]): HTMLElementTagNameMap[K] {
  const [name, ...classes] = tag.split('.');
  const el = document.createElement(name as K);
  if (classes.length) el.className = classes.join(' ');
  for (const [k, v] of Object.entries(props ?? {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v as EventListener);
    else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
    else if (k === 'dataset' && typeof v === 'object') Object.assign(el.dataset, v);
    else if (k in el && typeof v !== 'string') (el as unknown as Record<string, unknown>)[k] = v;
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  append(el, ...children);
  return el;
}

export function append(el: Element, ...children: Child[]): void {
  for (const c of children) {
    if (c === null || c === undefined || c === false) continue;
    el.append(typeof c === 'string' ? document.createTextNode(c) : c);
  }
}

export function clear(el: Element): void { while (el.firstChild) el.firstChild.remove(); }

// " · " between the non-empty parts (SFDotJoin)
export function dotJoin(...parts: (string | undefined | null | false)[]): string {
  return parts.filter((p): p is string => !!p && p.length > 0).join(' · ');
}

export function formatDuration(secs: number): string {
  const s = Math.max(0, Math.round(secs));
  const hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60;
  const two = (n: number): string => String(n).padStart(2, '0');
  return hh ? `${hh}:${two(mm)}:${two(ss)}` : `${mm}:${two(ss)}`;
}

export function clock(epoch: number): string {
  const d = new Date(epoch * 1000);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

// A 24x24 icon from one SVG path (currentColor)
export function icon(path: string): SVGSVGElement {
  const ns = 'http://www.w3.org/2000/svg';
  const s = document.createElementNS(ns, 'svg');
  s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('aria-hidden', 'true');
  const p = document.createElementNS(ns, 'path');
  p.setAttribute('d', path);
  s.append(p);
  return s;
}

export const ICONS = {
  search: 'M10 3a7 7 0 0 1 5.6 11.2l5.1 5.1-1.4 1.4-5.1-5.1A7 7 0 1 1 10 3zm0 2a5 5 0 1 0 0 10 5 5 0 0 0 0-10z',
  gear: 'M12 8.5a3.5 3.5 0 1 1 0 7 3.5 3.5 0 0 1 0-7zm-1.6-6.5h3.2l.5 2.6c.6.2 1.2.5 1.7.9l2.5-.9 1.6 2.8-2 1.7c.1.6.1 1.3 0 1.9l2 1.7-1.6 2.8-2.5-.9c-.5.4-1.1.7-1.7.9l-.5 2.6h-3.2l-.5-2.6c-.6-.2-1.2-.5-1.7-.9l-2.5.9-1.6-2.8 2-1.7a6 6 0 0 1 0-1.9l-2-1.7 1.6-2.8 2.5.9c.5-.4 1.1-.7 1.7-.9z',
  tv: 'M3 4h18a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1h-8v2h4v2H7v-2h4v-2H3a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zm1 2v10h16V6z',
  play: 'M8 5v14l11-7z',
  pause: 'M6 5h4v14H6zm8 0h4v14h-4z',
  stop: 'M6 6h12v12H6z',
} as const;
