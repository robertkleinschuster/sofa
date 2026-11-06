// LIVE smoke test (opt-in: SOFA_YT_LIVE=1 tools/test-sofa-yt). Talks to YouTube:
//   - at most ONE player request (none while build/sofa-yt-live still holds a valid response for the
//     video; hard cap via --max-player-requests, persisted per state dir),
//   - small pacing window and mpv without a cache, so only ~1 min of media is pulled.
// mpv plays 10 s from 60 s, seeks once (to 25:00) via its IPC socket, plays 3 s more, quits.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { DIR, get, json, nth, until, within } from './helpers.ts';
import type { VodAnswer } from '../../res/sofa-yt/lib/app.ts';
import type { SessionStatus } from '../../res/sofa-yt/lib/session.ts';
import { mpvIpc } from './mpvipc.ts';

const VID = process.env.SOFA_YT_LIVE_VIDEO || 'OzCYsIrrRyw';
const STATE = process.env.SOFA_YT_LIVE_STATE || path.resolve(DIR, '..', 'sofa-yt-live');
const MPV = process.env.SOFA_MPV || '/opt/local/bin/mpv';
const MAX_REQ = process.env.SOFA_YT_MAX_PLAYER_REQUESTS || '1';

test('live: /open, mpv plays 10 s from 1:00, one seek, subtitles', { timeout: 180000 }, async () => {
  fs.mkdirSync(STATE, { recursive: true });
  const env = { ...process.env };
  delete env.DYLD_INSERT_LIBRARIES;
  const side = spawn(process.env.SOFA_NODE || process.execPath, [path.join(DIR, 'main.ts'), '--port', '0', '--state', STATE,
    '--block-file', path.join(STATE, 'youtube-block.json'), '--max-player-requests', MAX_REQ, '--budget-window', '86400',
    '--ahead-low', '6', '--ahead-high', '15', '--debug'], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  let out = ''; let err = '';
  side.stdout.on('data', (d) => { out += d; });
  side.stderr.on('data', (d) => { err += d; process.stderr.write(d); });
  let mpv: ChildProcess | null = null;
  try {
    assert.ok(await until(() => out.includes('\n'), 15000), 'sidecar ready');
    const { port } = json<{ ready: boolean; port: number }>(nth(out.split('\n'), 0));
    const base = `http://127.0.0.1:${port}`;
    const t0 = Date.now();
    const o = json<VodAnswer & { error?: string }>((await get(`${base}/open?v=${VID}&start=60`, { timeoutMs: 60000 })).body);
    process.stderr.write(`OPEN ${JSON.stringify(o)}\n`);
    assert.ok(!o.error, `open failed: ${o.error}`);
    process.stderr.write(`open took ${Date.now() - t0} ms (cached=${o.cached})\n`);
    assert.ok(o.video.startsWith(base) && o.audio.startsWith(base));

    const sock = path.join(os.tmpdir(), `sofa-yt-mpv-${process.pid}.sock`);
    const t1 = Date.now();
    // no --length: it would end playback at 120 s, before the seek target
    const proc = spawn(MPV, ['--no-config', '--vo=null', '--ao=null', '--cache=no', '--demuxer-readahead-secs=2',
      `--input-ipc-server=${sock}`, '--start=60', '--msg-level=all=info', o.video, `--audio-file=${o.audio}`],
    { env, stdio: ['ignore', 'pipe', 'pipe'] });
    let mlog = '';
    mpv = proc;
    proc.stdout.on('data', (d) => { mlog += d; });
    proc.stderr.on('data', (d) => { mlog += d; });
    const mpvExit = new Promise((r) => proc.on('exit', r));
    assert.ok(await until(() => fs.existsSync(sock), 15000), 'mpv IPC up');
    const ipc = mpvIpc(sock);
    await ipc.ready;
    const pos = async (): Promise<number> => { const p = await ipc.get('time-pos'); return typeof p === 'number' ? p : -1; };
    assert.ok(await until(async () => (await pos()) >= 60.5, 30000, 200), 'playback started at 1:00');
    const tStart = Date.now();
    process.stderr.write(`first frame after ${tStart - t1} ms\n`);
    assert.ok(await until(async () => (await pos()) >= 70, 30000, 200), 'played 10 s');
    const playedWall = (Date.now() - tStart) / 1000;
    process.stderr.write(`10 s played in ${playedWall.toFixed(1)} s wall time\n`);
    const tSeek = Date.now();
    await ipc.cmd('seek', 1500, 'absolute');
    assert.ok(await until(async () => { const p = await pos(); return p >= 1500.5 && p < 1600; }, 30000, 200), 'seek to 25:00 plays');
    process.stderr.write(`seek -> playing after ${Date.now() - tSeek} ms\n`);
    assert.ok(await until(async () => (await pos()) >= 1503, 30000, 200), 'played on after the seek');
    const tracks = (await ipc.get('track-list')) as { type: string; codec: string; 'demux-w': number; 'demux-h': number }[];   // mpv's track-list
    const v = tracks.find((t) => t.type === 'video');
    process.stderr.write(`mpv video ${v?.codec} ${v?.['demux-w']}x${v?.['demux-h']}\n`);
    assert.equal(v?.['demux-h'], o.height);
    await ipc.cmd('quit');
    ipc.close();
    const code = await within(mpvExit, 10000);
    assert.equal(code, 0, `mpv exit (${mlog.slice(-2000)})`);
    mpv = null;

    if (o.subs.length) {
      const sub = nth(o.subs, 0);
      const s = await get(sub.url, { timeoutMs: 20000 });
      process.stderr.write(`subs ${sub.lang}/${sub.kind}: HTTP ${s.status}, ${s.body.length} bytes: ${s.body.toString().slice(0, 120).replace(/\n/g, ' | ')}\n`);
      assert.equal(s.status, 200);
      assert.match(s.body.toString(), /^WEBVTT/);
    }
    const st = json<SessionStatus>((await get(`${base}/s/${o.sid}/status`)).body);
    process.stderr.write(`STATUS ${JSON.stringify(st)}\n`);
    const h = json<{ poToken: string; fetched: { videoSec: number } }>((await get(`${base}/health`)).body);
    process.stderr.write(`HEALTH ${JSON.stringify(h)}\n`);
    assert.equal(h.poToken, 'ready');
    assert.ok(h.fetched.videoSec < 150, `media pulled ${h.fetched.videoSec} s`);
  } finally {
    if (mpv && mpv.exitCode === null) mpv.kill('SIGKILL');
    side.stdin.end();
    await within(new Promise((r) => side.on('exit', r)), 5000);
    if (side.exitCode === null) side.kill('SIGKILL');
    fs.writeFileSync(path.join(STATE, 'last-run.log'), err);
  }
});
