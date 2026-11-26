// What tools/test-api does with the dev instance, step by step - every operation of the contract as a
// client uses it, and the wrong uses that have a documented answer (their error codes).

import { statSync } from 'node:fs';
import { join } from 'node:path';
import type { Answer, Call } from './client.ts';

export interface Tools {
  api: (path: string, opts?: Omit<Call, 'path'>) => Promise<Answer>;
  check: (m: string, cond: boolean, got?: unknown) => void;
  ok: (m: string) => void; bad: (m: string) => void; note: (m: string) => void;
  sleep: (ms: number) => Promise<void>;
  waitLog: (re: RegExp, ms?: number, from?: number) => Promise<RegExpMatchArray>;
  pairingCode: () => Promise<string>;
  items: (page: Answer) => (Record<string, unknown> & { d?: Record<string, unknown>; id?: string })[];
  itemOf: (page: Answer, id: string) => Record<string, unknown>;
  log: () => string;
  name: string; port: number; data: string;
}
export interface State { token: string; img: string }

const V1 = '/api/v1';
const codeOf = (a: Answer): unknown => a.json?.code;

async function until<T>(t: Tools, what: string, f: () => Promise<T | null | undefined | false>, ms = 30_000): Promise<T> {
  const deadline = Date.now() + ms;
  for (;;) {
    const v = await f();
    if (v) return v;
    if (Date.now() > deadline) throw new Error(`${what}: not within ${ms / 1000} s`);
    await t.sleep(250);
  }
}

