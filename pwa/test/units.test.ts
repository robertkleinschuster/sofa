// Pure parts of the PWA: run with `node --test test/` (Node strips the types).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { codeFromHash, discoveryURL, hostFromHash, needsDiscovery, normalizeHost, shortName } from '../src/connection.ts';
import { parseRoute, routeHash, type Route } from '../src/router.ts';
import { isOpaque, recolor, LOGO_LIGHT_TEXT, LOGO_ORIGINAL, LOGO_WHITE } from '../src/logos.ts';
import { themeVariables } from '../src/theme.ts';
import { downloadChoices, type DownloadAction } from '../src/choices.ts';
import { browserFormats } from '../src/formats.ts';
import type { DownloadState } from '../src/types.ts';

test('host names: what the user types becomes host:port', () => {
  assert.equal(normalizeHost('imac'), 'imac:7443');
  assert.equal(normalizeHost('  IMAC  '), 'imac:7443');
  assert.equal(normalizeHost('imac:8443'), 'imac:8443');
  assert.equal(normalizeHost('https://mac.example.org/x'), 'mac.example.org:7443');
  assert.equal(normalizeHost(''), null);
  assert.equal(normalizeHost('ima c'), null);
  assert.equal(normalizeHost('imac:99999'), null);
  assert.equal(normalizeHost('-imac'), null);
});

test('a short name is learned through the connect route; a full name goes straight to TLS', () => {
  assert.equal(needsDiscovery('imac:7443'), true);
  assert.equal(needsDiscovery('imac.example.org:7443'), false);
  assert.equal(discoveryURL('imac:7443', 'https://x.github.io/sofa/'), 'http://imac:7443/connect?return=https%3A%2F%2Fx.github.io%2Fsofa%2F');
  assert.equal(shortName('imac.example.org:7443'), 'imac');
});

test('the connect redirect hands back the full name in the fragment', () => {
  assert.equal(hostFromHash('#host=imac.example.org:7443'), 'imac.example.org:7443');
  assert.equal(hostFromHash('#/app/zdf&host=imac.example.org%3A7443'), 'imac.example.org:7443');
  assert.equal(hostFromHash('#/'), null);
  assert.equal(hostFromHash('#host=<script>'), null);
});

test('the TV\'s pairing link (QR code) carries the full name and the code', () => {
  const hash = '#host=imac.example.org:7443&code=042137';
  assert.equal(hostFromHash(hash), 'imac.example.org:7443');
  assert.equal(codeFromHash(hash), '042137');
  assert.equal(codeFromHash('#host=imac.example.org:7443'), null);
  assert.equal(codeFromHash('#host=a:1&code=12345'), null, 'six digits only');
  assert.equal(codeFromHash('#host=a:1&code=1234567'), null);
});

test('routes round-trip through the hash', () => {
  const routes: Route[] = [
    { name: 'home' }, { name: 'app', id: 'youtube' }, { name: 'page', handle: 'abc123', title: 'Tatort & mehr', theme: 'ard' },
    { name: 'show', ref: 'zdf:show:x/y', title: 'heute' }, { name: 'search', app: 'zdf', q: 'Wetter ü' },
    { name: 'search', app: 'zdf' }, { name: 'connect' }, { name: 'pair' }, { name: 'settings' },
  ];
  for (const r of routes) assert.deepEqual(parseRoute(routeHash(r)), r);
  assert.deepEqual(parseRoute(''), { name: 'home' });
  assert.deepEqual(parseRoute('#host=x'), { name: 'home' });
  assert.deepEqual(parseRoute('#/nope'), { name: 'home' });
  assert.deepEqual(parseRoute('#/app/'), { name: 'home' });
});

test('logos: the variants recolour as SFLogo.m does', () => {
  const px = (...rgba: number[]): Uint8ClampedArray => new Uint8ClampedArray(rgba);
  const white = px(250, 250, 250, 255), dark = px(20, 20, 20, 255), red = px(220, 20, 30, 255);
  const run = (p: Uint8ClampedArray, v: number, knock: boolean): number[] => { const c = new Uint8ClampedArray(p); recolor(c, v, knock); return [...c]; };
  assert.deepEqual(run(white, LOGO_ORIGINAL, true), [0, 0, 0, 0], 'white background cut out');
  assert.deepEqual(run(white, LOGO_ORIGINAL, false), [250, 250, 250, 255], 'kept with alpha');
  assert.deepEqual(run(dark, LOGO_LIGHT_TEXT, false), [255, 255, 255, 255], 'dark text turns white');
  assert.deepEqual(run(red, LOGO_LIGHT_TEXT, false), [220, 20, 30, 255], 'colour stays');
  assert.deepEqual(run(red, LOGO_WHITE, false), [255, 255, 255, 255]);
  assert.equal(isOpaque(px(1, 2, 3, 255, 4, 5, 6, 255)), true);
  assert.equal(isOpaque(px(1, 2, 3, 255, 4, 5, 6, 0)), false);
});

