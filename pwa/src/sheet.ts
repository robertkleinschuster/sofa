// The item's sheet (⋯ on a tile): what the TV's menu offers - play here or on the TV, from the start,
// Später ansehen, the download, gesehen, aus Weiterschauen entfernen, zur Sendung, folgen - with the
// item's text. And a confirmation in the same look, for what can't be undone (it names the consequence).

import { clock, dotJoin, h } from './dom.ts';
import { resumeLabel } from './player.ts';
import { downloadChoices, type Choice, type DownloadAction } from './choices.ts';
import type { Item, MarkChange } from './types.ts';

export type { DownloadAction };


export interface SheetActions {
  play(item: Item, fromStart: boolean): void;
  toTV(item: Item): void;          // "Auf dem Fernseher abspielen"
  mark(item: Item, change: MarkChange): Promise<void>;
  download(item: Item, action: DownloadAction): void;
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

// The sheet itself: a panel from the bottom (centred on wide screens) with the choices and Abbrechen
function present(label: string, top: (Node | null)[], choices: Choice[], returnFocus?: HTMLElement): void {
  closeSheet();
  let closed = false;   // fading out: nothing in it acts any more
  const close = (): void => {
    if (closed) return;
    closed = true;
    el.classList.remove('open');
    el.inert = true;
    setTimeout(() => el.remove(), 200);
    removeEventListener('keydown', onKey);
    if (current?.el === el) current = null;
    if (returnFocus?.isConnected) returnFocus.querySelector<HTMLElement>('.more')?.focus({ preventScroll: true });
  };
  const onKey = (e: KeyboardEvent): void => { if (e.key === 'Escape') close(); };
  const buttons = choices.map((c) => {
    const cls = c.primary ? 'button.sheet-button.primary' : c.danger ? 'button.sheet-button.danger' : 'button.sheet-button';
    return h(cls as 'button', { type: 'button', onclick: async () => { if (closed) return; close(); await c.run(); } },
      h('span.sheet-label', null, c.label), c.detail ? h('span.sheet-detail', null, c.detail) : null);
  });
  const panel = h('div.sheet-panel', { role: 'dialog', 'aria-modal': 'true', 'aria-label': label }, ...top,
    h('div.sheet-buttons', null, ...buttons, h('button.sheet-button.cancel', { type: 'button', onclick: close }, 'Abbrechen')));
  const el = h('div.sheet', { onclick: (e: Event) => { if (e.target === el) close(); } }, panel);
  document.body.append(el);
  addEventListener('keydown', onKey);
  // (closed before its first frame - a quick Abbrechen: it stays closed)
  requestAnimationFrame(() => { if (closed) return; el.classList.add('open'); (panel.querySelector('.sheet-button') as HTMLElement | null)?.focus({ preventScroll: true }); });
  current = { el, done: close };
}

// "Download löschen?" - the question, what it means, and the one button that does it
export function confirmSheet(c: { title: string; text: string; yes: string; danger?: boolean; onYes: () => void }): void {
  present(c.title, [h('div.sheet-text', null, h('h2', null, c.title), h('p.sheet-sub', null, c.text))],
    [{ label: c.yes, run: c.onYes, ...(c.danger ? { danger: true } : { primary: true }) }]);
}

export function openSheet(item: Item, actions: SheetActions, returnFocus?: HTMLElement): void {
  const choices: Choice[] = [];
  const add = (label: string, run: () => void | Promise<void>, primary = false): void => { choices.push({ label, run, primary }); };
  const playable = (item.kind === 'video' || item.kind === 'live') && !item.drm;
  if (item.kind === 'video' && !item.drm) {
    const resume = resumeLabel(item);
    if (resume) { add(resume, () => actions.play(item, false), true); add('Von vorn abspielen', () => actions.play(item, true)); }
    else add('Abspielen', () => actions.play(item, true), true);
  }
  if (item.kind === 'live' && !item.drm) add('Live ansehen', () => actions.play(item, false), true);
  if (playable) add('Auf dem Fernseher abspielen', () => actions.toTV(item));
  if (item.kind === 'video' || item.kind === 'live') {
    add(item.later ? 'Aus „Später ansehen“ entfernen' : 'Später ansehen', () => actions.mark(item, { later: !item.later }));
  }
  if (item.kind === 'video') {
    choices.push(...downloadChoices(item, (a) => actions.download(item, a)));
    add(item.watched ? 'Als ungesehen markieren' : 'Als gesehen markieren', () => actions.mark(item, { watched: !item.watched }));
    if (item.progress && item.progress > 0 && !item.watched) add('Aus „Weiterschauen“ entfernen', () => actions.mark(item, { forget: true }));
    if (item.showRef) add('Zur Sendung', () => actions.openShow(item));
  }
  if (item.kind === 'folder') {
    if (item.page || item.id) add('Öffnen', () => actions.open(item), true);
    if (item.following !== undefined) add(item.following ? 'Nicht mehr folgen' : 'Folgen', () => actions.mark(item, { follow: !item.following }));
  }

  const pic = actions.imageURL(item.backdrop ?? item.img, 640);
  const nowLine = item.kind === 'live' && item.now
    ? dotJoin(`Jetzt: ${item.now.title}`, `${clock(item.now.start)}–${clock(item.now.end)}`) : null;
  const nextLine = item.kind === 'live' && item.next ? dotJoin(`Danach: ${item.next.title}`, clock(item.next.start)) : null;
  present(item.title ?? 'Optionen', [
    pic ? h('img.sheet-picture', { src: pic, alt: '' }) : null,
    h('div.sheet-text', null,
      h('h2', null, item.title ?? ''),
      item.sub ? h('p.sheet-sub', null, item.sub) : null,
      nowLine ? h('p.sheet-sub', null, nowLine) : null,
      nextLine ? h('p.sheet-sub', null, nextLine) : null,
      item.drm ? h('p.sheet-note', null, 'Dieses Video ist kopiergeschützt (DRM) und lässt sich mit Sofa nicht abspielen.') : null,
      item.plot ? h('p.sheet-plot', null, item.plot) : null)], choices, returnFocus);
}
