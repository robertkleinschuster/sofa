// The driver of tools/test-api: runs a dev instance of Sofa (only the Example app, local media, a
// throwaway certificate on loopback), calls every operation of api/openapi.yaml the way a client does -
// the right way and the wrong ways that have a documented answer - and checks every request and answer
// against the contract (Contract.check), the error codes against src/Library/SFWebErrors.m, and what the
// run left unexercised. The first answer of each operation and status is written, scrubbed, to
// api/examples/<operation>.<status>.json (requests: <operation>.request.json).

import { spawn, type ChildProcess } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { Contract, type Exchange } from './openapi.ts';
import { Client, type Answer, type Call } from './client.ts';
import { scrub } from './scrub.ts';
import { selftest } from './selftest.ts';
import { afterRestart, scenario, type Tools } from './scenario.ts';

const E = process.env;
const need = (k: string): string => { const v = E[k]; if (!v) throw new Error(`${k} missing`); return v; };
const SRC = need('SOFA_SRC'), DATA = need('SOFA_DATA'), NAME = need('SOFA_NAME'), PORT = Number(need('SOFA_PORT')), T = need('SOFA_TMP');
const LOG = join(DATA, 'sofa.log'), FIFO = join(DATA, 'dev.fifo');
const EXAMPLES = join(SRC, 'api/examples');

let failed = 0;
const ok = (m: string): void => console.log(`  ok    ${m}`);
const bad = (m: string): void => { console.log(`  FAIL  ${m}`); failed = 1; };
const note = (m: string): void => console.log(`  note  ${m}`);
const check = (m: string, cond: boolean, got?: unknown): void => { if (cond) ok(m); else bad(`${m}${got === undefined ? '' : `: got ${JSON.stringify(got).slice(0, 300)}`}`); };
const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
const log = (): string => (existsSync(LOG) ? readFileSync(LOG, 'utf8') : '');

async function waitLog(re: RegExp, ms = 30_000, from = 0): Promise<RegExpMatchArray> {
  const deadline = Date.now() + ms;
  for (;;) {
    const m = log().slice(from).match(re);
    if (m) return m;
    if (Date.now() > deadline) throw new Error(`no ${re} in the log`);
    await sleep(100);
  }
}

// ---- the contract, the examples ---------------------------------------------------------------------
selftest();
ok('the validator and the YAML reader pass their own checks');
const contract = new Contract(join(SRC, 'api/openapi.yaml'));
ok(`the contract reads and compiles (${contract.operations.length} operations)`);
const recorded = new Set<string>();
rmSync(EXAMPLES, { recursive: true, force: true });
mkdirSync(EXAMPLES, { recursive: true });
const ctx = { name: NAME, port: PORT, tmp: T };
function record(x: Exchange): void {
  const problems = contract.check(x);
  for (const p of problems) bad(`contract: ${p}`);
  const m = contract.match(x.method, x.path);
  if (!m) return;
  const id = m.op.id;
  if (x.body !== undefined && x.bodyType === 'application/json' && !recorded.has(`${id}.request`)) {
    recorded.add(`${id}.request`);
    writeFileSync(join(EXAMPLES, `${id}.request.json`), JSON.stringify(scrub(x.body, ctx), null, 2) + '\n');
  }
  const key = `${id}.${x.status}`;
  if (recorded.has(key) || !x.contentType.startsWith('application/json')) return;
  recorded.add(key);
  try { writeFileSync(join(EXAMPLES, `${key}.json`), JSON.stringify(scrub(JSON.parse(x.responseBody.toString('utf8')), ctx), null, 2) + '\n'); } catch { /* checked above */ }
}
const client = new Client(NAME, PORT, readFileSync(need('SOFA_CERT'), 'utf8'), record);
const api = (path: string, opts: Omit<Call, 'path'> = {}): Promise<Answer> => client.call({ path, ...opts });