export async function scenario(t: Tools): Promise<State> {
  const { api, check } = t;
  console.log('==> connect: discover, the connect redirect, hello, pairing');
  const disc = await api('/discover', { plain: true });
  check('discover: the full name for the short one (plain HTTP)', disc.status === 200 && disc.json?.host === t.name && disc.json?.port === t.port, disc.json);
  check('discover: no CORS on plain HTTP', !('access-control-allow-origin' in disc.headers));
  const red = await api(`/connect?return=${encodeURIComponent('https://pwa.test/app/')}`, { plain: true, headers: { Origin: 'https://pwa.test' } });
  check('connect: 303 back to the PWA with the full name', red.status === 303 && red.headers.location === `https://pwa.test/app/#host=${t.name}:${t.port}`, red.headers.location);
  check('connect: a foreign return address is refused', (await api(`/connect?return=${encodeURIComponent('https://evil.test/')}`, { plain: true })).status === 400);
  const hello = await api(`${V1}/hello`);
  check('hello: the API versions and features', hello.json?.api?.version === 1 && hello.json?.api?.min === 1 && hello.json?.features?.includes('session-formats'), hello.json);
  check('hello: /api/hello is the same route (the PWA\'s paths)', JSON.stringify((await api('/api/hello')).json?.api) === JSON.stringify(hello.json?.api));
  const v2 = await api('/api/v2/hello');
  check('an unknown API version: 404 unsupported_version', v2.status === 404 && codeOf(v2) === 'unsupported_version', v2.json);
  // every route but hello and pair wants a paired device's token
  const anon: Answer[] = [];
  for (const path of ['info', 'home', 'app/example', `page/${'0'.repeat(32)}`, `more/${'0'.repeat(32)}`, 'show?ref=x', 'search?app=example', 'suggest?app=example&q=x', 'status'])
    anon.push(await api(`${V1}/${path}`));
  for (const [path, json] of [['play', { item: { id: 'x' } }], [`stream/${'0'.repeat(32)}`, { state: 'paused' }], ['state', { item: { id: 'x' } }],
    ['tv/play', { item: { id: 'x' } }], ['tv/control', { action: 'pause' }]] as const) anon.push(await api(`${V1}/${path}`, { json }));
  anon.push(await api(`${V1}/pair`, { method: 'DELETE' }));
  check('no token: 401 not_paired everywhere but hello and pair', anon.every((a) => a.status === 401 && codeOf(a) === 'not_paired'), anon.map((a) => a.status));

  const closed = await api(`${V1}/pair`, { json: { code: '123456', name: 'Test' } });
  check('pair: no code on the TV: 410 no_pairing_open', closed.status === 410 && codeOf(closed) === 'no_pairing_open', closed.json);
  const code = await t.pairingCode();
  const wrong = String((Number(code) + 1) % 1_000_000).padStart(6, '0');
  const w = await api(`${V1}/pair`, { json: { code: wrong, name: 'Test' } });
  check('pair: a wrong code: 403 wrong_code', w.status === 403 && codeOf(w) === 'wrong_code', w.json);
  const tv = await api(`${V1}/pair`, { json: { code, name: 'Test', client: { kind: 'tv' } }, invalid: true });
  check('pair: an unknown client kind: 400 bad_request', tv.status === 400 && codeOf(tv) === 'bad_request', tv.json);
  const paired = await api(`${V1}/pair`, { json: { code: code.slice(0, 3) + ' ' + code.slice(3), name: 'iPhone von Test', client: { kind: 'ios', app: 'Sofa', version: '1.0 (1)' } } });
  check('pair: the TV\'s code pairs (a token)', paired.status === 200 && /^[0-9a-f]{64}$/.test(paired.json?.token ?? ''), paired.json);
  const token: string = paired.json.token;
  check('pair: the client is recorded (iOS app, its version)', /web: paired device [0-9a-f]{16} \(iPhone von Test, ios Sofa 1\.0 \(1\)\)/.test(t.log()));
  const second = await api(`${V1}/pair`, { json: { code: await t.pairingCode(), name: 'Browser' } });
  check('pair: without `client` a device is the PWA (web)', second.status === 200 && /paired device [0-9a-f]{16} \(Browser, web\)/.test(t.log()), second.json);
  check('hello with the token: paired', (await api(`${V1}/hello`, { token })).json?.paired === true);
  const unknown = await api(`${V1}/nothing-here`, { token, offContract: true });
  check('an unknown route: 404 not_found (with a token - without one every route is 401)', unknown.status === 404 && codeOf(unknown) === 'not_found', unknown.json);

  console.log('==> browse');
  const info = await api(`${V1}/info`, { token });
  check('info: the apps, themes, this device', info.status === 200 && info.json?.apps?.[0]?.id === 'example' && info.json?.device === 'iPhone von Test', info.json?.device);
  const home = await api(`${V1}/home`, { token });
  check('home: a page', home.status === 200 && Array.isArray(home.json?.shelves));
  const page = await api('/api/app/example', { token });
  check('the app\'s start page (through /api/: the same route)', page.status === 200 && t.items(page).some((i) => i.id === 'example:1'));
  const handle = t.items(home).find((i) => typeof i.page === 'string')?.page as string;
  check('page: a folder\'s page by its handle', (await api(`${V1}/page/${handle}`, { token })).status === 200);
  const gone = await api(`${V1}/page/${'0'.repeat(32)}`, { token });
  check('page: an unknown handle: 410 page_gone', gone.status === 410 && codeOf(gone) === 'page_gone', gone.json);
  const moreHandle = (page.json.shelves as { more?: string }[]).find((s) => s.more)?.more;
  const more = await api(`${V1}/more/${moreHandle}`, { token });
  check('more: the next portion of a shelf', more.status === 200 && more.json?.items?.length > 0, more.json);
  check('more: an unknown handle: 410 page_gone', codeOf(await api(`${V1}/more/${'0'.repeat(32)}`, { token })) === 'page_gone');
  check('show: a show page by ref', (await api(`${V1}/show?ref=exampleshow:demo&title=Beispielsendung`, { token })).status === 200);
  check('show: no show ref: 404 not_found', codeOf(await api(`${V1}/show?ref=nothing`, { token })) === 'not_found');
  check('app: no such app: 404 not_found', codeOf(await api(`${V1}/app/nothing`, { token })) === 'not_found');
  check('search: the recent searches', Array.isArray((await api(`${V1}/search?app=example`, { token })).json?.recent));
  check('search: a query is a page', t.items(await api(`${V1}/search?app=example&q=Test`, { token })).some((i) => i.id === 'example:1'));
  const nosearch = await api(`${V1}/search?app=nothing&q=x`, { token });
  check('search: no such app: 404 no_search', nosearch.status === 404 && codeOf(nosearch) === 'no_search', nosearch.json);
  const idle = await api(`${V1}/status`, { token });
  check('status: nothing on the TV, no downloads', idle.status === 200 && idle.json?.tv === null && idle.json?.downloads?.length === 0, idle.json);
  check('suggest: a list', Array.isArray((await api(`${V1}/suggest?app=example&q=Te`, { token })).json?.list));

  console.log('==> marks');
  const one = t.itemOf(page, 'example:1'), show = t.itemOf(page, 'exampleshow:demo');
  check('state: Später ansehen', (await api(`${V1}/state`, { token, json: { item: one, later: true } })).json?.item?.later === true);
  check('state: watched', (await api(`${V1}/state`, { token, json: { item: one, watched: true } })).json?.item?.watched === true);
  await api(`${V1}/state`, { token, json: { item: one, watched: false, later: false, forget: true } });
  check('state: follow a show', (await api(`${V1}/state`, { token, json: { item: show, follow: true } })).json?.item?.following === true);
  const noitem = await api(`${V1}/state`, { token, json: { item: {} }, invalid: true });
  check('state: no item: 400 unknown_item', noitem.status === 400 && codeOf(noitem) === 'unknown_item', noitem.json);
  const noref = { ...one }; delete noref.ref;
  const nodl = await api(`${V1}/state`, { token, json: { item: noref, download: true } });
  check('state: no resolver: 400 not_downloadable', nodl.status === 400 && codeOf(nodl) === 'not_downloadable', nodl.json);

  console.log('==> play: formats, streams, reports');
  const play = async (item: Record<string, unknown>, formats?: string[]): Promise<Answer> =>
    api(`${V1}/play`, { token, json: formats ? { item, formats } : { item } });
  const h264 = await play(one, ['avc1', 'mp4a']);
  check('play: an H.264 + AAC client gets the DASH pair as HLS', h264.status === 200 && h264.json?.kind === 'hls' && !h264.json?.segmented, h264.json);
  const sid: string = h264.json.stream, url: string = h264.json.url;
  check('media: the HLS master', (await api(url)).headers['content-type'] === 'application/vnd.apple.mpegurl');
  await api(url.replace('index.m3u8', 'v.m3u8'));
  const range = await api(url.replace('index.m3u8', 't/v'), { headers: { Range: 'bytes=0-99' } });
  check('media: track bytes by Range (206)', range.status === 206 && range.body.length === 100, range.status);
  check('report: playing', (await api(`${V1}/stream/${sid}`, { token, json: { state: 'playing', position: 5, duration: 4 } })).status === 200);
  const badState = await api(`${V1}/stream/${sid}`, { token, json: { state: 'flying' }, invalid: true });
  check('report: an unknown state: 400 bad_state', badState.status === 400 && codeOf(badState) === 'bad_state', badState.json);
  const noStream = await api(`${V1}/stream/${'0'.repeat(32)}`, { token, json: { state: 'paused' } });
  check('report: no such stream: 404 stream_gone', noStream.status === 404 && codeOf(noStream) === 'stream_gone', noStream.json);
  check('report: the beacon on the capability path', (await api(`/m/${sid}/state`, { text: JSON.stringify({ state: 'paused', position: 2, duration: 4 }) })).status === 200);
  check('report: a beacon of an unknown state: 400', (await api(`/m/${sid}/state`, { text: JSON.stringify({ state: 'flying' }) })).status === 400);
  const noMedia = await api(url.replace('index.m3u8', 'nothing.m3u8'));
  check('media: no such resource of the stream: 404', noMedia.status === 404 && codeOf(noMedia) === 'not_found', noMedia.json);
  await api(`${V1}/stream/${sid}`, { token, json: { state: 'closed' } });
  check('report: a beacon of an ended stream: 404', (await api(`/m/${sid}/state`, { text: JSON.stringify({ state: 'closed' }) })).status === 404);
  const ended = await api(url);
  check('media: a closed stream: 410 stream_gone (play again)', ended.status === 410 && codeOf(ended) === 'stream_gone', ended.json);

  const vp9 = await play(one, ['vp09', 'opus', 'avc1', 'mp4a']);
  check('play: a client preferring VP9 + Opus gets the app\'s VP9 session, copied into segments', vp9.status === 200 && vp9.json?.segmented === 'copy+copy', vp9.json);
  check('play: ... the app was asked in the client\'s order', /example: browser format for example:1 \(vp09\+opus\)/.test(t.log()));
  const seg: string = vp9.json?.url ?? '';
  check('media: the segmented playlist, its init and first segment', (await api(seg)).status === 200
    && (await api(seg.replace('index.m3u8', 'init.mp4'))).status === 200 && (await api(seg.replace('index.m3u8', 's/0.m4s'))).headers['content-type'] === 'video/mp4');
  await api(`${V1}/stream/${vp9.json?.stream}`, { token, json: { state: 'closed' } });
  const drm = await play({ ...one, drm: true });
  check('play: copy-protected: 403 drm', drm.status === 403 && codeOf(drm) === 'drm', drm.json);
  const folder = await play(show);
  check('play: a folder: 400 not_video', folder.status === 400 && codeOf(folder) === 'not_video', folder.json);
  check('play: no item: 400 unknown_item', codeOf(await api(`${V1}/play`, { token, json: { item: {} }, invalid: true })) === 'unknown_item');

  console.log('==> downloads');
  const two = t.itemOf(page, 'example:2');
  const dl = await api(`${V1}/state`, { token, json: { item: two, download: true } });
  check('download: started (what the TV would say)', dl.status === 200 && typeof dl.json?.message === 'string' && dl.json.message.length > 0, dl.json);
  await until(t, 'the download', async () => (await api(`${V1}/state`, { token, json: { item: two } })).json?.item?.dl?.state === 'done', 60_000);
  t.ok('download: done');
  check('download: Behalten', (await api(`${V1}/state`, { token, json: { item: two, keep: true } })).json?.item?.dl?.kept === true);
  const file = await play(two, ['avc1', 'mp4a']);
  check('play: a stored MP4 of the client\'s codecs is a file', file.json?.kind === 'file', file.json);
  check('media: the file by Range', (await api(file.json?.url ?? '/m/x/media', { headers: { Range: 'bytes=0-15' } })).status === 206);
  check('media: a range beyond the end: 416', (await api(file.json?.url ?? '/m/x/media', { headers: { Range: 'bytes=999999999-' } })).status === 416);
  await api(`${V1}/stream/${file.json?.stream}`, { token, json: { state: 'closed' } });
  check('download: deleted', (await api(`${V1}/state`, { token, json: { item: two, download: false } })).json?.item?.dl?.state === 'none');

  console.log('==> the TV');
  const three = t.itemOf(page, 'example:3');
  check('tv: play', (await api(`${V1}/tv/play`, { token, json: { item: three } })).status === 200);
  const st = await until(t, 'the TV playing', async () => { const s = await api(`${V1}/status`, { token }); return s.json?.tv?.state === 'playing' ? s : null; });
  check('status: the TV\'s player', st.json.tv.item.id === 'example:3');
  check('status: a stale generation answers at once', (await api(`${V1}/status?since=0-0`, { token, timeoutMs: 5_000 })).status === 200);
  const busy = await api(`${V1}/tv/play`, { token, json: { item: one } });
  check('tv: another video plays: 409 tv_busy, naming it', busy.status === 409 && codeOf(busy) === 'tv_busy' && busy.json?.busy?.title === 'Mandelbrot', busy.json);
  check('tv: pause', (await api(`${V1}/tv/control`, { token, json: { action: 'pause' } })).status === 200);
  const badAction = await api(`${V1}/tv/control`, { token, json: { action: 'jump' }, invalid: true });
  check('tv: an unknown action: 400 bad_action', badAction.status === 400 && codeOf(badAction) === 'bad_action', badAction.json);
  check('tv: stop', (await api(`${V1}/tv/control`, { token, json: { action: 'stop' } })).status === 200);
  await until(t, 'the TV idle', async () => (await api(`${V1}/status`, { token })).json?.tv === null);
  const tvIdle = await api(`${V1}/tv/control`, { token, json: { action: 'pause' } });
  check('tv: nothing plays: 404 tv_idle', tvIdle.status === 404 && codeOf(tvIdle) === 'tv_idle', tvIdle.json);
  const tvNoItem = await api(`${V1}/tv/play`, { token, json: { item: {} }, invalid: true });
  check('tv: no item: 400 unknown_item', tvNoItem.status === 400 && codeOf(tvNoItem) === 'unknown_item', tvNoItem.json);
  check('tv: copy-protected: 403 drm', codeOf(await api(`${V1}/tv/play`, { token, json: { item: { ...one, drm: true } } })) === 'drm');

  console.log('==> pictures');
  const img = t.items(page).find((i) => i.id === 'example:1')?.img as string;
  const pic = await api(`${img}&w=128`);
  check('image: a picture Sofa handed out', pic.status === 200 && /^image\/(png|jpeg)$/.test(pic.headers['content-type'] ?? ''), pic.status);
  const forged = await api(`/img/${'0'.repeat(32)}?u=${encodeURIComponent('/etc/passwd')}`);
  check('image: a path Sofa did not hand out: 403 bad_signature', forged.status === 403 && codeOf(forged) === 'bad_signature', forged.json);
  const keyMode = statSync(join(t.data, 'web/image.key')).mode & 0o777;
  check('image: the signing key is a file of the data folder, 0600', keyMode === 0o600, keyMode.toString(8));

  console.log('==> unpairing, too many wrong codes');
  check('unpair: the device itself', (await api(`${V1}/pair`, { method: 'DELETE', token: second.json.token })).status === 200);
  check('unpair: its token stops working', (await api(`${V1}/info`, { token: second.json.token })).status === 401);
  await t.pairingCode();
  let limited: Answer | null = null;
  for (let k = 0; k < 12 && !limited; k++) {
    const a = await api(`${V1}/pair`, { json: { code: 'x' + k, name: 'Test' } });
    if (a.status === 429) limited = a;
  }
  check('pair: too many wrong codes: 429 rate_limited', codeOf(limited ?? ({} as Answer)) === 'rate_limited', limited?.json);
  return { token, img };
}

