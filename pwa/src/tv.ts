// The TV (docs/pwa.md §6): "Auf dem Fernseher abspielen" and the "Am Fernseher" bar.
// Sending opens the item in the TV's own player, as the remote would (resume, history, marks are the
// TV's). When something else plays there, Sofa says so and the sheet asks before replacing it. After
// sending, the bar shows what the TV does - with Sofa's status it follows the TV's player (open, paused,
// failed, closed) and offers pause/play and stop; the viewer hears once that it plays now, or that it
// failed there.

import { ApiError, type Api } from './api.ts';
import { dotJoin, formatDuration, h, icon, ICONS } from './dom.ts';
import { confirmSheet } from './sheet.ts';
import type { Item, TvState } from './types.ts';

const WATCH_MS = 90_000;   // a sent video is watched this long for "läuft jetzt" / "ließ sich nicht abspielen"

const STATE_TEXT: Record<TvState['state'], string> = {
  playing: 'Läuft', paused: 'Pausiert', buffering: 'Lädt …', ended: 'Zu Ende', failed: 'Ließ sich nicht abspielen',
};

export interface TvHost {
  api: Api;
  toast(text: string): void;
  statusChanged(): void;   // ask Sofa's status at once
}

export class Tv {
  private bar: HTMLElement;
  private pic: HTMLImageElement;
  private label: HTMLElement;
  private state: HTMLElement;   // in the label, after "Am Fernseher · " (which narrow screens leave to the icon)
  private title: HTMLElement;
  private toggle: HTMLButtonElement;
  private fill: HTMLElement;
  private tv: TvState | null = null;
  private at = 0;                                         // when `tv` arrived (performance.now)
  private shownId: string | undefined;
  private expect: { id: string; until: number } | null = null;
  private ticker: ReturnType<typeof setInterval> | null = null;

  constructor(private host: TvHost) {
    this.pic = h('img.tvbar-pic', { alt: '' });
    this.pic.addEventListener('error', () => { this.pic.hidden = true; });
    this.label = h('span.tvbar-label');
    this.state = h('span');
    this.title = h('span.tvbar-title');
    this.toggle = h('button.tvbar-button', { type: 'button', onclick: () => this.control(this.playingNow() ? 'pause' : 'play') });
    this.fill = h('span');
    this.bar = h('section.tvbar', { 'aria-label': 'Am Fernseher', hidden: true },
      this.pic,
      h('div.tvbar-text', null, h('span.tvbar-head', null, icon(ICONS.tv), this.label), this.title),
      this.toggle,
      h('button.tvbar-button', { type: 'button', 'aria-label': 'Am Fernseher beenden', title: 'Am Fernseher beenden', onclick: () => this.control('stop') }, icon(ICONS.stop)),
      h('span.tvbar-progress', null, this.fill));
    document.body.append(this.bar);
  }

  // "Auf dem Fernseher abspielen"; at: hand a playback over from the browser at this position
  async send(item: Item, opts: { fromStart?: boolean; at?: number } = {}, replace = false): Promise<void> {
    if (!replace) this.host.toast('Wird an den Fernseher gesendet …');
    try {
      const r = await this.host.api.tvPlay(item, { ...opts, replace });
      this.expect = !r.already && item.id ? { id: item.id, until: Date.now() + WATCH_MS } : null;
      this.host.toast(r.already ? 'Läuft schon am Fernseher' : 'Am Fernseher geöffnet');
      this.update(r.tv);
      this.host.statusChanged();
    } catch (e) {
      if (e instanceof ApiError && e.status === 409 && !replace) {
        confirmSheet({
          title: e.message, text: 'Es wird dort beendet – die Stelle bleibt gespeichert.',
          yes: item.title ? `Stattdessen „${item.title}“ abspielen` : 'Stattdessen abspielen',
          onYes: () => void this.send(item, opts, true),
        });
        return;
      }
      this.host.toast(e instanceof ApiError && e.unreachable ? 'Der Fernseher ist gerade nicht erreichbar.' : e instanceof Error ? e.message : 'Das hat nicht geklappt.');
    }
  }

  // Sofa's status (or an answer of our own): what the TV's player shows now
  update(tv: TvState | null): void {
    this.tv = tv;
    this.at = performance.now();
    const ex = this.expect;
    if (ex && Date.now() > ex.until) this.expect = null;
    else if (ex && tv && tv.item.id === ex.id && (tv.state === 'playing' || tv.state === 'failed')) {
      this.expect = null;
      this.host.toast(tv.state === 'playing' ? 'Läuft jetzt am Fernseher' : `„${tv.item.title ?? 'Das Video'}“ ließ sich am Fernseher nicht abspielen.`);
    }
    this.render();
  }

  private playingNow(): boolean { return this.tv?.state === 'playing' || this.tv?.state === 'buffering'; }

  private render(): void {
    const tv = this.tv;
    const on = !!tv;
    this.bar.hidden = !on;
    document.body.classList.toggle('tv-on', on);
    this.tick();
    if (!tv) { this.shownId = undefined; return; }
    if (tv.item.id !== this.shownId) {
      this.shownId = tv.item.id;
      const src = this.host.api.image(tv.item.img ?? tv.item.imgFallback, 96);
      this.pic.hidden = !src;
      if (src) this.pic.src = src; else this.pic.removeAttribute('src');
      this.title.textContent = tv.item.title ?? '';
    }
    const playing = this.playingNow();
    this.toggle.replaceChildren(icon(playing ? ICONS.pause : ICONS.play));
    this.toggle.setAttribute('aria-label', playing ? 'Am Fernseher pausieren' : 'Am Fernseher abspielen');
    this.toggle.title = this.toggle.getAttribute('aria-label')!;
    this.toggle.hidden = tv.state === 'failed' || tv.state === 'ended';
    if (playing && !tv.live && !this.ticker) this.ticker = setInterval(() => this.tick(), 1000);
    if ((!playing || tv.live) && this.ticker) { clearInterval(this.ticker); this.ticker = null; }
  }

  // the label and the progress; a playing video's position runs on from Sofa's last answer
  private tick(): void {
    const tv = this.tv;
    if (!tv) { if (this.ticker) { clearInterval(this.ticker); this.ticker = null; } return; }
    const pos = tv.state === 'playing' ? Math.min(tv.duration || Infinity, tv.position + (performance.now() - this.at) / 1000) : tv.position;
    const time = !tv.live && tv.duration > 0 ? `${formatDuration(pos)} / ${formatDuration(tv.duration)}` : null;
    if (!this.state.isConnected) this.label.replaceChildren(h('span.tvbar-where', null, 'Am Fernseher · '), this.state);
    this.state.textContent = dotJoin(tv.live && tv.state === 'playing' ? 'Live' : STATE_TEXT[tv.state], tv.state === 'failed' ? null : time);
    this.fill.style.width = !tv.live && tv.duration > 0 ? `${Math.round(Math.min(1, pos / tv.duration) * 1000) / 10}%` : '0';
  }

  private async control(action: 'play' | 'pause' | 'stop'): Promise<void> {
    try {
      const r = await this.host.api.tvControl(action);
      this.update(action === 'stop' ? null : r.tv);
      this.host.statusChanged();
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) { this.update(null); return; }
      this.host.toast(e instanceof ApiError && e.unreachable ? 'Der Fernseher ist gerade nicht erreichbar.' : e instanceof Error ? e.message : 'Das hat nicht geklappt.');
    }
  }

  // unpaired or another Sofa: nothing of the old one stays on screen
  reset(): void { this.expect = null; this.update(null); }
}
