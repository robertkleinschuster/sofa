// background.ts with stand-ins for the page and two media elements: how iOS treats a Home Screen
// web app (the video paused on the way to the background, an <audio> element let play on).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Background, type BackgroundEnv, type BackgroundHooks } from '../src/background.ts';

class FakeMedia extends EventTarget {
  paused = true; ended = false; currentTime = 0; duration = 600; readyState = 0; playbackRate = 1;
  currentSrc = ''; src = ''; loads = 0; refuse = false;
  private attrs = new Map<string, string>();
  setAttribute(k: string, v: string): void { this.attrs.set(k, v); if (k === 'src') this.src = v; }
  hasAttribute(k: string): boolean { return this.attrs.has(k); }
  removeAttribute(k: string): void { this.attrs.delete(k); if (k === 'src') this.src = ''; }
  load(): void { this.loads++; }
  play(): Promise<void> {
    if (this.refuse) return Promise.reject(new DOMException('not allowed', 'NotAllowedError'));
    if (this.paused) { this.paused = false; this.fire('play'); this.fire('playing'); }
    return Promise.resolve();
  }
  pause(): void { if (!this.paused) { this.paused = true; this.fire('pause'); } }
  fire(ev: string): void { this.dispatchEvent(new Event(ev)); }
}

class FakePage extends EventTarget {
  hidden = false;
  hide(): void { this.hidden = true; this.dispatchEvent(new Event('visibilitychange')); }
  show(): void { this.hidden = false; this.dispatchEvent(new Event('visibilitychange')); }
}

function setup(src = 'https://sofa.example:7443/m/abc/index.m3u8') {
  const video = new FakeMedia(), carrier = new FakeMedia(), page = new FakePage();
  const clocks: string[] = [];
  const hooks: BackgroundHooks = { close: () => undefined, pip: () => undefined, clock: (s) => clocks.push(s) };
  const env = { page, nav: {} as Navigator, carrier } as unknown as BackgroundEnv;
  const bg = new Background(video as unknown as HTMLVideoElement, hooks, env);
  video.currentSrc = src; video.readyState = 1; video.fire('loadedmetadata');
  carrier.readyState = 1;
  return { video, carrier, page, bg, clocks };
}

const tick = (): Promise<void> => new Promise((r) => setTimeout(r, 0));

test('the carrier holds the video\'s stream, ready; a MediaSource stream has none to carry', () => {
  assert.equal(setup().carrier.src, 'https://sofa.example:7443/m/abc/index.m3u8');
  assert.equal(setup('blob:https://x/1').carrier.src, '');
});

test('iOS pauses the video as the app leaves: the carrier plays on from there, the video takes over on return', async () => {
  const { video, carrier, page, bg, clocks } = setup();
  await video.play(); video.currentTime = 123.4;
  page.hide(); video.pause();                     // the system's pause, the page already hidden
  await tick();
  assert.equal(carrier.paused, false);
  assert.equal(carrier.currentTime, 123.4);
  assert.equal(bg.clock, carrier as unknown as HTMLMediaElement);
  assert.deepEqual(clocks, ['playing']);
  carrier.currentTime = 300;                     // listened on with the screen locked
  page.show();
  assert.equal(carrier.paused, true);
  assert.equal(video.paused, false);
  assert.equal(video.currentTime, 300);
  assert.equal(bg.clock, video as unknown as HTMLMediaElement);
});

test('the pause that comes just before the page hides (iOS) is the system\'s too', async () => {
  const { video, carrier, page } = setup();
  await video.play(); video.currentTime = 50;
  video.pause(); page.hide();
  await tick();
  assert.equal(carrier.paused, false);
  assert.equal(carrier.currentTime, 50);
});

test('paused by the person: nothing plays on in the background', async () => {
  const { video, carrier, page } = setup();
  await video.play();
  video.pause();
  await new Promise((r) => setTimeout(r, 1100));  // PAUSE_HIDE_MS: then it was the person's
  page.hide();
  await tick();
  assert.equal(carrier.paused, true);
});

test('a pause on the lock screen pauses the carrier; back in front the video stays paused there', async () => {
  const { video, carrier, page, clocks } = setup();
  await video.play();
  page.hide(); video.pause(); await tick();
  carrier.currentTime = 80; carrier.pause();
  assert.deepEqual(clocks, ['playing', 'paused']);
  page.show();
  assert.equal(video.paused, true);
  assert.equal(video.currentTime, 80);
});

test('a carrier the browser refuses: no carrying, the video is left paused', async () => {
  const { video, carrier, page, bg } = setup();
  carrier.refuse = true;
  await video.play();
  page.hide(); video.pause(); await tick();
  assert.equal(bg.clock, video as unknown as HTMLMediaElement);
  page.show();
  assert.equal(video.paused, true);
});

test('a MediaSource stream: the video itself is asked to play on', async () => {
  const { video, carrier, page } = setup('blob:https://x/1');
  await video.play();
  page.hide(); video.pause(); await tick();
  assert.equal(carrier.paused, true);
  assert.equal(video.paused, false);
});

test('a live stream: the carrier plays from its edge (no seek)', async () => {
  const { video, carrier, page } = setup();
  video.duration = Infinity; carrier.currentTime = 7;
  await video.play(); video.currentTime = 1000;
  page.hide(); video.pause(); await tick();
  assert.equal(carrier.paused, false);
  assert.equal(carrier.currentTime, 7);
});

test('detach empties the carrier', () => {
  const { carrier, bg } = setup();
  bg.detach();
  assert.equal(carrier.src, '');
});
