// PoTokenProvider (lib/webpo.ts) with a test factory instead of BotGuard: after YouTube rejected a
// token (stream protection status 3) renew() makes the next tokens come from a fresh attestation -
// at most once per 10 min, every renewal is a BotGuard request of its own.
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
