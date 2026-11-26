// Playback in the browser (docs/pwa.md §3). Sofa opens the item through its own routes and hands
// out a capability path; this plays it - natively where the browser plays HLS itself (Safari, iOS),
// with hls.js (MSE) elsewhere, files in a plain <video> - and reports the player's state, so the
// position lands in Sofa's store (the TV's rule) and YouTube views are reported as its player would.

import { ApiError, type Api, type StreamReport } from './api.ts';
import { formatDuration, h, icon, ICONS } from './dom.ts';
import { browserFormats, mediaSourceTest } from './formats.ts';
import type { Item, PlayAnswer } from './types.ts';

const REPORT_EVERY_MS = 10_000;
const REOPEN_LIMIT = 2;
const UNSUPPORTED = 'Dieser Browser kann das Videoformat nicht abspielen.';               // stream errors healed by opening the item again, per playback

type HlsLike = { destroy(): void; loadSource(u: string): void; attachMedia(v: HTMLMediaElement): void; on(ev: string, f: (e: string, d: { fatal?: boolean; type?: string; details?: string }) => void): void; recoverMediaError(): void };

export interface PlayerHost {
  api: Api;
  closed(item: Item): void;      // the overlay went away: refresh the item's tiles
  toast(text: string): void;
  // "Am Fernseher weiterschauen": this playback moves to the TV (at: where it is; none for a live)
  toTV(item: Item, at: number | undefined): void;
}

let lastActivity = Date.now();
for (const ev of ['pointerdown', 'keydown', 'touchstart']) {
  globalThis.addEventListener?.(ev, () => { lastActivity = Date.now(); }, { passive: true, capture: true });
}

// Apple's browsers play HLS (and fMP4 byte ranges) natively and best; others go through hls.js.
function preferNative(video: HTMLVideoElement): boolean {
  const can = video.canPlayType('application/vnd.apple.mpegurl') !== '';
  const apple = /Apple/.test(navigator.vendor ?? '') && !/CriOS|FxiOS|EdgiOS/.test(navigator.userAgent);
  return can && (apple || !('MediaSource' in globalThis || 'ManagedMediaSource' in globalThis));
}

export class Player {
  private overlay: HTMLElement;
  private video: HTMLVideoElement;
  private status: HTMLElement;
  private hls: HlsLike | null = null;
  private answer: PlayAnswer | null = null;
  private timer: ReturnType<typeof setInterval> | null = null;
  private reopened = 0;
  private gone = false;          // Sofa no longer knows the stream
  private closing = false;
  private onPageHide = (): void => this.beaconClose();

  constructor(private host: PlayerHost, private item: Item, private fromStart = false) {
    this.video = h('video', { controls: true, playsInline: true, preload: 'auto' });
    this.video.setAttribute('playsinline', '');
    this.status = h('div.player-status', { role: 'status' });
    const close = h('button.player-close', { type: 'button', 'aria-label': 'Schließen', title: 'Schließen', onclick: () => history.back() }, '✕');
    const tvLabel = item.kind === 'live' ? 'Am Fernseher ansehen' : 'Am Fernseher weiterschauen';
    const tv = h('button.player-tv', { type: 'button', 'aria-label': tvLabel, title: tvLabel, onclick: () => this.toTV() }, icon(ICONS.tv));
    this.overlay = h('div.player', { role: 'dialog', 'aria-label': item.title ?? 'Video' },
      h('div.player-bar', null, close, h('div.player-title', null, item.title ?? '', item.sub ? h('span', null, item.sub) : null), tv),
      this.video, this.status);
  }

  async open(): Promise<void> {
    document.body.append(this.overlay);
    document.body.classList.add('playing');
    this.showStatus('Wird geöffnet …');
    addEventListener('pagehide', this.onPageHide);
    this.wire();
    try {
      await this.start();
    } catch (e) {
      this.fail(e);
    }
  }

  private async start(at?: number): Promise<void> {
    const native = preferNative(this.video);
    const formats = browserFormats(native ? null : mediaSourceTest());
    this.overlay.dataset['formats'] = formats.join(' ');
    const a = await this.host.api.play(this.item, formats);
    if (this.closing) { this.host.api.beacon(a.stream, { state: 'closed' }); return; }
    this.answer = a;
    this.gone = false;
    this.failed = false;
    const start = at ?? (this.fromStart ? 0 : a.start);
    this.teardownEngine();
    if (a.segmented) this.overlay.dataset['segmented'] = a.segmented;
    if (a.kind === 'hls' && !native) {
      const { default: Hls } = await import('hls.js');
      if (this.closing) return;
      if (!Hls.isSupported()) { this.overlay.dataset['engine'] = 'native'; this.video.src = this.host.api.url(a.url); }
      else {
        const hls = new Hls({ startPosition: a.live ? -1 : start, maxBufferLength: 30, backBufferLength: 60 }) as unknown as HlsLike;
        let mediaRecoveries = 0;
        hls.on('hlsError', (_e, d) => {
          this.overlay.dataset['lastError'] = `${d.type ?? ''} ${d.details ?? ''}${d.fatal ? ' (fatal)' : ''}`;
          if (!d.fatal) return;
          if (d.details === 'manifestIncompatibleCodecsError') { this.fail(new Error(UNSUPPORTED)); return; }
          if (d.type === 'mediaError' && mediaRecoveries++ < 2) { hls.recoverMediaError(); return; }
          this.streamFailed(`${d.type ?? ''} ${d.details ?? ''}`);
        });
        this.overlay.dataset['engine'] = 'hls.js';
        hls.loadSource(this.host.api.url(a.url));
        hls.attachMedia(this.video);
        this.hls = hls;
      }
    } else {
      this.overlay.dataset['engine'] = a.kind === 'hls' ? 'native' : 'file';
      this.video.src = this.host.api.url(a.url);
      if (!a.live && start > 0) {
        this.video.addEventListener('loadedmetadata', () => { if (start < (this.video.duration || Infinity) - 5) this.video.currentTime = start; }, { once: true });
      }
    }
    if ('mediaSession' in navigator) {
      navigator.mediaSession.metadata = new MediaMetadata({ title: a.title || this.item.title || '', artist: this.item.channel ?? this.item.sub ?? 'Sofa' });
    }
    try {
      await this.video.play();
      this.showStatus('');
    } catch (e) {
      this.overlay.dataset['playError'] = e instanceof Error ? e.name : String(e);
      // the browser wants a tap first (the gesture expired while Sofa opened it): the controls say so
      if (!this.failed && e instanceof Error && e.name === 'NotAllowedError') this.showStatus('Zum Abspielen tippen');
    }
  }

