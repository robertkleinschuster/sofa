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
