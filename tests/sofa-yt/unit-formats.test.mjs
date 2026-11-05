// Format / track choice (mirrors ytresolver.py's rules) on real player-response fixtures.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mod, fixturePlayer } from './helpers.mjs';

const F = await mod('lib/formats.mjs');
const { FormatXTags } = await mod('node_modules/googlevideo/dist/src/exports/protos.js');
const { parseRange } = await mod('lib/app.mjs');

const oz = fixturePlayer('OzCYsIrrRyw');
const jnq = fixturePlayer('jNQXAC9IVRw');

test('video: 1080p, VP9 before AV1 before H.264 at equal resolution', () => {
  const f = F.describeFormats(oz.adaptiveFormats);
  const v = F.pickVideo(f);
  assert.equal(v.itag, 248);
  assert.equal(v.codec, 'vp9');
  assert.equal(v.height, 1080);
  assert.equal(F.pickVideo(f, 720).itag, 247);
  const noVp9 = F.describeFormats(oz.adaptiveFormats.filter((x) => !x.mimeType.includes('vp9')));
  assert.equal(F.pickVideo(noVp9).itag, 399, 'AV1 next');
  const avcOnly = F.describeFormats(oz.adaptiveFormats.filter((x) => x.mimeType.includes('avc1') || x.mimeType.startsWith('audio')));
  assert.equal(F.pickVideo(avcOnly).itag, 137, 'H.264 last');
});

test('video: small videos work (no strict quality filter), fps cap', () => {
  const v = F.pickVideo(F.describeFormats(jnq.adaptiveFormats));
  assert.equal(v.itag, 242);
  const hfr = oz.adaptiveFormats.map((x) => (x.itag === 248 ? { ...x, fps: 120 } : x));
  assert.equal(F.pickVideo(F.describeFormats(hfr)).itag, 399, '1080p120 VP9 is skipped');
});

test('audio: no DRC / voice boost, Opus preferred, unique keys', () => {
  const f = F.describeFormats(oz.adaptiveFormats);
  const a = F.pickAudio(f);
  assert.equal(a.itag, 251);
  assert.equal(a.drc, false);
  assert.equal(a.vb, false);
  const keys = f.map((x) => x.key);
  assert.equal(new Set(keys).size, keys.length, 'keys unique');
  assert.deepEqual(F.audioTracks(f), [], 'one language: no choice');
  assert.equal(F.codecOf('audio/mp4; codecs="mp4a.40.2"'), 'mp4a');
  assert.equal(F.codecOf('video/mp4; codecs="av01.0.08M.08"'), 'av01');
});

function xt(tags) {
  return Buffer.from(FormatXTags.encode({ xtags: Object.entries(tags).map(([key, value]) => ({ key, value })) }).finish())
    .toString('base64').replace(/\+/g, '-').replace(/\//g, '_');
}

function multiLang() {
  const base = oz.adaptiveFormats.find((x) => x.itag === 251 && !x.xtags);
  const aac = oz.adaptiveFormats.find((x) => x.itag === 140 && !x.xtags);
  const lang = (src, id, name, tags, extra = {}) => ({ ...src, ...extra, xtags: xt(tags), audioTrack: { id, displayName: name, audioIsDefault: false } });
  return [
    ...oz.adaptiveFormats.filter((x) => !x.mimeType.startsWith('audio')),
    // YouTube marks the auto-dubbed German track as default for a German viewer: must not win
    { ...lang(base, 'de-DE.3', 'German (dubbed-auto)', { acont: 'dubbed-auto', lang: 'de-DE' }), audioTrack: { id: 'de-DE.3', displayName: 'German', audioIsDefault: true } },
    lang(base, 'en.4', 'English original', { acont: 'original', lang: 'en' }, { bitrate: 100000 }),
    lang(aac, 'en.4', 'English original', { acont: 'original', lang: 'en' }, { bitrate: 130000 }),
    lang(base, 'en.4', 'English original', { acont: 'original', lang: 'en', drc: '1' }, { bitrate: 160000, isDrc: true }),
    lang(base, 'fr.3', 'French', { acont: 'dubbed', lang: 'fr' }),
    lang(base, 'es.5', 'Spanish descriptive', { acont: 'descriptive', lang: 'es' }),
  ];
}

test('audio: original track first, never the (default) auto-dubbed one', () => {
  const f = F.describeFormats(multiLang());
  const a = F.pickAudio(f);
  assert.equal(a.lang, 'en');
  assert.equal(a.codec, 'opus', 'Opus before AAC even at lower bitrate');
  assert.equal(a.drc, false);
  const list = F.audioTracks(f);
  assert.equal(list[0].lang, 'en');
  assert.equal(list[0].original, true);
  assert.equal(list[0].format.key, a.key);
  const de = list.find((t) => t.lang === 'de-DE');
  assert.equal(de.dubbed, true);
  assert.equal(list.find((t) => t.lang === 'fr').dubbed, true);
  assert.equal(list.at(-1).described, true, 'audio description last');
});

test('subtitles: auto track of the spoken language; translation only when useful', () => {
  // German video, German auto captions only
  const de = F.subtitleTracks(oz.captions, 'de');
  assert.deepEqual(de.map((t) => [t.kind, t.lang]), [['auto', 'de']]);
  const en = F.subtitleTracks(oz.captions, 'en');
  assert.deepEqual(en.map((t) => [t.kind, t.lang]), [['auto', 'de'], ['translated', 'en']]);
  assert.equal(en[1].tlang, 'en');
  // a manual German track suppresses the translation
  const caps = structuredClone(oz.captions);
  caps.playerCaptionsTracklistRenderer.captionTracks.unshift({ baseUrl: 'https://www.youtube.com/api/timedtext?v=x&lang=fr', languageCode: 'fr', name: { simpleText: 'French' }, vssId: '.fr', isTranslatable: true });
  caps.playerCaptionsTracklistRenderer.captionTracks[1].languageCode = 'fr';
  const fr = F.subtitleTracks(caps, 'fr');
  assert.deepEqual(fr.map((t) => [t.kind, t.lang]), [['manual', 'fr'], ['auto', 'fr']]);
  assert.equal(new Set(fr.map((t) => t.key)).size, fr.length, 'distinct URL keys');
  assert.deepEqual(F.subtitleTracks(null), []);
});

test('Range header parsing', () => {
  assert.equal(parseRange(undefined, 100), null);
  assert.deepEqual(parseRange('bytes=0-', 100), { start: 0, end: 100 });
  assert.deepEqual(parseRange('bytes=10-19', 100), { start: 10, end: 20 });
  assert.deepEqual(parseRange('bytes=90-500', 100), { start: 90, end: 100 });
  assert.deepEqual(parseRange('bytes=-30', 100), { start: 70, end: 100 });
  assert.equal(parseRange('bytes=100-', 100), 'bad');
  assert.equal(parseRange('bytes=0-5,10-20', 100), null, 'multi-range -> whole file');
});
