// Tiles as the TV draws them (src/Framework/SFTile.m): picture with badge, duration, chip, progress;
// title and a dim line below, with the channel's or station's round avatar. Same item, same box:
// a tile is re-rendered in place when its state changes, so nothing moves.

import type { Api } from './api.ts';
import { clock, dotJoin, formatDuration, h, icon, ICONS } from './dom.ts';
import { hasMark, logoURL, markURL } from './logos.ts';
import type { Item, TileStyle } from './types.ts';

export interface TileHost {
  api: Api;
  activate(item: Item, tile: HTMLElement): void;
  menu(item: Item, tile: HTMLElement): void;
}

// CSS width of a style's picture (for the image size asked of Sofa); matches tiles.css.
const CSS_WIDTH: Record<TileStyle, number> = { landscape: 320, poster: 200, circle: 160, app: 270, wide: 460, button: 0 };

const LIVE_RED = '#e5162a';

// Tiles on screen by item id, to update every copy of an item (it can be in several rails).
const live = new Map<string, Set<HTMLElement>>();
const itemOf = new WeakMap<HTMLElement, { item: Item; style: TileStyle; host: TileHost }>();

export function hasMenu(item: Item): boolean {
  return item.kind === 'video' || (item.kind === 'folder' && item.following !== undefined) || (item.kind === 'live' && !!item.id);
}

export function tile(item: Item, shelfStyle: TileStyle, host: TileHost): HTMLElement {
  const style = item.style ?? shelfStyle;
  const el = build(item, style, host);
  itemOf.set(el, { item, style, host });
  if (item.id) {
    let set = live.get(item.id);
    if (!set) live.set(item.id, set = new Set());
    set.add(el);
  }
  return el;
}

// After a mark, a playback or a download step: every tile of this item gets the new state. A change
// of the chip alone (a download's progress) is written into the tile as it is - nothing is rebuilt, so
// the picture does not fade in again (no blinking every few seconds).
export function updateTiles(item: Item): void {
  if (!item.id) return;
  const set = live.get(item.id);
  if (!set) return;
  for (const el of [...set]) {
    if (!el.isConnected) { set.delete(el); continue; }
    const info = itemOf.get(el);
    if (!info) continue;
    // keep what only the page knew (a page handle is per answer), take the new state
    const merged: Item = { ...info.item, ...pickState(item) };
    if (onlyChipChanged(info.item, merged)) {
      itemOf.set(el, { ...info, item: merged });
      setChip(el, merged, info.style);
      continue;
    }
    const fresh = tile(merged, info.style, info.host);
    el.replaceWith(fresh);
    set.delete(el);
  }
}

function pickState(i: Item): Partial<Item> {
  const out: Partial<Item> = { watched: !!i.watched, later: !!i.later, chip: i.chip, dl: i.dl };
  if (i.progress !== undefined) out.progress = i.progress; else out.progress = 0;
  if (i.following !== undefined) out.following = i.following;
  return out;
}

function onlyChipChanged(a: Item, b: Item): boolean {
  return !!a.watched === !!b.watched && !!a.later === !!b.later && (a.progress ?? 0) === (b.progress ?? 0) && a.following === b.following;
}

function setChip(el: HTMLElement, item: Item, style: TileStyle): void {
  const art = el.querySelector('.art');
  if (!art) return;
  let chip = art.querySelector<HTMLElement>('.chip');
  if (!item.chip || style !== 'landscape') { chip?.remove(); return; }
  if (!chip) { chip = h('span.chip'); art.append(chip); }
  chip.textContent = item.chip;
}

export function forgetTiles(): void { live.clear(); }

function build(item: Item, style: TileStyle, host: TileHost): HTMLElement {
  const disabled = item.kind === 'video' && item.drm;
  const el = h('div.tile', { role: 'listitem', dataset: { style, kind: item.kind, ...(item.id ? { id: item.id } : {}) } });
  const now = (): Item => itemOf.get(el)?.item ?? item;   // the state it has now (updateTiles may have patched it)
  if (disabled) el.classList.add('drm');
  const art = h('button.art', {
    type: 'button',
    'aria-label': spokenLabel(item),
    onclick: () => host.activate(now(), el),
  });
  if (item.tint) art.style.setProperty('--tint', item.tint);
  el.append(art);

  if (style === 'button') {
    art.append(h('span.button-label', null, item.title ?? ''));
    return el;
  }
  if (style === 'app') appArt(art, item);
  else if (style === 'wide') wideArt(art, item, host);
  else picture(art, item, style, host);

  if (item.badge) {
    const b = h('span.badge', null, item.badge);
    if (item.badge === 'LIVE') b.style.background = LIVE_RED;
    art.append(b);
  }
  if (style === 'landscape' && item.duration && item.duration > 0) art.append(h('span.duration', null, formatDuration(item.duration)));
  if (style === 'landscape' && item.chip) art.append(h('span.chip', null, item.chip));
  if (item.watched) art.append(h('span.watched', { title: 'Gesehen', 'aria-label': 'Gesehen' }, icon(ICONS.check)));
  if ((style === 'landscape' || style === 'poster') && item.progress && item.progress > 0 && !item.watched) {
    const bar = h('span.progress', null, h('span', { style: { width: `${Math.round(item.progress * 1000) / 10}%` } }));
    art.append(bar);
  }
  if (disabled) art.append(h('span.drm-note', null, 'Kopiergeschützt'));

  // app and wide tiles carry their text in the picture (the TV's SFTile: no text below them)
  if (style !== 'wide' && style !== 'app') el.append(meta(item, style, host));
  if (hasMenu(item)) {
    el.append(h('button.more', { type: 'button', 'aria-label': 'Optionen', title: 'Optionen', onclick: (e: Event) => { e.stopPropagation(); host.menu(now(), el); } }, icon(ICONS.more)));
  }
  return el;
}