// ---- the dev instance ---------------------------------------------------------------------------------
let app: ChildProcess | null = null;
async function startSofa(extra: Record<string, string> = {}): Promise<number> {
  const from = log().length;
  app = spawn(join(SRC, 'build/SofaDev.app/Contents/MacOS/Sofa'), ['--dev', '--instance', need('SOFA_INSTANCE')], {
    stdio: 'ignore',
    env: { ...process.env, SOFA_DATA_DIR: DATA, SOFA_ONLY_APPS: 'example', SOFA_WEB_PORT: String(PORT), SOFA_WEB_CERT: need('SOFA_CERT'),
      SOFA_WEB_KEY: need('SOFA_KEY'), SOFA_WEB_LOOPBACK: '1', SOFA_WEB_ORIGINS: 'https://pwa.test', SOFA_WEB_APP_URL: 'https://pwa.test/app/',
      SOFA_PROXY_LOOPBACK: '1', SOFA_AUDIO_OUT: 'null', SOFA_SOURCE_GAP: '1', SOFA_EXAMPLE_MORE: '1',
      SOFA_EXAMPLE_MEDIA: need('MEDIA_FILE'), SOFA_EXAMPLE_IMAGE: need('MEDIA_IMAGE'),
      SOFA_EXAMPLE_BROWSER_VIDEO: need('MEDIA_DASH_V'), SOFA_EXAMPLE_BROWSER_AUDIO: need('MEDIA_DASH_A'),
      SOFA_EXAMPLE_BROWSER_VP9_VIDEO: need('MEDIA_VP9_V'), SOFA_EXAMPLE_BROWSER_VP9_AUDIO: need('MEDIA_VP9_A'), ...extra },
  });
  await waitLog(/fifo ready/, 30_000, from);
  await waitLog(/web: listening on port/, 30_000, from);
  return from;
}
async function stopSofa(): Promise<void> {
  if (!app) return;
  const a = app; app = null;
  if (a.exitCode === null) {
    appendFileSync(FIFO, 'quit\n');
    await Promise.race([new Promise((r) => a.once('exit', r)), sleep(30_000)]);
    if (a.exitCode === null) a.kill();
  }
  const refused = log().match(/^[0-9: .-]+ store: .* -> .*$/m);
  if (refused) bad(`the database refused a statement: ${refused[0]}`);
}
process.on('exit', () => { app?.kill(); });

async function pairingCode(): Promise<string> {
  const before = (log().match(/dev: web pairing code [0-9]{6}/g) ?? []).length;
  appendFileSync(FIFO, 'open web\n');
  const deadline = Date.now() + 30_000;
  for (;;) {
    const all = log().match(/dev: web pairing code ([0-9]{6})/g) ?? [];
    if (all.length > before) return all[all.length - 1]!.slice(-6);
    if (Date.now() > deadline) throw new Error('no pairing code');
    await sleep(100);
  }
}

type Item = Record<string, unknown> & { d?: Record<string, unknown>; id?: string };
const items = (page: Answer): Item[] => ((page.json?.shelves ?? []) as { items: Item[] }[]).flatMap((s) => s.items);
const itemOf = (page: Answer, id: string): Record<string, unknown> => {
  const i = items(page).find((x) => x.id === id);
  if (!i?.d) throw new Error(`no item ${id}`);
  return i.d;
};

// ---- run 1: everything a client does ------------------------------------------------------------------
const tools: Tools = { api, check, ok, bad, note, sleep, waitLog, pairingCode, items, itemOf, log, name: NAME, port: PORT, data: DATA };
try {
  await startSofa();
  const state = await scenario(tools);
  await stopSofa();
  // ---- run 2: the same data folder after a restart - the pairing and the picture URLs stay; paused streams
  console.log('==> restarted (short stream lifetimes)');
  await startSofa({ SOFA_STREAM_IDLE: '2', SOFA_STREAM_PAUSED: '8' });
  await afterRestart(tools, state);
} catch (e) {
  bad(`the run broke off: ${(e as Error).stack ?? String(e)}`);
} finally {
  await stopSofa();
}

// ---- what the run covered ------------------------------------------------------------------------------
const cov = contract.coverage();
check(`every operation of the contract exercised (${cov.total - cov.missing.length}/${cov.total})`, !cov.missing.length, cov.missing);
note(`statuses answered: ${cov.seenStatuses}/${cov.statuses}; not exercised: ${cov.unseen.join(', ')}`);
const server = [...readFileSync(join(SRC, 'src/Library/SFWebErrors.m'), 'utf8').matchAll(/SFWebErr[A-Za-z]+ = @"([a-z_]+)"/g)].map((m) => m[1]!).sort();
const spec = contract.errorCodes();
check('the error codes of the contract are the server\'s (SFWebErrors.m)', JSON.stringify(server) === JSON.stringify(spec), { server, spec });
note(`error codes answered: ${[...contract.codes].sort().join(' ')} (${contract.codes.size}/${spec.length}); not: ${spec.filter((c) => !contract.codes.has(c)).join(' ')}`);
note(`examples: ${readdirSync(EXAMPLES).length} files in api/examples`);
process.exit(failed);
