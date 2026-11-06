// sofa-yt: YouTube SABR sidecar for Sofa (long-lived child process).
//
//   node main.ts --port 0 --state <dir> --block-file <path> [--debug] [--no-warm]
//                 [--ahead-low 30 --ahead-high 90]
//                 [--max-player-requests N --budget-window <sec>]
//   node main.ts --check             load every dependency and exit (bundle self-test)
//
// stdout: exactly one line {"ready":true,"port":N,"userAgent":"..."} once the HTTP server listens on
// 127.0.0.1 (userAgent: the one browser identity, which the app uses for its own YouTube requests).
// stderr: log lines prefixed "sofa-yt:". The process exits when stdin closes (parent died).
// Contract and design: docs/sofa-yt.md.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import type { ReloadPlaybackContext } from 'googlevideo/protos';
import { errorMessage, toError } from './lib/errors.ts';
import { log, setDebug } from './lib/log.ts';
import { parseJson, record } from './lib/json.ts';
import type { AppStartPump } from './lib/app.ts';
import type { PumpHandle, SessionConfig } from './lib/session.ts';

const argv = process.argv.slice(2);
const flag = (name: string): boolean => argv.includes(`--${name}`);
function opt(name: string): string | undefined;
function opt(name: string, def: string | number): string | number;
function opt(name: string, def?: string | number): string | number | undefined {
  const i = argv.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < argv.length) return argv[i + 1];
  const eq = argv.find((a) => a.startsWith(`--${name}=`));
  return eq ? eq.slice(name.length + 3) : def;
}

// stdout belongs to the readiness line; libraries that console.log go to stderr
const toStderr = (...a: unknown[]): void => { process.stderr.write(`sofa-yt: [lib] ${a.map(String).join(' ')}\n`); };
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
  await import('undici');
  await import('./lib/transport.ts');
  await import('./lib/app.ts');
  await import('./lib/sabrpump.ts');
  await import('./lib/webpo.ts');
  process.stderr.write(`sofa-yt: check ok (node ${process.version})\n`);
  process.exit(0);
}

if (flag('debug')) setDebug(true);
const WARM_AGAIN_MS = 30 * 60 * 1000;
const stateDir = opt('state');
if (!stateDir) { log('missing --state <dir>'); process.exit(2); }
fs.mkdirSync(stateDir, { recursive: true });
const blockFile = String(opt('block-file', path.join(stateDir, 'youtube-block.json')));

// One browser identity for every request of this process (identity.ts): youtubei.js, BotGuard,
// SABR and captions all use the global fetch - it carries the identity's headers and cookies, and
// connects like Chrome (transport.ts: TLS offer, HTTP/2).
const { setGlobalDispatcher } = await import('undici');
const { chromeAgent } = await import('./lib/transport.ts');
setGlobalDispatcher(chromeAgent());
const { loadIdentity, CookieJar, browserFetch } = await import('./lib/identity.ts');
const identity = await loadIdentity(stateDir);
globalThis.fetch = browserFetch(identity, new CookieJar(path.join(stateDir, 'cookies.json')), globalThis.fetch);

const { Breaker } = await import('./lib/breaker.ts');
const { PoTokenProvider } = await import('./lib/webpo.ts');
const { YouTube, PlayerBudget } = await import('./lib/youtube.ts');
const { FileStore } = await import('./lib/filestore.ts');
const { startSabrPump } = await import('./lib/sabrpump.ts');
const { createApp } = await import('./lib/app.ts');

const breaker = new Breaker(blockFile);
const po = new PoTokenProvider({ identity });
const maxReq = Number(opt('max-player-requests', 60));
const store = new FileStore(stateDir);   // player responses, budget, visitor (lib/store.ts)
const budget = new PlayerBudget({
  store,
  max: maxReq > 0 ? maxReq : Infinity,
  windowS: Number(opt('budget-window', 3600)),
});
const youtube = new YouTube({ store, jsCacheDir: path.join(stateDir, 'ytjs-cache'), identity, breaker, po, budget });

