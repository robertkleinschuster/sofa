// Headless Firefox driven over WebDriver BiDi, as Sofa will drive it (docs/youtube-engine.md): the
// engine test (offline page) and the live engine test (youtube.com) share it.
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { until, within } from './helpers.ts';

export const FIREFOX = process.env.SOFA_FIREFOX || '/opt/local/bin/firefox';
export const ENGINE = process.env.SOFA_YT_ENGINE || '';

export type Json = Record<string, unknown>;

export interface Bidi {
  send(method: string, params: object): Promise<Json>;
  events: Json[];
  close(): void;
}

/** Minimal WebDriver BiDi client: commands by id, events collected. */
export async function bidi(url: string): Promise<Bidi> {
  const ws = new WebSocket(url);
  let id = 0;
  const events: Json[] = [];
  const waits = new Map<number, { ok: (r: Json) => void; bad: (e: Error) => void }>();
  ws.onmessage = (m) => {
    const j = JSON.parse(String(m.data)) as { id?: number; type?: string; error?: string; message?: string; result?: Json };
    if (j.type === 'event') { events.push(j as Json); return; }
    const w = j.id !== undefined ? waits.get(j.id) : undefined;
    if (!w) return;
    waits.delete(j.id!);
    if (j.type === 'error') w.bad(new Error(`${j.error}: ${j.message}`)); else w.ok(j.result ?? {});
  };
  await new Promise<void>((ok, bad) => { ws.onopen = () => ok(); ws.onerror = () => bad(new Error(`BiDi: cannot connect to ${url}`)); });
  return {
    send: (method, params) => new Promise((ok, bad) => { const i = ++id; waits.set(i, { ok, bad }); ws.send(JSON.stringify({ id: i, method, params })); }),
    events,
    close: () => ws.close(),
  };
}

export interface RunningFirefox {
  proc: ChildProcess;
  /** BiDi session endpoint (ws://.../session) */
  url: string;
  output(): string;
  stop(): Promise<void>;
}

/**
 * Prefs of a test profile: no updates, telemetry or remote settings from it, and silent - a test
 * that lets YouTube's player run must not play sound on the machine's speakers (user 2026-11-06).
 */
export function writeProfile(profile: string, extra: Record<string, string | number | boolean> = {}): void {
  fs.mkdirSync(profile, { recursive: true });   // must exist: a missing profile opens a modal dialog and hangs
  const prefs: Record<string, string | number | boolean> = {
    'services.settings.server': '', 'app.update.enabled': false, 'toolkit.telemetry.enabled': false,
    'datareporting.policy.dataSubmissionEnabled': false, 'media.volume_scale': '0.0', ...extra,
  };
  fs.writeFileSync(path.join(profile, 'user.js'), Object.entries(prefs).map(([k, v]) => `user_pref(${JSON.stringify(k)}, ${JSON.stringify(v)});\n`).join(''));
}

export const XVFB = process.env.SOFA_XVFB || '/opt/local/bin/Xvfb';

/**
 * Prefs for Firefox on a display (startXvfb): the firefox-x11 port's defaults are tuned for remote X
 * (no GPU process, WebGL off); a browser on a screen has both, as a stock Firefox does. Without the
 * GPU process Firefox disables WebGL (gfxPlatform: FEATURE_WEBGL_NO_GPU_PROCESS); Mesa's software
 * GL is on Firefox's blocklist, hence force-enabled.
 */
export const DISPLAY_PREFS = { 'layers.gpu-process.enabled': true, 'webgl.disabled': false, 'webgl.force-enabled': true };

/** A virtual X display (Xvfb with Mesa GL): Firefox on it renders like on a screen, WebGL included. */
export interface VirtualDisplay { display: string; stop(): Promise<void> }

export async function startXvfb({ width = 1920, height = 1080 } = {}): Promise<VirtualDisplay> {
  const env = { ...process.env };
  delete env.DYLD_INSERT_LIBRARIES;
  // -displayfd: Xvfb picks a free display and writes its number once it accepts clients (readiness)
  const proc = spawn(XVFB, ['-displayfd', '3', '-screen', '0', `${width}x${height}x24`, '-nolisten', 'tcp'], { env, stdio: ['ignore', 'ignore', 'pipe', 'pipe'] });
  let num = '';
  (proc.stdio[3] as NodeJS.ReadableStream).on('data', (d) => { num += d; });
  let err = '';
  proc.stderr!.on('data', (d) => { err += d; });
  const exited = new Promise((r) => proc.on('exit', r));
  const stop = async (): Promise<void> => {
    if (proc.exitCode === null) proc.kill('SIGTERM');
    await within(exited, 5000);
    if (proc.exitCode === null) proc.kill('SIGKILL');
  };
  if (!await until(() => /\d+\n/.test(num), 15000, 50)) { await stop(); throw new Error(`Xvfb did not start (${err.slice(-300)})`); }
  return { display: `:${num.trim()}`, stop };
}

