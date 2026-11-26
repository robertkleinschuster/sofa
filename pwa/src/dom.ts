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

// A 24x24 icon from one SVG path (currentColor; even-odd, so a ring's inside stays open)
export function icon(path: string): SVGSVGElement {
  const ns = 'http://www.w3.org/2000/svg';
  const s = document.createElementNS(ns, 'svg');
  s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('aria-hidden', 'true'); s.setAttribute('class', 'icon');
  const p = document.createElementNS(ns, 'path');
  p.setAttribute('d', path); p.setAttribute('fill-rule', 'evenodd');
  s.append(p);
  return s;
}

export const ICONS = {
  search: 'M10 3a7 7 0 0 1 5.6 11.2l5.1 5.1-1.4 1.4-5.1-5.1A7 7 0 1 1 10 3zm0 2a5 5 0 1 0 0 10 5 5 0 0 0 0-10z',
  gear: 'M10.3 2h3.4l.5 2.7c.7.3 1.3.6 1.9 1.1l2.6-.9 1.7 2.9-2.1 1.8a7 7 0 0 1 0 2.2l2.1 1.8-1.7 2.9-2.6-.9c-.6.5-1.2.8-1.9 1.1l-.5 2.7h-3.4l-.5-2.7c-.7-.3-1.3-.6-1.9-1.1l-2.6.9-1.7-2.9 2.1-1.8a7 7 0 0 1 0-2.2L3.6 7.8l1.7-2.9 2.6.9c.6-.5 1.2-.8 1.9-1.1zM12 8.8a3.2 3.2 0 1 0 0 6.4 3.2 3.2 0 0 0 0-6.4z',
  back: 'M15.4 4.6 8 12l7.4 7.4-1.4 1.4L5.2 12 14 3.2z',
  next: 'M8.6 4.6 16 12l-7.4 7.4 1.4 1.4 8.8-8.8L10 3.2z',
  more: 'M5 10a2 2 0 1 1 0 4 2 2 0 0 1 0-4zm7 0a2 2 0 1 1 0 4 2 2 0 0 1 0-4zm7 0a2 2 0 1 1 0 4 2 2 0 0 1 0-4z',
  close: 'M6.4 5 12 10.6 17.6 5 19 6.4 13.4 12l5.6 5.6-1.4 1.4-5.6-5.6L6.4 19 5 17.6 10.6 12 5 6.4z',
  check: 'M9.5 15.6 5.4 11.5 4 12.9l5.5 5.5L20 7.9l-1.4-1.4z',
  offline: 'M12 2a10 10 0 1 1 0 20 10 10 0 0 1 0-20zm0 2a8 8 0 0 0-6.3 12.9L16.9 5.7A8 8 0 0 0 12 4zm6.3 3.1L7.1 18.3A8 8 0 0 0 18.3 7.1z',
  tv: 'M3 4h18a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1h-8v2h4v2H7v-2h4v-2H3a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zm1 2v10h16V6z',
  play: 'M8 5v14l11-7z',
  pause: 'M6 5h4v14H6zm8 0h4v14h-4z',
  stop: 'M6 6h12v12H6z',
} as const;