// What a screen reader says for the tile: its text and the state the picture shows
function spokenLabel(item: Item): string {
  const seen = item.watched ? 'gesehen' : item.progress && item.progress > 0 ? `zu ${Math.round(item.progress * 100)} % gesehen` : null;
  return dotJoin(item.badge === 'LIVE' ? 'Live' : null, item.title, item.sub,
    item.duration && item.duration > 0 ? formatDuration(item.duration) : null, seen, item.chip?.replace(/^↓\s*/, 'Download: '));
}

function picture(art: HTMLElement, item: Item, style: TileStyle, host: TileHost): void {
  const src = host.api.image(item.img, CSS_WIDTH[style]);
  const fallback = host.api.image(item.imgFallback, CSS_WIDTH[style]);
  if (!src && !fallback) { placeholder(art, item); return; }
  const img = h('img', { alt: '', loading: 'lazy', decoding: 'async', draggable: false });
  if (item.fit) img.classList.add('fit');
  img.addEventListener('load', () => img.classList.add('loaded'));
  img.addEventListener('error', () => {
    if (fallback && img.src !== fallback) img.src = fallback;
    else { img.remove(); placeholder(art, item); }
  });
  img.src = src ?? fallback!;
  art.prepend(img);
}

// No picture: the tint or the surface with the title, as the TV's empty tiles
function placeholder(art: HTMLElement, item: Item): void {
  if (art.querySelector('.placeholder')) return;
  art.prepend(h('span.placeholder', null, item.title ?? ''));
}

function appArt(art: HTMLElement, item: Item): void {
  art.classList.add('app-art');
  if (item.logo) {
    const img = h('img.logo', { alt: item.title ?? '' });
    void logoURL(item.logo, item.logoVariant ?? 0).then((u) => {
      if (u) { img.src = u; } else { img.replaceWith(h('span.wordmark', null, item.title ?? '')); }
    });
    art.append(img);
  } else {
    art.append(h('span.wordmark', { style: item.title && item.title.length > 9 ? { fontSize: '1.5em' } : {} }, item.title ?? ''));
    if (item.sub) art.append(h('span.app-sub', null, item.sub));
  }
}

function wideArt(art: HTMLElement, item: Item, host: TileHost): void {
  art.classList.add('wide-art');
  const src = host.api.image(item.img, CSS_WIDTH.wide);
  if (src) {
    const img = h('img', { alt: '', loading: 'lazy', decoding: 'async' });
    img.addEventListener('load', () => img.classList.add('loaded'));
    img.addEventListener('error', () => img.remove());
    img.src = src;
    art.append(img);
    art.classList.add('with-picture');
  }
  art.append(h('span.wide-title', null, item.title ?? ''));
}

function meta(item: Item, style: TileStyle, host: TileHost): HTMLElement {
  const center = style === 'circle' || style === 'poster';
  const m = h('div.meta', center ? { class: 'meta center' } : null);
  if (item.title) m.append(h('div.title', null, item.title));
  // live channel with a programme: what runs now instead of the static line
  const sub = item.kind === 'live' && item.now ? dotJoin(item.now.title, `bis ${clock(item.now.end)}`) : item.sub;
  let avatar: string | undefined;
  if (!center) {
    if (item.kind === 'video' && item.channelImg && item.channel && sub?.startsWith(item.channel)) avatar = host.api.image(item.channelImg, 34);
    else if (item.kind === 'video' && hasMark(item.station)) avatar = markURL(item.station!);
    else if (item.mark && item.kind !== 'live' && hasMark(item.source)) avatar = markURL(item.source!);
  }
  if (sub || avatar) {
    const line = h('div.sub');
    if (avatar) {
      const a = h('img.avatar', { alt: '', loading: 'lazy' });
      a.addEventListener('error', () => a.remove());
      a.src = avatar;
      line.append(a);
    }
    if (sub) line.append(h('span', null, sub));
    m.append(line);
  }
  return m;
}
