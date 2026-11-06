// The sidecar connects like Chrome (lib/transport.ts): OpenSSL accepts Chrome's TLS offer, the
// client hello carries "h2" before "http/1.1", only Chrome's groups, and requests go over HTTP/2.
// Offline: a local TLS server with a throwaway certificate (openssl), no network.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import tls from 'node:tls';
import http2 from 'node:http2';
import { spawnSync } from 'node:child_process';
import { mod, tempDir } from './helpers.ts';

const { CHROME_TLS, chromeAgent } = await mod('lib/transport.ts');
const OPENSSL = process.env.SOFA_OPENSSL || '/opt/local/bin/openssl';

test('OpenSSL accepts Chrome\'s ciphers, groups and signature algorithms', () => {
  assert.doesNotThrow(() => tls.createSecureContext(CHROME_TLS));
});

test('requests go over HTTP/2, the hello offers h2 first', { skip: !fs.existsSync(OPENSSL) && 'openssl missing' }, async () => {
  const dir = tempDir('sofa-yt-tls-');
  const key = path.join(dir, 'key.pem'), cert = path.join(dir, 'cert.pem');
  const r = spawnSync(OPENSSL, ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes',
    '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost', '-days', '1', '-keyout', key, '-out', cert]);
  assert.equal(r.status, 0, String(r.stderr));
  let offered: string[] = [];
  const server = http2.createSecureServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert), allowHTTP1: true,
    ALPNCallback: ({ protocols }: { protocols: string[] }) => { offered = protocols; return protocols.includes('h2') ? 'h2' : 'http/1.1'; } });
  server.on('request', (req, res) => { res.end(JSON.stringify({ version: req.httpVersion })); });
  await new Promise<void>((ok) => server.listen(0, '127.0.0.1', ok));
  const agent = chromeAgent({ ca: fs.readFileSync(cert), servername: 'localhost' });
  try {
    const port = (server.address() as { port: number }).port;
    const res = await fetch(`https://localhost:${port}/`, { dispatcher: agent } as RequestInit);
    assert.deepEqual(await res.json(), { version: '2.0' });
    assert.deepEqual(offered, ['h2', 'http/1.1']);
  } finally {
    await agent.close();
    await new Promise((ok) => server.close(ok));
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
