// lib/report.ts: a view's stats pings as youtube.com's player sent them in the 2026-11-07 capture
// (Firefox 153, "Me at the zoo", 19.013 s, played to the end, then left): the same pings, order,
// parameter order, transports, flush slots (rti/rtn), segments, the pause/end ping, pe=1 and final=1,
// qoe's sequence; fexp and the build number as the player derives them.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mod } from './helpers.ts';

const { ViewReporter, encodeFexp, playerBuild, qclc, secs } = await mod('lib/report.ts');

const T = 'https://s.youtube.com/api/stats';
const COMMON = 'cl=1015688510&docid=VID&ei=EI&fexp=&ns=yt&plid=PL&el=detailpage&len=19&of=OF&vm=VM';
const tracking = {
  playback: `${T}/playback?${COMMON}`, watchtime: `${T}/watchtime?${COMMON}`,
  ptracking: 'https://www.youtube.com/ptracking?ei=EI&oid=OID&plid=PL&pltype=content&ptchn=CH&ptk=youtube_single&video_id=VID',
  qoe: `${T}/qoe?cl=1015688510&docid=VID&ei=EI&el=detailpage&event=streamingstats&fexp=&ns=yt&plid=PL`,
  atr: `${T}/atr?c=WEB&docid=VID&ns=yt`, flushSlots: [10, 20, 30], flushInterval: 40,
};
const client = { cl: '1013419924', fexp: 'v1,100673025,1884', xsrf: 'TOK=', hl: 'de_DE', cr: 'AT', cbrand: 'apple', cbr: 'Firefox', cbrver: '153.0',
  c: 'WEB', cver: '2.20261105.05.01', cos: 'Macintosh', cosver: '10.15', cplatform: 'DESKTOP', view: null };

type Sent = { transport: string; method: string; path: string; q: [string, string][]; raw: string; body: string | null; ct: string | null; at: number };

function harness(lenS = 19.013) {
  let now = 1_000_000;
  const sent: Sent[] = [];
  const r = new ViewReporter({ cpn: '_WC0N7JFHe1jiCPd', tracking, lenS, fmt: 395, afmt: 251 }, client, {
    send: (transport, method, url, body, ct) => {
      const u = new URL(url);
      sent.push({ transport, method, path: u.host + u.pathname, q: [...u.searchParams], raw: u.search, body, ct, at: (now - 1_000_000) / 1000 });
    },
    now: () => now, random: () => 0.5,
    media: () => ({ aheadS: 18.933, bytes: 450833, seconds: 1.149 }),
  });
  /** advance to `t` s after the start, ticking every 250 ms like the engine */
  const at = (t: number) => { while ((now - 1_000_000) / 1000 + 0.25 <= t) { now += 250; r.tick(); } now = 1_000_000 + t * 1000; r.tick(); };
  return { r, sent, at };
}
const keys = (s: Sent) => s.q.map(([k]) => k);
const get = (s: Sent, k: string) => s.q.find(([x]) => x === k)?.[1];
const kind = (s: Sent) => s.path.replace('www.youtube.com/', '').replace('api/stats/', '');