/** Pump factory: real SABR with this process' PO tokens and reload path. */
async function preMint(videoId: string): Promise<string | undefined> {
  try { return await po.mintString(videoId); } catch (e) { log('PO token for SABR unavailable:', errorMessage(e)); return undefined; }
}
const tokenCache = new Map<string, { token: string; at: number }>(); // videoId -> one pre-minted token per video, reused for restarts
const startPump: AppStartPump = (info, formats, opts) => {
  let handle: PumpHandle | null = null;
  let aborted = false;
  const tc = tokenCache.get(info.id);
  const launch = (poToken: string | undefined): void => {
    if (aborted) return;
    try {
      handle = startSabrPump({
        ...opts, info, formats, poToken,
        mintPoToken: () => po.mintBytes(info.id),
        reload: async (ctx?: ReloadPlaybackContext) => {
          const r = await youtube.reload(info.id, ctx, { bg: !!opts.bg });
          // the session keeps the info object: point it at the fresh URL for future runs
          const fresh = youtube.cached(info.id);
          if (fresh && fresh.kind !== 'hls') { info.sabrUrl = fresh.sabrUrl; info.ustreamer = fresh.ustreamer; info.expires = fresh.expires; }
          return r;
        },
      });
    } catch (e) {
      opts.onEnd(toError(e), 'error');
    }
  };
  if (tc && Date.now() - tc.at < 30 * 60 * 1000) launch(tc.token);
  else {
    preMint(info.id).then((token) => {
      if (token) {
        if (tokenCache.size > 32) tokenCache.delete(tokenCache.keys().next().value!); // bounded
        tokenCache.set(info.id, { token, at: Date.now() });
      }
      launch(token);
    });
  }
  return { abort() { aborted = true; handle?.abort(); } };
};

// pacing window (seconds of media buffered ahead of the reader): resume below low, pause above high
const sessionCfg: Partial<SessionConfig> = {};
if (opt('ahead-low')) sessionCfg.LOW_MS = Number(opt('ahead-low')) * 1000;
if (opt('ahead-high')) sessionCfg.HIGH_MS = Number(opt('ahead-high')) * 1000;
const app = createApp({ youtube, po, breaker, startPump, sessionCfg });
const server = http.createServer(app.handler);
server.on('clientError', (_err, sock) => { try { sock.destroy(); } catch { /* gone */ } });

let shuttingDown = false;
function shutdown(why: string): void {
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
process.on('unhandledRejection', (e) => log('unhandled rejection:', e instanceof Error ? e.stack || e : e));
// an exception that escaped every handler leaves unknown state: exit, Sofa restarts the sidecar
process.on('uncaughtException', (e) => { log('uncaught exception:', e.stack || e); process.exit(70); });

server.listen(Number(opt('port', 0)), '127.0.0.1', () => {
  const addr = server.address();
  const port = addr !== null && typeof addr === 'object' ? addr.port : 0;   // always an AddressInfo for TCP
  app.setPort(port);
  process.stdout.write(`${JSON.stringify({ ready: true, port, userAgent: identity.userAgent })}\n`);
  log(`listening on 127.0.0.1:${port}, state ${stateDir}`);
  // warm up the web identity (no player request): Innertube session + BotGuard minter. Not when
  // the last warm-up was recent: Sofa restarts often (deploys, updates) and each warm-up contacts
  // YouTube twice; then the first /open (or preload) warms up on demand, ~2 s later.
  const warmFile = path.join(stateDir, 'last-warmup.json');
  let lastWarm = 0;
  try { lastWarm = Number(record(parseJson(fs.readFileSync(warmFile, 'utf8'))).at) || 0; } catch { /* never warmed */ }
  const recent = Date.now() - lastWarm < WARM_AGAIN_MS;
  if (recent) log(`warm-up deferred to first use (last one ${Math.round((Date.now() - lastWarm) / 60000)} min ago)`);
  if (!flag('no-warm') && !process.env.SOFA_NO_WARMUP && !recent) {
    youtube.session().then(() => po.warm(), () => po.warm());
    try { fs.writeFileSync(warmFile, JSON.stringify({ at: Date.now() })); } catch { /* best effort */ }
  }
});
server.on('error', (e) => { log('server error:', e.message); process.exit(1); });