// After a restart on the same data folder, with short stream lifetimes (idle 2 s, paused 8 s)
export async function afterRestart(t: Tools, s: State): Promise<void> {
  const { api, check } = t;
  check('restart: the pairing stays', (await api(`${V1}/hello`, { token: s.token })).json?.paired === true);
  check('restart: a picture URL handed out before still works (the key is kept)', (await api(`${s.img}&w=128`)).status === 200);
  const page = await api(`${V1}/app/example`, { token: s.token });
  const one = t.itemOf(page, 'example:1'), two = t.itemOf(page, 'example:3');
  const a = await api(`${V1}/play`, { token: s.token, json: { item: one, formats: ['avc1', 'mp4a'] } });
  const b = await api(`${V1}/play`, { token: s.token, json: { item: two, formats: ['avc1', 'mp4a'] } });
  await api(`${V1}/stream/${a.json.stream}`, { token: s.token, json: { state: 'paused', position: 3, duration: 4 } });
  await api(`${V1}/stream/${b.json.stream}`, { token: s.token, json: { state: 'playing', position: 1, duration: 4 } });
  await t.waitLog(new RegExp(`web: stream ${String(b.json.stream).slice(0, 6)} ended \\(unused\\)`), 15_000);
  check('streams: an unused one ends after the idle time', (await api(b.json.url, { offContract: true })).status === 410);
  check('streams: a paused one is still there', (await api(a.json.url)).status === 200);
  await t.waitLog(new RegExp(`web: stream ${String(a.json.stream).slice(0, 6)} ended \\(paused too long\\)`), 20_000);
  check('streams: a paused one ends after its longer time (410: play again)', (await api(a.json.url)).status === 410);
}