test('theme tokens become CSS variables, with the base theme for what is missing', () => {
  const v = themeVariables({ fonts: { regular: '', medium: '', bold: '', wordmark: '' }, corner: 6, light: true, uppercaseHeaders: true, headerMark: 'bar', accent: 'rgba(250,120,0,1)' }, null);
  assert.equal(v['--corner'], '6px');
  assert.equal(v['--accent'], 'rgba(250,120,0,1)');
  assert.equal(v['--progress'], 'rgba(250,120,0,1)', 'light themes draw progress in the accent');
  assert.equal(v['--bg'], 'rgba(16,17,20,1)');
  assert.equal(v['--header-case'], 'uppercase');
  assert.match(v['--font']!, /system-ui/);
  const d = themeVariables({ fonts: { regular: 'AvenirNext-Regular', medium: '', bold: '', wordmark: '' }, corner: 10, light: false, uppercaseHeaders: false, headerMark: 'none' }, null);
  assert.match(d['--font']!, /^"sofa-AvenirNext-Regular", system-ui/);
  assert.equal(d['--progress'], 'rgba(255,255,255,1)');
});

test('the download options follow the TV menu for each state', () => {
  const run = (dl?: DownloadState): string[] => {
    const acts: DownloadAction[] = [];
    const choices = downloadChoices({ kind: 'video', ...(dl ? { dl } : {}) }, (a) => acts.push(a));
    for (const c of choices) void c.run();
    return choices.map((c, i) => `${c.label}${c.detail ? ` (${c.detail})` : ''} -> ${acts[i]}`);
  };
  assert.deepEqual(run(), []);
  assert.deepEqual(run({ state: 'none' }), ['Herunterladen -> start']);
  assert.deepEqual(run({ state: 'queued' }), ['Download abbrechen (wartet) -> cancel']);
  assert.deepEqual(run({ state: 'running', progress: 0.416 }), ['Download abbrechen (42 %) -> cancel']);
  assert.deepEqual(run({ state: 'failed', failure: 'Quelle antwortet nicht' }), ['Erneut herunterladen (Quelle antwortet nicht) -> start', 'Aus Downloads entfernen -> remove']);
  assert.deepEqual(run({ state: 'done', kept: false }), ['Behalten (Aus) -> keep', 'Download löschen -> delete']);
  assert.deepEqual(run({ state: 'done', kept: true }), ['Behalten (An) -> unkeep', 'Download löschen -> delete']);
});

test('formats: newest first, hardware before software, Apple\'s HLS codecs for the browser\'s own player', async () => {
  type P = Record<string, [boolean, boolean]>;   // codec -> [supported, in hardware]
  const prober = (p: P) => async (c: string) => ({ supported: p[c]?.[0] ?? false, efficient: p[c]?.[1] ?? false });
  // iPhone 17 Pro (AV1 in hardware), native HLS: VP9/Opus not asked even where a probe says yes
  assert.deepEqual(await browserFormats(prober({ av01: [true, true], hvc1: [true, true], avc1: [true, true], vp09: [true, true], mp4a: [true, true], opus: [true, true] }), true),
    ['av01', 'hvc1', 'avc1', 'mp4a']);
  // an older iPhone: no AV1; H.264 + AAC whatever a probe says
  assert.deepEqual(await browserFormats(prober({ hvc1: [true, true] }), true), ['hvc1', 'avc1', 'mp4a']);
  // a Mac decoding AV1 only in software: left out while VP9/H.264 decode in hardware
  assert.deepEqual(await browserFormats(prober({ av01: [true, false], vp09: [true, true], avc1: [true, true], opus: [true, true], mp4a: [true, true] }), false),
    ['vp09', 'avc1', 'opus', 'mp4a']);
  // this Mac's Firefox: nothing in hardware - what it decodes, newest first
  assert.deepEqual(await browserFormats(prober({ vp09: [true, false], av01: [true, false], opus: [true, true] }), false), ['av01', 'vp09', 'opus']);
  assert.deepEqual(await browserFormats(async () => { throw new Error('no'); }, false), []);
});