  private wire(): void {
    const v = this.video;
    v.addEventListener('playing', () => { this.showStatus(''); this.report('playing'); this.startClock(); });
    v.addEventListener('pause', () => { if (!v.ended && !this.closing) this.report('paused'); this.stopClock(); });
    v.addEventListener('seeked', () => this.report(v.paused ? 'paused' : 'playing'));
    v.addEventListener('ended', () => { this.report('ended'); this.stopClock(); });
    v.addEventListener('waiting', () => this.showStatus('Lädt …', 800));
    v.addEventListener('error', () => {
      if (this.hls || this.closing) return;
      // 4 = MEDIA_ERR_SRC_NOT_SUPPORTED: the format, not the connection - opening it again won't help
      if (v.error?.code === 4) this.fail(new Error(UNSUPPORTED)); else this.streamFailed(`media error ${v.error?.code ?? ''}`);
    });
  }

  private startClock(): void {
    if (this.timer) return;
    this.timer = setInterval(() => { if (!this.video.paused) this.report('playing'); }, REPORT_EVERY_MS);
  }

  private stopClock(): void { if (this.timer) { clearInterval(this.timer); this.timer = null; } }

  private state(state: StreamReport['state']): StreamReport {
    const v = this.video;
    const r: StreamReport = { state, lactMs: Math.max(0, Date.now() - lastActivity) };
    if (Number.isFinite(v.currentTime)) r.position = Math.max(0, v.currentTime);
    const d = Number.isFinite(v.duration) && v.duration > 0 ? v.duration : this.answer?.duration;
    if (d && d > 0) r.duration = d;
    return r;
  }

  private report(state: StreamReport['state']): void {
    const a = this.answer;
    if (!a || this.closing || this.gone) return;
    this.host.api.report(a.stream, this.state(state)).catch((e: unknown) => {
      // 404: Sofa ended the stream (restarted, or idle) - it plays on from the buffer; a seek or the
      // next error opens it again
      if (e instanceof ApiError && e.status === 404 && a === this.answer) this.gone = true;
    });
  }

  private streamFailed(why: string): void {
    if (this.closing) return;
    console.warn('sofa: stream failed:', why);
    if (this.reopened >= REOPEN_LIMIT) { this.fail(new Error('Die Wiedergabe ist abgebrochen.')); return; }
    this.reopened++;
    const at = this.answer?.live ? undefined : this.video.currentTime || undefined;
    if (this.answer && !this.gone) this.host.api.beacon(this.answer.stream, this.state('closed'));
    this.answer = null;
    this.showStatus('Verbindung wird wiederhergestellt …');
    this.start(at).catch((e) => this.fail(e));
  }

  private failed = false;
  private fail(e: unknown): void {
    if (this.closing) return;
    this.failed = true;
    this.stopClock();
    const msg = e instanceof Error ? e.message : 'Das Video ließ sich nicht abspielen.';
    this.showStatus(msg);
  }

  private statusTimer: ReturnType<typeof setTimeout> | null = null;
  private showStatus(text: string, delayMs = 0): void {
    if (this.statusTimer) { clearTimeout(this.statusTimer); this.statusTimer = null; }
    const apply = (): void => { this.status.textContent = text; this.status.hidden = !text; this.status.classList.toggle('error', this.failed); };
    if (delayMs && text) this.statusTimer = setTimeout(apply, delayMs); else apply();
  }

  private beaconClose(): void {
    const a = this.answer;
    if (a && !this.gone) this.host.api.beacon(a.stream, this.state('closed'));
  }

  private teardownEngine(): void {
    if (this.hls) { this.hls.destroy(); this.hls = null; }
  }

  // The TV takes over where this playback is (its own stream ends: one player per video and person)
  private toTV(): void {
    const live = this.answer?.live ?? this.item.kind === 'live';
    const t = this.video.currentTime;
    this.video.pause();
    this.host.toTV(this.item, !live && Number.isFinite(t) && t > 1 ? t : undefined);
  }

  // Back button or ✕ (via history): the last report, then away.
  close(): void {
    if (this.closing) return;
    const a = this.answer;
    if (a && !this.gone) {
      const last = this.state('closed');
      this.host.api.report(a.stream, last).catch(() => this.host.api.beacon(a.stream, last));
    }
    this.closing = true;
    this.stopClock();
    removeEventListener('pagehide', this.onPageHide);
    this.video.pause();
    this.teardownEngine();
    this.video.removeAttribute('src');
    this.video.load();
    this.overlay.remove();
    document.body.classList.remove('playing');
    if (document.fullscreenElement) void document.exitFullscreen().catch(() => undefined);
    this.host.closed(this.item);
  }
}

export function resumeLabel(item: Item): string | null {
  if (!item.progress || item.progress <= 0 || item.watched || !item.duration) return null;
  return `Weiterschauen ab ${formatDuration(item.progress * item.duration)}`;
}
