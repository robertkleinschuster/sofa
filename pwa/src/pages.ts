// A Sofa page (SFPage: shelves of tiles) in the browser: rails scroll sideways, grids wrap; a
// shelf with `more` loads its next portion when its end comes into view, appended at the end so
// nothing on screen moves.

import type { Api } from './api.ts';
import { h } from './dom.ts';
import { tile, type TileHost } from './tiles.ts';
import type { Page, Shelf } from './types.ts';

export function renderPage(page: Page, host: TileHost, opts: { showTitle: boolean }): HTMLElement {
  const root = h('div.page');
  if (page.backdrop) {
    const back = h('div.backdrop');
    const img = h('img', { alt: '', decoding: 'async' });
    img.addEventListener('load', () => img.classList.add('loaded'));
    img.addEventListener('error', () => back.remove());
    img.src = host.api.image(page.backdrop, Math.min(1920, globalThis.innerWidth || 1280)) ?? '';
    back.append(img);
    root.append(back);
  }
  if (opts.showTitle && (page.title || page.subtitle)) {
    root.append(h('header.page-head', null,
      page.title ? h('h1', null, page.title) : null,
      page.subtitle ? h('p.page-sub', null, page.subtitle) : null));
  }
  const shelves = page.shelves.filter((s) => s.items.length || s.more);
  if (!shelves.length) root.append(h('p.empty', null, page.empty ?? 'Hier ist gerade nichts.'));
  for (const s of shelves) root.append(renderShelf(s, host));
  return root;
}

function renderShelf(shelf: Shelf, host: TileHost): HTMLElement {
  const sec = h('section.shelf', { dataset: { layout: shelf.layout, style: shelf.style } });
  if (shelf.title) sec.append(h('h2.shelf-title', null, shelf.title));
  const list = h('div.tiles', { role: 'list' });
  for (const item of shelf.items) list.append(tile(item, shelf.style, host));
  sec.append(list);
  if (shelf.layout === 'rail') addRailButtons(sec, list);
  if (shelf.more) loadMoreAtEnd(shelf.more, shelf, list, host.api, host);
  if (shelf.layout === 'rail' && shelf.focus) {
    // the TV starts this rail at a tile (e.g. "today" in a schedule): scroll it into view once laid out
    requestAnimationFrame(() => {
      const t = list.children[shelf.focus!] as HTMLElement | undefined;
      if (t) list.scrollLeft = t.offsetLeft - list.offsetLeft;
    });
  }
  return sec;
}

// Desktop: arrows at the rail's sides (a mouse has no sideways swipe); touch screens swipe.
function addRailButtons(sec: HTMLElement, list: HTMLElement): void {
  const step = (dir: number): void => list.scrollBy({ left: dir * list.clientWidth * 0.85, behavior: 'smooth' });
  const prev = h('button.rail-arrow.prev', { type: 'button', 'aria-label': 'Zurück blättern', onclick: () => step(-1) }, '‹');
  const next = h('button.rail-arrow.next', { type: 'button', 'aria-label': 'Weiter blättern', onclick: () => step(1) }, '›');
  const update = (): void => {
    prev.hidden = list.scrollLeft <= 4;
    next.hidden = list.scrollLeft + list.clientWidth >= list.scrollWidth - 4;
  };
  list.addEventListener('scroll', update, { passive: true });
  requestAnimationFrame(update);
  new ResizeObserver(update).observe(list);
  sec.append(prev, next);
}

function loadMoreAtEnd(handle: string, shelf: Shelf, list: HTMLElement, api: Api, host: TileHost): void {
  const sentinel = h('div.more-sentinel', { 'aria-hidden': 'true' });
  list.append(sentinel);
  let busy = false, failures = 0;
  const io = new IntersectionObserver((entries) => {
    if (!entries.some((e) => e.isIntersecting) || busy) return;
    busy = true;
    sentinel.classList.add('loading');
    api.more(handle).then((answer) => {
      for (const item of answer.items) sentinel.before(tile(item, shelf.style, host));
      if (!answer.more || !answer.items.length) { io.disconnect(); sentinel.remove(); }
    }).catch(() => {
      // a gone list (410) or repeated failures end it; the rest stays as loaded
      if (++failures >= 3) { io.disconnect(); sentinel.remove(); }
    }).finally(() => {
      busy = false;
      sentinel.classList.remove('loading');
      // still in view (a short portion): ask again
      if (sentinel.isConnected) { io.unobserve(sentinel); io.observe(sentinel); }
    });
  }, { root: shelf.layout === 'rail' ? list : null, rootMargin: '0px 600px 600px 0px' });
  io.observe(sentinel);
}