test('the captured view: pings, order and timing', () => {
  const { r, sent, at } = harness();
  r.update({ state: 'buffering', position: 0 });
  at(2.3); r.update({ state: 'playing', position: 0.02 });
  at(21); r.update({ state: 'ended', position: 19.013 });
  at(28.5); r.close();
  assert.deepEqual(sent.map(kind), ['qoe', 'playback', 'ptracking', 'watchtime', 'qoe', 'watchtime', 'watchtime', 'qoe', 'watchtime', 'qoe', 'watchtime']);
  assert.ok(sent.every((s) => s.path.startsWith('www.youtube.com/')), 'all to www.youtube.com, not s.youtube.com');
  const [q1, play, pt, w1, q2, w2, wEnd, qEnd, wPe, qClose, wFinal] = sent as [Sent, Sent, Sent, Sent, Sent, Sent, Sent, Sent, Sent, Sent, Sent];
  assert.ok(q1.at >= 1.2 && q1.at < 1.5, 'qoe seq 1 before playing');
  // stats/playback exactly as the player ordered it
  assert.deepEqual(keys(play), ['ns', 'el', 'cpn', 'ver', 'cmt', 'fmt', 'fs', 'rt', 'euri', 'lact', 'cl', 'mos', 'volume', 'cbrand', 'cbr', 'cbrver', 'c', 'cver',
    'cplayer', 'cos', 'cosver', 'cplatform', 'hl', 'cr', 'len', 'fexp', 'rtn', 'afmt', 'muted', 'docid', 'ei', 'plid', 'of', 'vm']);
  assert.match(play.raw, /&euri&lact=/, 'euri bare, like the player');
  assert.match(play.raw, /fexp=v1%2C100673025%2C1884/, 'fexp commas encoded');
  assert.equal(get(play, 'cl'), '1013419924', 'the player build, not the base URL\'s cl');
  assert.equal(get(play, 'len'), '19.013');
  assert.equal(get(play, 'rtn'), '8');
  assert.deepEqual([play.transport, play.method, play.ct, play.body], ['xhr', 'POST', 'application/x-www-form-urlencoded', 'session_token=TOK%3D']);
  assert.deepEqual(keys(pt), ['html5', 'video_id', 'cpn', 'ei', 'ptk', 'oid', 'ptchn', 'pltype']);
  assert.deepEqual([pt.transport, pt.method, pt.body], ['fetch', 'GET', null]);
  // scheduled watchtime: slot 8, next 18; the played segment
  assert.deepEqual(keys(w1), ['ns', 'el', 'cpn', 'ver', 'cmt', 'fmt', 'fs', 'rt', 'euri', 'lact', 'cl', 'state', 'volume', 'cbrand', 'cbr', 'cbrver', 'c', 'cver',
    'cplayer', 'cos', 'cosver', 'cplatform', 'hl', 'cr', 'len', 'rtn', 'afmt', 'idpj', 'ldpj', 'rti', 'st', 'et', 'muted', 'docid', 'ei', 'plid', 'of', 'vm']);
  // due at slot 8 (the engine's 250-ms tick: within a quarter second); the segment up to then
  assert.ok(w1.at >= 8 && w1.at < 8.25, `slot 8 (at ${w1.at})`);
  assert.deepEqual([get(w1, 'state'), get(w1, 'rti'), get(w1, 'rtn'), get(w1, 'st'), get(w1, 'et')], ['playing', '8', '18', '0.02', secs(0.02 + w1.at - 2.3)]);
  assert.ok(q2.at >= 10 && q2.at < 10.25, 'qoe seq 2 after ~10 s');
  assert.ok(w2.at >= 18 && w2.at < 18.25, `slot 18 (at ${w2.at})`);
  assert.deepEqual([get(w2, 'rti'), get(w2, 'rtn'), get(w2, 'st'), get(w2, 'et')], ['18', '28', get(w1, 'et'), secs(0.02 + w2.at - 2.3)]);
  // the end: a paused ping on the pending slot, no rtn; qoe with EN
  assert.deepEqual([get(wEnd, 'state'), get(wEnd, 'rti'), get(wEnd, 'rtn'), get(wEnd, 'st'), get(wEnd, 'et')], ['paused', '28', undefined, get(w2, 'et'), '19.013']);
  assert.match(get(qEnd, 'vps')!, /:EN$/);
  // leaving: pe=1, qoe N/SU, final=1 (after cplatform), neither with rti/rtn
  assert.deepEqual([get(wPe, 'pe'), get(wPe, 'rti'), get(wPe, 'final'), get(wPe, 'st'), get(wPe, 'et')], ['1', undefined, undefined, '19.013', '19.013']);
  assert.match(get(qClose, 'vps')!, /:N,.*:SU$/);
  assert.equal(get(wFinal, 'final'), '1');
  assert.equal(keys(wFinal).indexOf('final'), keys(wFinal).indexOf('cplatform') + 1);
  // qoe: text body (fetch), the player's order, seq and qclc
  assert.deepEqual([q2.transport, q2.ct, q2.body], ['fetch', null, 'session_token=TOK%3D']);
  assert.deepEqual(keys(q1).slice(0, 13), ['fmt', 'cpn', 'el', 'ns', 'fexp', 'cl', 'dai', 'seq', 'docid', 'ei', 'event', 'plid', 'cbrand']);
  assert.equal(get(q1, 'cat'), 'streaming,sabr');
  assert.equal(get(q2, 'afmt'), '251', 'afmt from seq 2 on');
  assert.deepEqual(sent.filter((s) => kind(s) === 'qoe').map((s) => get(s, 'seq')), ['1', '2', '3', '4']);
  assert.equal(get(q2, 'qclc'), qclc('_WC0N7JFHe1jiCPd', 2));
  assert.ok(sent.every((s) => get(s, 'cpn') === '_WC0N7JFHe1jiCPd'), 'one cpn for the whole view');
});

