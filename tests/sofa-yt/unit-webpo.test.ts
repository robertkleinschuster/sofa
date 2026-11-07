// PoTokenProvider (lib/webpo.ts) with a test factory instead of BotGuard: after YouTube rejected a
// token (stream protection status 3) renew() makes the next tokens come from a fresh attestation -
// at most once per 10 min, every renewal is a BotGuard request of its own. Deadlines for a hung
// attestation or mint.
import test from 'node:test';
import assert from 'node:assert/strict';
import { PoTokenProvider } from '../../res/sofa-yt/lib/webpo.ts';
import type { MinterSetup } from '../../res/sofa-yt/lib/webpo.ts';
import { until } from './helpers.ts';

function provider() {
  let made = 0;
  const p = new PoTokenProvider({
    factory: async (): Promise<MinterSetup> => {
      const n = ++made;
      return { ttlMs: 12 * 3600 * 1000, refreshMs: 100 * 1000, minter: {
        mint: async () => Uint8Array.of(n), mintAsWebsafeString: async () => `token-${n}`,
      } as unknown as MinterSetup['minter'] };
    },
  });
  return { p, made: () => made };
}

test('renew(): the next token comes from a fresh attestation, at most once per 10 min', async () => {
  const { p, made } = provider();
  assert.equal(await p.mintString('vid'), 'token-1');
  assert.equal(await p.mintString('vid'), 'token-1', 'the attestation lasts');
  p.renew();
  assert.ok(await until(() => made() === 2, 2000), 'renewed in the background');
  assert.equal(await p.mintString('vid'), 'token-2');
  p.renew();   // within 10 min of the last renewal
  assert.equal(await p.mintString('vid'), 'token-2', 'no second renewal right away');
  assert.equal(made(), 2);
});

// Incident 2026-11-07: after a page reload every open stalled - an attestation or mint that never
// settles (BotGuard's VM) held all later tokens. Each has a deadline; the next attempt starts afresh.
const never = <T>(): Promise<T> => new Promise<T>(() => {});

test('an attestation that hangs fails after its deadline; the next attempt runs a new one', async () => {
  let calls = 0;
  const p = new PoTokenProvider({
    setupTimeoutMs: 150, retryMinMs: 50,
    factory: async (): Promise<MinterSetup> => {
      if (++calls === 1) return never<MinterSetup>();
      return { ttlMs: 3600 * 1000, refreshMs: 0, minter: {
        mint: async () => Uint8Array.of(1), mintAsWebsafeString: async () => 'fresh',
      } as unknown as MinterSetup['minter'] };
    },
  });
  const t0 = performance.now();
  await assert.rejects(p.mintString('vid'), /PO token setup timed out/);
  assert.ok(performance.now() - t0 < 1000, 'within the deadline, not forever');
  await new Promise((r) => setTimeout(r, 60));   // after the retry backoff
  assert.equal(await p.mintString('vid'), 'fresh', 'not stuck behind the hung attestation');
  assert.equal(calls, 2);
});

test('a mint that hangs fails after its deadline; the next token comes from a fresh attestation', async () => {
  let made = 0;
  const p = new PoTokenProvider({
    mintTimeoutMs: 150,
    factory: async (): Promise<MinterSetup> => {
      const n = ++made;
      return { ttlMs: 3600 * 1000, refreshMs: 0, minter: {
        mint: async () => Uint8Array.of(n),
        mintAsWebsafeString: async () => (n === 1 ? never<string>() : `token-${n}`),
      } as unknown as MinterSetup['minter'] };
    },
  });
  await assert.rejects(p.mintString('vid'), /PO token mint timed out/);
  assert.equal(await p.mintString('vid'), 'token-2', 'the hung minter was dropped');
});
