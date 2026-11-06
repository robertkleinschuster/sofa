// lib/bytes.ts: the byte helpers that replace node's Buffer/crypto so the modules run in the browser
// engine too (docs/youtube-engine.md).
import test from 'node:test';
import assert from 'node:assert/strict';
import { mod } from './helpers.ts';

const { randomHex, fromBase64, latin1 } = await mod('lib/bytes.ts');

test('randomHex: n bytes as lowercase hex, different each time', () => {
  const a = randomHex(8), b = randomHex(8);
  assert.match(a, /^[0-9a-f]{16}$/);
  assert.notEqual(a, b);
});

test('fromBase64: base64 and base64url give the same bytes', () => {
  const bytes = Uint8Array.from([0xfb, 0xff, 0xfe, 0x00, 0x41]);
  assert.deepEqual(fromBase64(Buffer.from(bytes).toString('base64')), bytes);
  assert.deepEqual(fromBase64(Buffer.from(bytes).toString('base64url')), bytes);
});

test('latin1: byte range as a type code', () => {
  assert.equal(latin1(Uint8Array.from([0, 0, 0, 24, 0x73, 0x69, 0x64, 0x78]), 4, 8), 'sidx');
});
