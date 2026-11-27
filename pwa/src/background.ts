// A playback beyond the page (docs/pwa.md §3): picture in picture, playing on with the screen locked
// or the app in the background, and the system's media controls (lock screen, Control Center,
// headphones, keyboard media keys). One per player; detach() undoes all of it.
//
//   - picture in picture: the standard API (Chrome, Safari 13.1+) or WebKit's presentation mode
//     (iOS); autopictureinpicture lets the browser enter it by itself when the app goes to the
//     background while the video plays. iOS offers none in a Home Screen web app (WebKit bug 303885):
//     the button stays hidden there, by the browser's own answer
//   - background: the audio session is "playback" (WebKit's Audio Session API: the category that
//     plays on when the screen locks). A pause the system makes on the way to the background is
//     undone once. Where the system won't let the video play in the background - iOS pauses every
//     <video> with a picture when the app leaves or the screen locks (MediaSessionManageriOS: the
//     Video and VideoAudio session types are background-restricted, Audio is not) - the sound is
//     carried on by an <audio> element of the same stream (the carrier: an <audio> element is an
//     Audio session whatever the stream holds), from the video's position; back in front, the video
//     takes over from the carrier's position. The carrier is loaded (metadata) beforehand and
//     unlocked by the person's first tap, so it starts at once: WebKit lets a hidden page start
//     audible playback only right after other audio stopped (a hand-over) or on a gesture.
//     A stream the browser plays through MediaSource (blob:) has no URL to carry: there the video
//     itself is asked to play on
//   - the person's own pauses are known: the system's controls come through the actions below, the
//     page's (the video's controls, the space bar) happen while it is visible - except one in the very
//     moment the page hides (PAUSE_HIDE_MS), which iOS makes itself
//   - the system's controls: Media Session actions and the position (seek bar on the lock screen),
//     on whichever element plays (the clock)

type WebKitVideo = HTMLVideoElement & {
  webkitSupportsPresentationMode?: (mode: string) => boolean;
  webkitSetPresentationMode?: (mode: string) => void;
  webkitPresentationMode?: string;
};
type AudioSessionNavigator = Navigator & { audioSession?: { type: string } };

const SEEK_STEP_S = 10;
const PAUSE_HIDE_MS = 1000;   // a pause this close before the page hid came with the hiding
const ACTIONS: MediaSessionAction[] = ['play', 'pause', 'stop', 'seekbackward', 'seekforward', 'seekto'];
const GESTURES = ['touchend', 'click', 'keydown'];

export function pipSupported(v: HTMLVideoElement): boolean {
  const w = v as WebKitVideo;
  return (globalThis.document?.pictureInPictureEnabled === true && !v.disablePictureInPicture)
    || (typeof w.webkitSupportsPresentationMode === 'function' && w.webkitSupportsPresentationMode('picture-in-picture'));
}

export function inPip(v: HTMLVideoElement): boolean {
  return globalThis.document?.pictureInPictureElement === v || (v as WebKitVideo).webkitPresentationMode === 'picture-in-picture';
}

// Into picture in picture, or out of it (a tap: both APIs want a user gesture)
export async function togglePip(v: HTMLVideoElement): Promise<void> {
  const w = v as WebKitVideo;
  if (inPip(v)) {
    if (document.pictureInPictureElement) await document.exitPictureInPicture();
    else w.webkitSetPresentationMode?.('inline');
    return;
  }
  if (document.pictureInPictureEnabled && typeof v.requestPictureInPicture === 'function') await v.requestPictureInPicture();
  else w.webkitSetPresentationMode?.('picture-in-picture');
}

export interface BackgroundHooks {
  close(): void;                                  // the system's "stop"
  pip(on: boolean): void;                         // picture in picture began or ended
  clock(state: 'playing' | 'paused'): void;       // the carrier played or paused (the video's own events say the rest)
}

// What it uses of the page, the browser and the carrier (tests hand in their own)
export interface BackgroundEnv {
  page: EventTarget & { readonly hidden: boolean };
  nav: Navigator;
  carrier: HTMLAudioElement;
}

