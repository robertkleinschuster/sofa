// sofa-yt: YouTube SABR sidecar for Sofa (long-lived child process).
//
//   node main.mjs --port 0 --state <dir> --block-file <path> [--debug] [--no-warm]
//                 [--ahead-low 30 --ahead-high 90]
//                 [--max-player-requests N --budget-file <path> --budget-window <sec>]
//   node main.mjs --check            load every dependency and exit (bundle self-test)
//
// stdout: exactly one line {"ready":true,"port":N} once the HTTP server listens on 127.0.0.1.
// stderr: log lines prefixed "sofa-yt:". The process exits when stdin closes (parent died).
// Contract and design: docs/sofa-yt.md.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { log, setDebug } from './lib/log.mjs';

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const opt = (name, def) => {
  const i = argv.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < argv.length) return argv[i + 1];
  const eq = argv.find((a) => a.startsWith(`--${name}=`));
  return eq ? eq.slice(name.length + 3) : def;
};

// stdout belongs to the readiness line; libraries that console.log go to stderr
const toStderr = (...a) => process.stderr.write(`sofa-yt: [lib] ${a.map(String).join(' ')}\n`);
console.log = toStderr; console.info = toStderr; console.debug = () => {};

if (flag('check')) {
  // Bundle self-test: every dependency must load with this node (no network).
  await import('googlevideo/sabr-stream');
  await import('googlevideo/utils');
  await import('youtubei.js');
  await import('bgutils-js/botguard');
  await import('bgutils-js/webpo');
  await import('bgutils-js/utils');
  await import('jsdom');
  await import('./lib/app.mjs');
  await import('./lib/sabrpump.mjs');
  await import('./lib/webpo.mjs');
  process.stderr.write(`sofa-yt: check ok (node ${process.version})\n`);
  process.exit(0);
}

if (flag('debug')) setDebug(true);
const stateDir = opt('state');
if (!stateDir) { log('missing --state <dir>'); process.exit(2); }
fs.mkdirSync(stateDir, { recursive: true });
const blockFile = opt('block-file', path.join(stateDir, 'youtube-block.json'));

const { Breaker } = await import('./lib/breaker.mjs');
const { PoTokenProvider } = await import('./lib/webpo.mjs');
const { YouTube, PlayerBudget } = await import('./lib/youtube.mjs');
const { startSabrPump } = await import('./lib/sabrpump.mjs');
const { createApp } = await import('./lib/app.mjs');

const breaker = new Breaker(blockFile);
const po = new PoTokenProvider();
const maxReq = Number(opt('max-player-requests', 60));
const budget = new PlayerBudget({
  file: opt('budget-file', path.join(stateDir, 'player-requests.json')),
  max: maxReq > 0 ? maxReq : Infinity,
  windowS: Number(opt('budget-window', 3600)),
});
const youtube = new YouTube({ stateDir, breaker, po, budget });

/** Pump factory: real SABR with this process' PO tokens and reload path. */
async function preMint(videoId) {
  try { return await po.mintString(videoId); } catch (e) { log('PO token for SABR unavailable:', e.message); return undefined; }
}
const tokenCache = new Map(); // videoId -> {token, at}: one pre-minted token per video, reused for restarts
function startPump(info, formats, opts) {
  let handle = null;
  let aborted = false;
  const tc = tokenCache.get(info.id);
  const launch = (poToken) => {
    if (aborted) return;
    try {
      handle = startSabrPump({
        ...opts, info, formats, poToken,
        mintPoToken: () => po.mintBytes(info.id),
        reload: async (ctx) => {
          const r = await youtube.reload(info.id, ctx, { bg: !!opts.bg });
          // the session keeps the info object: point it at the fresh URL for future runs
          const fresh = youtube.cached(info.id);
          if (fresh) { info.sabrUrl = fresh.sabrUrl; info.ustreamer = fresh.ustreamer; info.expires = fresh.expires; }
          return r;
        },
      });
    } catch (e) {
      opts.onEnd(e, 'error');
    }
  };
  if (tc && Date.now() - tc.at < 30 * 60 * 1000) launch(tc.token);
  else {
    preMint(info.id).then((token) => {
      if (token) {
        if (tokenCache.size > 32) tokenCache.delete(tokenCache.keys().next().value); // bounded
        tokenCache.set(info.id, { token, at: Date.now() });
      }
      launch(token);
    });
  }
  return { abort() { aborted = true; handle?.abort(); } };
}

// pacing window (seconds of media buffered ahead of the reader): resume below low, pause above high
const sessionCfg = {};
if (opt('ahead-low')) sessionCfg.LOW_MS = Number(opt('ahead-low')) * 1000;
if (opt('ahead-high')) sessionCfg.HIGH_MS = Number(opt('ahead-high')) * 1000;
const app = createApp({ youtube, po, breaker, startPump, sessionCfg });
const server = http.createServer(app.handler);
server.on('clientError', (err, sock) => { try { sock.destroy(); } catch { /* gone */ } });

let shuttingDown = false;
function shutdown(why) {
  if (shuttingDown) return;
  shuttingDown = true;
  log(`exiting (${why})`);
  app.shutdown();
  server.close();
  server.closeAllConnections?.();
  setTimeout(() => process.exit(0), 300).unref();
}

// no orphans: the parent holds our stdin; EOF/error means it is gone
process.stdin.on('end', () => shutdown('stdin closed'));
process.stdin.on('close', () => shutdown('stdin closed'));
process.stdin.on('error', () => shutdown('stdin error'));
process.stdin.resume();
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGPIPE', () => {});
process.on('unhandledRejection', (e) => log('unhandled rejection:', e?.stack || e));
// an exception that escaped every handler leaves unknown state: exit, Sofa restarts the sidecar
process.on('uncaughtException', (e) => { log('uncaught exception:', e?.stack || e); process.exit(70); });

server.listen(Number(opt('port', 0)), '127.0.0.1', () => {
  const port = server.address().port;
  app.setPort(port);
  process.stdout.write(`${JSON.stringify({ ready: true, port })}\n`);
  log(`listening on 127.0.0.1:${port}, state ${stateDir}`);
  // warm up the web identity (no player request): Innertube session + BotGuard minter
  if (!flag('no-warm') && !process.env.SOFA_NO_WARMUP) {
    youtube.session().then(() => po.warm(), () => po.warm());
  }
});
server.on('error', (e) => { log('server error:', e.message); process.exit(1); });
