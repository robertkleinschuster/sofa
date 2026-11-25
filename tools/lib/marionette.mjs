// A minimal Marionette (WebDriver over Firefox's own protocol) client for the browser tests: a
// headless Firefox with a throwaway profile, driven over a local TCP port. Messages are
// "<length>:<json>"; a command is [0, id, name, params], its answer [1, id, error, result].

import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { join } from 'node:path';

// display: an X display (Xvfb) to render on instead of headless - headless builds may not take screenshots
export async function launchFirefox({ binary, profileDir, prefs = {}, port, display }) {
  mkdirSync(profileDir, { recursive: true });
  const all = { 'marionette.port': port, 'browser.shell.checkDefaultBrowser': false, 'browser.startup.homepage_override.mstone': 'ignore',
    'datareporting.policy.dataSubmissionEnabled': false, 'toolkit.telemetry.reportingpolicy.firstRun': false,
    'app.update.enabled': false, 'browser.aboutwelcome.enabled': false, ...prefs };
  writeFileSync(join(profileDir, 'user.js'), Object.entries(all).map(([k, v]) => `user_pref(${JSON.stringify(k)}, ${JSON.stringify(v)});`).join('\n') + '\n');
  const env = display ? { ...process.env, DISPLAY: display } : { ...process.env, MOZ_HEADLESS: '1' };
  delete env.DYLD_INSERT_LIBRARIES;
  const args = [...(display ? [] : ['--headless']), '--marionette', '--no-remote', '--profile', profileDir, 'about:blank'];
  const proc = spawn(binary, args, { env, stdio: 'ignore' });
  const client = new Marionette();
  const deadline = Date.now() + 60_000;
  for (;;) {
    try { await client.connect(port); break; } catch {
      if (Date.now() > deadline || proc.exitCode !== null) { proc.kill(); throw new Error('Firefox/Marionette did not come up'); }
      await new Promise((r) => setTimeout(r, 300));
    }
  }
  client.proc = proc;
  return client;
}

export class Marionette {
  constructor() { this.id = 0; this.pending = new Map(); this.buf = Buffer.alloc(0); this.greeted = null; }

  connect(port) {
    return new Promise((resolve, reject) => {
      const sock = net.connect(port, '127.0.0.1');
      sock.once('error', reject);
      this.greeted = resolve;
      sock.on('data', (d) => this.onData(d));
      this.sock = sock;
    });
  }

  onData(d) {
    this.buf = Buffer.concat([this.buf, d]);
    for (;;) {
      const colon = this.buf.indexOf(58);
      if (colon < 0) return;
      const len = Number(this.buf.subarray(0, colon).toString());
      if (this.buf.length < colon + 1 + len) return;
      const msg = JSON.parse(this.buf.subarray(colon + 1, colon + 1 + len).toString());
      this.buf = this.buf.subarray(colon + 1 + len);
      if (!Array.isArray(msg)) { this.greeted?.(msg); this.greeted = null; continue; }
      const [, id, error, result] = msg;
      const p = this.pending.get(id);
      if (!p) continue;
      this.pending.delete(id);
      if (error) p.reject(new Error(`${error.error}: ${error.message}`)); else p.resolve(result);
    }
  }

  send(name, params = {}) {
    const id = ++this.id;
    const body = Buffer.from(JSON.stringify([0, id, name, params]));
    this.sock.write(`${body.length}:`);
    this.sock.write(body);
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }

  // acceptInsecureCerts: the tests' throwaway certificate (older Marionette reads the flat form)
  session(caps = {}) {
    const c = { acceptInsecureCerts: true, ...caps };
    return this.send('WebDriver:NewSession', { ...c, capabilities: { alwaysMatch: c } });
  }
  navigate(url) { return this.send('WebDriver:Navigate', { url }); }
  async run(script, args = []) { return (await this.send('WebDriver:ExecuteScript', { script, args })).value; }
  async runAsync(script, args = []) { return (await this.send('WebDriver:ExecuteAsyncScript', { script, args, scriptTimeout: 60_000 })).value; }
  setWindow(width, height) { return this.send('WebDriver:SetWindowRect', { width, height }); }
  async screenshot() {
    try { return Buffer.from((await this.send('WebDriver:TakeScreenshot', { full: false })).value, 'base64'); } catch {
      return Buffer.from((await this.send('WebDriver:TakeScreenshot', { full: true, scroll: false })).value, 'base64');
    }
  }
  async url() { return (await this.send('WebDriver:GetCurrentURL')).value; }

  // until script returns something truthy (polled in the page), or throws after ms
  async until(script, ms = 30_000, what = script) {
    const deadline = Date.now() + ms;
    let last;
    for (;;) {
      try { last = await this.run(script); if (last) return last; } catch (e) { last = e.message; }
      if (Date.now() > deadline) throw new Error(`timed out: ${what} (last: ${JSON.stringify(last)})`);
      await new Promise((r) => setTimeout(r, 250));
    }
  }

  async quit() {
    try { await Promise.race([this.send('Marionette:Quit', { flags: ['eForceQuit'] }), new Promise((r) => setTimeout(r, 5000))]); } catch { /* gone */ }
    this.sock?.destroy();
    if (this.proc && this.proc.exitCode === null) this.proc.kill();
  }
}