function browserEnv(): BackgroundEnv {
  const carrier = document.createElement('audio');
  carrier.preload = 'metadata';
  return { page: document, nav: navigator, carrier };
}

export class Background {
  private wantsPlay = false;        // the person's last word: playing (a pause from elsewhere is undone)
  private resumed = false;          // one undo per trip to the background
  private visiblePauseAt = 0;       // a pause while the page showed: the person's, unless the page hid right after
  private carrying = false;         // the carrier plays the sound for the video
  private carrierSrc = '';          // the stream the carrier holds ('' = none to carry)
  private unlocked = false;         // the carrier saw a gesture (WebKit then lets it play without one)
  private readonly page: BackgroundEnv['page'];
  private readonly nav: Navigator;
  private readonly carrier: HTMLAudioElement;
  private readonly off: Array<() => void> = [];
  private readonly video: HTMLVideoElement;
  private readonly hooks: BackgroundHooks;

  constructor(video: HTMLVideoElement, hooks: BackgroundHooks, env: BackgroundEnv = browserEnv()) {
    this.video = video;
    this.hooks = hooks;
    ({ page: this.page, nav: this.nav, carrier: this.carrier } = env);
    const v = video, a = this.carrier;
    v.setAttribute('autopictureinpicture', '');
    v.setAttribute('x-webkit-airplay', 'allow');
    try { const s = (this.nav as AudioSessionNavigator).audioSession; if (s) s.type = 'playback'; } catch { /* older WebKit: its default plays on */ }

    const listen = (t: EventTarget, ev: string, f: () => void): void => { t.addEventListener(ev, f); this.off.push(() => t.removeEventListener(ev, f)); };
    listen(v, 'play', () => { this.wantsPlay = true; this.position(); });
    for (const ev of ['playing', 'ratechange', 'seeked']) { listen(v, ev, () => this.position()); listen(a, ev, () => this.position()); }
    listen(v, 'loadedmetadata', () => { this.position(); this.prepare(); });
    listen(v, 'pause', () => this.systemPause());
    listen(v, 'enterpictureinpicture', () => hooks.pip(true));
    listen(v, 'leavepictureinpicture', () => hooks.pip(false));
    listen(v, 'webkitpresentationmodechanged', () => hooks.pip(inPip(v)));
    listen(a, 'playing', () => { if (this.carrying) { this.position(); hooks.clock('playing'); } });
    listen(a, 'pause', () => { if (this.carrying && !a.ended) hooks.clock('paused'); });
    listen(a, 'ended', () => { if (this.carrying) { this.wantsPlay = false; hooks.clock('paused'); } });
    listen(a, 'error', () => { if (this.carrying) { this.wantsPlay = false; hooks.clock('paused'); } else this.carrierSrc = ''; });
    listen(this.page, 'visibilitychange', () => {
      if (!this.page.hidden) { this.resumed = false; if (this.carrying) this.handBack(); return; }
      if (v.paused && this.wantsPlay && Date.now() - this.visiblePauseAt < PAUSE_HIDE_MS) this.carryOn();
    });
    const unlock = (): void => { if (!this.unlocked) { this.unlocked = true; a.load(); } };
    for (const ev of GESTURES) listen(this.page, ev, unlock);
    a.load();   // opened by a tap: that gesture may still count
    this.actions();
  }

  // The element whose time is the playback's: the carrier while it carries, else the video
  get clock(): HTMLMediaElement { return this.carrying ? this.carrier : this.video; }

  // the carrier holds the video's stream (metadata only), ready to take over
  private prepare(): void {
    const src = this.video.currentSrc;
    const usable = !!src && !src.startsWith('blob:');
    if (!usable) { if (this.carrierSrc) { this.carrierSrc = ''; this.carrier.removeAttribute('src'); this.carrier.load(); } return; }
    if (src === this.carrierSrc) return;
    this.carrierSrc = src;
    this.carrier.src = src;
  }