/**
 * Start Firefox on `profile` with BiDi on a free port: headless, or on `display` (startXvfb) like a
 * browser on a screen. The screen the page sees is the TV's.
 */
type LaunchOptions = { width?: number; height?: number; display?: string; remote?: boolean; url?: string };

/**
 * A started Firefox prints its BiDi port within ~2-3 s (measured 2026-11-07). Under test-all load a
 * start now and then hangs right after "You are running in headless mode" and never prints it (three
 * times on 2026-11-07) - a hang, not slowness: that start is ended and one fresh start is made.
 */
export async function launchFirefox(profile: string, opts: LaunchOptions = {}): Promise<RunningFirefox> {
  try {
    return await launchOnce(profile, opts);
  } catch (e) {
    if (!(e instanceof NoBidiPort)) throw e;
    console.error(`firefox.ts: start hung (${e.message}) - one fresh start`);
    return launchOnce(profile, opts);
  }
}

class NoBidiPort extends Error {}

async function launchOnce(profile: string, { width = 1920, height = 1080, display, remote = true, url = 'about:blank' }: LaunchOptions): Promise<RunningFirefox> {
  const env: NodeJS.ProcessEnv = display ? { ...process.env, DISPLAY: display }
    : { ...process.env, MOZ_HEADLESS_WIDTH: String(width), MOZ_HEADLESS_HEIGHT: String(height) };
  delete env.DYLD_INSERT_LIBRARIES;
  // remote: false = a browser as a user starts it (no remote agent; YouTube refuses one under remote
  // control) - driven through the engine extension instead
  const args = [...(display ? [`--width=${width}`, `--height=${height}`] : ['--headless']), '--no-remote', '--profile', profile,
    ...(remote ? ['--remote-debugging-port', '0'] : []), url];
  const proc = spawn(FIREFOX, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  proc.stderr!.on('data', (d) => { out += d; });
  proc.stdout!.on('data', (d) => { out += d; });
  const exited = new Promise((r) => proc.on('exit', r));
  const stop = async (): Promise<void> => {
    if (proc.exitCode === null) proc.kill('SIGTERM');
    await within(exited, 5000);
    if (proc.exitCode === null) proc.kill('SIGKILL');
  };
  if (!remote) return { proc, url: '', output: () => out, stop };
  const re = /WebDriver BiDi listening on (ws:\/\/\S+)/;
  if (!await until(() => re.test(out), 30000, 100)) { await stop(); throw new NoBidiPort(`Firefox: no BiDi port (${out.slice(-500)})`); }
  return { proc, url: `${re.exec(out)![1]!}/session`, output: () => out, stop };
}

/** The engine's channel messages so far (decoded JSON). */
export function engineMessages(b: Bidi): { type: string; [k: string]: unknown }[] {
  return b.events
    .filter((e) => e.method === 'script.message' && (e.params as Json).channel === 'sofa-engine')
    .map((e) => JSON.parse(String(((e.params as Json).data as Json).value)) as { type: string });
}

/** New BiDi session, the engine as preload script of the first tab with its channel; returns that tab. */
export async function injectEngine(b: Bidi, engineJs: string): Promise<string> {
  await b.send('session.new', { capabilities: {} });
  await b.send('session.subscribe', { events: ['script.message'] });
  const tree = await b.send('browsingContext.getTree', {}) as { contexts: { context: string }[] };
  const context = tree.contexts[0]!.context;
  // as Sofa injects it: the bundle runs before the page's scripts and gets the channel
  await b.send('script.addPreloadScript', {
    functionDeclaration: `(post) => {\n${engineJs}\n;globalThis.sofaEngine.connect(post);\n}`,
    arguments: [{ type: 'channel', value: { channel: 'sofa-engine' } }],
    contexts: [context],
  });
  return context;
}

/** Call `fn` (an expression evaluating to a function) in the tab; its result JSON-decoded. */
export async function callIn<T>(b: Bidi, context: string, fn: string): Promise<T> {
  const r = await b.send('script.callFunction', { functionDeclaration: `async () => JSON.stringify(await (${fn})())`, target: { context }, awaitPromise: true }) as
    { type: string; result?: { value: string }; exceptionDetails?: { text: string } };
  if (r.type !== 'success') throw new Error(`callFunction: ${r.exceptionDetails?.text ?? r.type}`);
  return JSON.parse(r.result!.value) as T;
}