test('qclc: the protobuf {cpn, seq} the capture carried', () => {
  assert.equal(qclc('_WC0N7JFHe1jiCPd', 1), 'ChBfV0MwTjdKRkhlMWppQ1BkEAE');
  assert.equal(qclc('_WC0N7JFHe1jiCPd', 2), 'ChBfV0MwTjdKRkhlMWppQ1BkEAI');
});

test('fexp: the page\'s experiment ids, large ones first, as deltas (captured)', () => {
  assert.equal(encodeFexp('24004644,39325854,51063643,100673025,100674909'), 'v1,100673025,1884,-76670265,15321210,11737789');
});

test('build number from the player script', () => {
  assert.equal(playerBuild('b.fexp=Kpa(x).toString();b.cl=(1013419924).toString();c=1'), '1013419924');
  assert.equal(playerBuild('no build here'), '');
});

test('seconds: 3 decimals, no trailing zeros', () => {
  assert.equal(secs(6.8), '6.8');
  assert.equal(secs(19.0129), '19.013');
  assert.equal(secs(0), '0');
});

test('a pause and a seek: pause ping, then the segments as lists', () => {
  const { r, sent, at } = harness(600);
  r.update({ state: 'playing', position: 0 });
  at(3); r.update({ state: 'paused', position: 3 });
  at(5); r.update({ state: 'playing', position: 3 });
  at(6); r.update({ state: 'playing', position: 60 });   // a seek ahead
  at(8);
  const w = sent.filter((s) => kind(s) === 'watchtime');
  assert.deepEqual([get(w[0]!, 'state'), get(w[0]!, 'st'), get(w[0]!, 'et'), get(w[0]!, 'rti')], ['paused', '0', '3', '8'], 'pause ping takes the slot');
  assert.equal(w.length, 1, 'the next slot (18) is not due yet');
  at(18);
  const w2 = sent.filter((s) => kind(s) === 'watchtime')[1]!;
  assert.deepEqual([get(w2, 'st'), get(w2, 'et')], ['3,60', '4,72'], 'segments before and after the seek');
});

test('lact: time since the last key press Sofa reported', () => {
  const { r, sent, at } = harness();
  at(1); r.update({ state: 'playing', position: 0, lactMs: 400 });
  assert.equal(get(sent.find((s) => kind(s) === 'playback')!, 'lact'), '400');
});

test('a rebuffer keeps the segment; nothing plays while paused: slots pass silently', () => {
  const { r, sent, at } = harness(600);
  r.update({ state: 'playing', position: 0 });
  at(4); r.update({ state: 'buffering', position: 4 });
  at(5); r.update({ state: 'playing', position: 4 });
  at(8);
  const w = sent.filter((s) => kind(s) === 'watchtime');
  assert.deepEqual([get(w[0]!, 'st'), get(w[0]!, 'et')], ['0', '7'], 'one segment across the rebuffer');
  r.update({ state: 'paused', position: 7 });
  const n = sent.filter((s) => kind(s) === 'watchtime').length;
  at(60);
  assert.equal(sent.filter((s) => kind(s) === 'watchtime').length, n, 'no pings while paused');
});

test('no stats/playback before it plays; a view that never played leaves without watchtime', () => {
  const { r, sent, at } = harness();
  r.update({ state: 'buffering', position: 0 });
  at(15); r.close();
  assert.deepEqual(sent.map(kind), ['qoe', 'qoe']);
  r.update({ state: 'playing', position: 0 });
  assert.equal(sent.length, 2, 'a closed view stays closed');
});