  private systemPause(): void {
    if (this.video.ended) { this.wantsPlay = false; return; }
    if (!this.page.hidden) {
      this.visiblePauseAt = Date.now();
      setTimeout(() => { if (!this.page.hidden && this.video.paused) this.wantsPlay = false; }, PAUSE_HIDE_MS);
      return;
    }
    if (this.wantsPlay) this.carryOn();
  }

  // the system paused the video on the way to the background (not the person): playing on, once -
  // the carrier from the video's position, or (no stream to carry) the video itself
  private carryOn(): void {
    const v = this.video, a = this.carrier;
    if (this.resumed || this.carrying || inPip(v) || !v.paused) return;
    this.resumed = true;
    if (!this.carrierSrc) { v.play().catch(() => { this.wantsPlay = false; }); return; }
    this.carrying = true;
    if (Number.isFinite(v.duration)) {   // a live stream plays from its edge
      const t = v.currentTime;
      if (a.readyState >= 1) a.currentTime = t;
      else a.addEventListener('loadedmetadata', () => { if (this.carrying) a.currentTime = t; }, { once: true });
    }
    a.play().catch(() => { if (this.carrying) { this.carrying = false; this.wantsPlay = false; } });
  }

  // back in front: the video takes over where the carrier is
  private handBack(): void {
    const v = this.video, a = this.carrier;
    const playing = !a.paused && !a.ended, t = a.currentTime;
    this.carrying = false;
    a.pause();
    if (Number.isFinite(v.duration) && Number.isFinite(t) && t > 0) v.currentTime = Math.min(t, v.duration);
    this.wantsPlay = playing;
    if (playing) void v.play().catch(() => undefined);   // refused: the video's controls show it paused
    this.position();
  }

  private actions(): void {
    if (!('mediaSession' in this.nav)) return;
    const ms = this.nav.mediaSession;
    const set = (a: MediaSessionAction, f: MediaSessionActionHandler | null): void => { try { ms.setActionHandler(a, f); } catch { /* not supported here */ } };
    set('play', () => { this.wantsPlay = true; void this.clock.play().catch(() => undefined); });
    set('pause', () => { this.wantsPlay = false; this.clock.pause(); });
    set('stop', () => { this.wantsPlay = false; this.hooks.close(); });
    set('seekbackward', (d) => { const c = this.clock; c.currentTime = Math.max(0, c.currentTime - (d.seekOffset ?? SEEK_STEP_S)); });
    set('seekforward', (d) => { const c = this.clock; c.currentTime = Math.min(c.duration || Infinity, c.currentTime + (d.seekOffset ?? SEEK_STEP_S)); });
    set('seekto', (d) => { if (d.seekTime !== undefined && Number.isFinite(d.seekTime)) this.clock.currentTime = d.seekTime; });
    this.off.push(() => { for (const a of ACTIONS) set(a, null); });
  }

  // the lock screen's seek bar (a live stream has none)
  private position(): void {
    if (!('mediaSession' in this.nav) || typeof this.nav.mediaSession.setPositionState !== 'function') return;
    const c = this.clock;
    try {
      if (Number.isFinite(c.duration) && c.duration > 0) {
        this.nav.mediaSession.setPositionState({ duration: c.duration, playbackRate: c.playbackRate || 1, position: Math.min(Math.max(0, c.currentTime), c.duration) });
      } else this.nav.mediaSession.setPositionState();
    } catch { /* a position past the end while seeking: the next event sets it */ }
  }

  detach(): void {
    for (const f of this.off.splice(0)) f();
    this.carrying = false;
    this.carrier.pause();
    this.carrier.removeAttribute('src');
    this.carrier.load();
    if ('mediaSession' in this.nav) { this.nav.mediaSession.metadata = null; try { this.nav.mediaSession.playbackState = 'none'; } catch { /* */ } }
    if (inPip(this.video)) void togglePip(this.video).catch(() => undefined);
  }
}
