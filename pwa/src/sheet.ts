// The item's sheet (⋯ on a tile): what the TV's menu offers - play, from the start, Später ansehen,
// gesehen, aus Weiterschauen entfernen, zur Sendung, folgen - with the item's text.

import { clock, dotJoin, h } from './dom.ts';
import { resumeLabel } from './player.ts';
import type { Item } from './types.ts';

export interface SheetActions {
  play(item: Item, fromStart: boolean): void;
  mark(item: Item, change: { watched?: boolean; later?: boolean; follow?: boolean; forget?: boolean }): Promise<void>;
  open(item: Item): void;          // a folder's page
  openShow(item: Item): void;      // the show a video belongs to
  imageURL(path: string | undefined, width: number): string | undefined;
}

let current: { el: HTMLElement; done: () => void } | null = null;

export function closeSheet(): boolean {
  if (!current) return false;
  current.done();
  return true;
}

export function openSheet(item: Item, actions: SheetActions, returnFocus?: HTMLElement): void {
  closeSheet();
  const close = (): void => {
    el.classList.remove('open');
    setTimeout(() => el.remove(), 200);
    removeEventListener('keydown', onKey);
    current = null;
    returnFocus?.querySelector<HTMLElement>('.more')?.focus({ preventScroll: true });
  };
  const onKey = (e: KeyboardEvent): void => { if (e.key === 'Escape') close(); };
  const act = (f: () => void | Promise<void>) => async (): Promise<void> => { close(); await f(); };

  const buttons: HTMLElement[] = [];
  const button = (label: string, f: () => void | Promise<void>, primary = false): void => {
    buttons.push(h(primary ? 'button.sheet-button.primary' : 'button.sheet-button', { type: 'button', onclick: act(f) }, label));
  };
  if (item.kind === 'video' && !item.drm) {
    const resume = resumeLabel(item);
    if (resume) { button(resume, () => actions.play(item, false), true); button('Von vorn abspielen', () => actions.play(item, true)); }
    else button('Abspielen', () => actions.play(item, true), true);
  }
  if (item.kind === 'live' && !item.drm) button('Live ansehen', () => actions.play(item, false), true);
  if (item.kind === 'video' || item.kind === 'live') {
    button(item.later ? 'Aus „Später ansehen“ entfernen' : 'Später ansehen', () => actions.mark(item, { later: !item.later }));
  }
  if (item.kind === 'video') {
    button(item.watched ? 'Als ungesehen markieren' : 'Als gesehen markieren', () => actions.mark(item, { watched: !item.watched }));
    if (item.progress && item.progress > 0 && !item.watched) button('Aus „Weiterschauen“ entfernen', () => actions.mark(item, { forget: true }));
    if (item.showRef) button('Zur Sendung', () => actions.openShow(item));
  }
  if (item.kind === 'folder') {
    if (item.page || item.id) button('Öffnen', () => actions.open(item), true);
    if (item.following !== undefined) button(item.following ? 'Nicht mehr folgen' : 'Folgen', () => actions.mark(item, { follow: !item.following }));
  }

  const pic = actions.imageURL(item.backdrop ?? item.img, 640);
  const nowLine = item.kind === 'live' && item.now
    ? dotJoin(`Jetzt: ${item.now.title}`, `${clock(item.now.start)}–${clock(item.now.end)}`) : null;
  const nextLine = item.kind === 'live' && item.next ? dotJoin(`Danach: ${item.next.title}`, clock(item.next.start)) : null;
  const panel = h('div.sheet-panel', { role: 'dialog', 'aria-modal': 'true', 'aria-label': item.title ?? 'Optionen' },
    pic ? h('img.sheet-picture', { src: pic, alt: '' }) : null,
    h('div.sheet-text', null,
      h('h2', null, item.title ?? ''),
      item.sub ? h('p.sheet-sub', null, item.sub) : null,
      nowLine ? h('p.sheet-sub', null, nowLine) : null,
      nextLine ? h('p.sheet-sub', null, nextLine) : null,
      item.drm ? h('p.sheet-note', null, 'Dieses Video ist kopiergeschützt und läuft nur am Fernseher.') : null,
      item.plot ? h('p.sheet-plot', null, item.plot) : null),
    h('div.sheet-buttons', null, ...buttons,
      h('button.sheet-button.cancel', { type: 'button', onclick: close }, 'Abbrechen')));
  const el = h('div.sheet', { onclick: (e: Event) => { if (e.target === el) close(); } }, panel);
  document.body.append(el);
  addEventListener('keydown', onKey);
  requestAnimationFrame(() => { el.classList.add('open'); (panel.querySelector('.sheet-button') as HTMLElement | null)?.focus({ preventScroll: true }); });
  current = { el, done: close };
}
