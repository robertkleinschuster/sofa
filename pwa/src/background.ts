// A playback beyond the page (docs/pwa.md §3): picture in picture, playing on with the screen locked
// or the app in the background, and the system's media controls (lock screen, Control Center,
// headphones, keyboard media keys). One per player; detach() undoes all of it.
//
//   - picture in picture: the standard API (Chrome, Safari 13.1+) or WebKit's presentation mode
//     (iOS, also in a Home Screen web app); autopictureinpicture lets the browser enter it by itself
//     when the app goes to the background while the video plays
//   - background: the audio session is "playback" (WebKit's Audio Session API: the category that
//     plays on when the screen locks); a pause the system makes on the way to the background is
//     undone once. The person's own pauses are known: the system's controls come through the
//     actions below, the page's (the video's controls, the space bar) happen while it is visible -
//     except one in the very moment the page hides (PAUSE_HIDE_MS), which iOS makes itself
//   - the system's controls: Media Session actions and the position (seek bar on the lock screen)

type WebKitVideo = HTMLVideoElement & {
  webkitSupportsPresentationMode?: (mode: string) => boolean;
  webkitSetPresentationMode?: (mode: string) => void;
  webkitPresentationMode?: string;
};
type AudioSessionNavigator = Navigator & { audioSession?: { type: string } };

const SEEK_STEP_S = 10;
const PAUSE_HIDE_MS = 1000;   // a pause this close before the page hid came with the hiding
const ACTIONS: MediaSessionAction[] = ['play', 'pause', 'stop', 'seekbackward', 'seekforward', 'seekto'];

export function pipSupported(v: HTMLVideoElement): boolean {
  const w = v as WebKitVideo;
  return (document.pictureInPictureEnabled === true && !v.disablePictureInPicture)
    || (typeof w.webkitSupportsPresentationMode === 'function' && w.webkitSupportsPresentationMode('picture-in-picture'));
}

export function inPip(v: HTMLVideoElement): boolean {
  return document.pictureInPictureElement === v || (v as WebKitVideo).webkitPresentationMode === 'picture-in-picture';
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

export class Background {
  private wantsPlay = false;        // the person's last word: playing (a pause from elsewhere is undone)
  private resumed = false;          // one undo per trip to the background
  private visiblePauseAt = 0;       // a pause while the page showed: the person's, unless the page hid right after
  private readonly off: Array<() => void> = [];

  constructor(private video: HTMLVideoElement, private onClose: () => void, onPipChange: (on: boolean) => void) {
    const v = video;
    v.setAttribute('autopictureinpicture', '');
    v.setAttribute('x-webkit-airplay', 'allow');
    const nav = navigator as AudioSessionNavigator;
    try { if (nav.audioSession) nav.audioSession.type = 'playback'; } catch { /* older WebKit: its default plays on */ }

    const listen = (t: EventTarget, ev: string, f: () => void): void => { t.addEventListener(ev, f); this.off.push(() => t.removeEventListener(ev, f)); };
    listen(v, 'play', () => { this.wantsPlay = true; this.position(); });
    listen(v, 'playing', () => this.position());
    listen(v, 'ratechange', () => this.position());
    listen(v, 'loadedmetadata', () => this.position());
    listen(v, 'seeked', () => this.position());
    listen(v, 'pause', () => this.systemPause());
    listen(v, 'enterpictureinpicture', () => onPipChange(true));
    listen(v, 'leavepictureinpicture', () => onPipChange(false));
    listen(v, 'webkitpresentationmodechanged', () => onPipChange(inPip(v)));
    listen(document, 'visibilitychange', () => {
      if (!document.hidden) { this.resumed = false; return; }
      if (v.paused && this.wantsPlay && Date.now() - this.visiblePauseAt < PAUSE_HIDE_MS) this.resume();
    });
    this.actions();
  }

  private systemPause(): void {
    if (this.video.ended) { this.wantsPlay = false; return; }
    if (!document.hidden) { this.visiblePauseAt = Date.now(); setTimeout(() => { if (!document.hidden && this.video.paused) this.wantsPlay = false; }, PAUSE_HIDE_MS); return; }
    if (this.wantsPlay) this.resume();
  }

  // the system paused the video on the way to the background (not the person): playing on, once
  private resume(): void {
    const v = this.video;
    if (this.resumed || inPip(v) || !v.paused) return;
    this.resumed = true;
    v.play().catch(() => { this.wantsPlay = false; });
  }

  private actions(): void {
    if (!('mediaSession' in navigator)) return;
    const v = this.video, ms = navigator.mediaSession;
    const set = (a: MediaSessionAction, f: MediaSessionActionHandler | null): void => { try { ms.setActionHandler(a, f); } catch { /* not supported here */ } };
    set('play', () => { this.wantsPlay = true; void v.play().catch(() => undefined); });
    set('pause', () => { this.wantsPlay = false; v.pause(); });
    set('stop', () => { this.wantsPlay = false; this.onClose(); });
    set('seekbackward', (d) => { v.currentTime = Math.max(0, v.currentTime - (d.seekOffset ?? SEEK_STEP_S)); });
    set('seekforward', (d) => { v.currentTime = Math.min(v.duration || Infinity, v.currentTime + (d.seekOffset ?? SEEK_STEP_S)); });
    set('seekto', (d) => { if (d.seekTime !== undefined && Number.isFinite(d.seekTime)) v.currentTime = d.seekTime; });
    this.off.push(() => { for (const a of ACTIONS) set(a, null); });
  }

  // the lock screen's seek bar (a live stream has none)
  private position(): void {
    const v = this.video;
    if (!('mediaSession' in navigator) || typeof navigator.mediaSession.setPositionState !== 'function') return;
    try {
      if (Number.isFinite(v.duration) && v.duration > 0) {
        navigator.mediaSession.setPositionState({ duration: v.duration, playbackRate: v.playbackRate || 1, position: Math.min(Math.max(0, v.currentTime), v.duration) });
      } else navigator.mediaSession.setPositionState();
    } catch { /* a position past the end while seeking: the next event sets it */ }
  }

  detach(): void {
    for (const f of this.off.splice(0)) f();
    if ('mediaSession' in navigator) { navigator.mediaSession.metadata = null; try { navigator.mediaSession.playbackState = 'none'; } catch { /* */ } }
    if (inPip(this.video)) void togglePip(this.video).catch(() => undefined);
  }
}
