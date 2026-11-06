// lib/store.ts + lib/filestore.ts: the engine's state behind one interface (docs/youtube-engine.md);
// the file layout of the node sidecar stays as it was. Plus what YouTube keeps there: the visitor.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { MemoryStore, WebStorageStore } from '../../res/sofa-yt/lib/store.ts';
import type { StateStore, WebStorageLike } from '../../res/sofa-yt/lib/store.ts';
import { FileStore } from '../../res/sofa-yt/lib/filestore.ts';
import { mod, tempDir, noSessions } from './helpers.ts';

const { YouTube } = await mod('lib/youtube.ts');

/** A Web Storage as the browser has it (localStorage), with an optional quota in characters. */
function fakeStorage(quota = Infinity): WebStorageLike & { data: Map<string, string> } {
  const data = new Map<string, string>();
  const used = (): number => [...data].reduce((n, [k, v]) => n + k.length + v.length, 0);
  return {
    data,
    get length() { return data.size; },
    key: (i) => [...data.keys()][i] ?? null,
    getItem: (k) => data.get(k) ?? null,
    setItem(k, v) {
      if (used() - (data.get(k)?.length ?? 0) + (data.has(k) ? 0 : k.length) + v.length > quota) throw new Error('QuotaExceededError');
      data.set(k, v);
    },
    removeItem: (k) => { data.delete(k); },
  };
}

for (const [name, make] of [['MemoryStore', () => new MemoryStore()], ['FileStore', () => new FileStore(tempDir('sofa-yt-store-'))],
  ['WebStorageStore', () => new WebStorageStore(fakeStorage(), 'sofa:')]] as const) {
  test(`${name}: get/set/delete, keys of one directory`, () => {
    const s: StateStore = make();
    assert.equal(s.get('visitor.json'), null);
    s.set('visitor.json', '{"visitorData":"x"}');
    s.set('players/a.json', '1'); s.set('players/b.json', '2'); s.set('players/sub/c.json', '3');
    assert.equal(s.get('visitor.json'), '{"visitorData":"x"}');
    assert.deepEqual(s.keys('players/').sort(), name === 'FileStore' ? ['players/a.json', 'players/b.json', 'players/sub'] : ['players/a.json', 'players/b.json']);
    s.delete('players/a.json');
    assert.equal(s.get('players/a.json'), null);
    s.delete('nothing.json');   // no error
  });
}

test('WebStorageStore: own prefix only, a full storage loses the write without throwing', () => {
  const storage = fakeStorage(100);
  storage.setItem('yt-player-volume', '{"volume":100}');   // the page's own keys stay untouched and unlisted
  const failed: string[] = [];
  const s = new WebStorageStore(storage, 'sofa:', (key) => failed.push(key));
  s.set('players/a.json', 'x');
  assert.deepEqual(s.keys('players/'), ['players/a.json']);
  assert.equal(storage.getItem('sofa:players/a.json'), 'x');
  s.set('players/b.json', 'y'.repeat(200));
  assert.deepEqual(failed, ['players/b.json']);
  assert.equal(s.get('players/b.json'), null);
  assert.equal(storage.getItem('yt-player-volume'), '{"volume":100}');
});

test('FileStore keeps the sidecar layout, private files', () => {
  const dir = tempDir('sofa-yt-store-');
  new FileStore(dir).set('players/abc.json', '{}');
  assert.ok(fs.existsSync(path.join(dir, 'players', 'abc.json')));
  assert.equal(fs.statSync(path.join(dir, 'players', 'abc.json')).mode & 0o777, 0o600);
});

test('visitor: kept across restarts, empty answers and garbage ignored', () => {
  const store = new MemoryStore();
  const make = () => new YouTube({ store, sessions: noSessions, breaker: { blockedUntil: () => 0, heldUntil: () => 0, note() {} },
    po: { mintString: () => Promise.reject(new Error('none')) } });
  const yt = make();
  assert.equal(yt.visitor(), undefined);
  yt.keepVisitor('CgtABC');
  assert.equal(make().visitor(), 'CgtABC', 'a new process finds it');
  yt.keepVisitor('');
  assert.equal(yt.visitor(), 'CgtABC', 'an empty answer does not forget the visitor');
  store.set('visitor.json', '{"visitorData":5}');
  assert.equal(yt.visitor(), undefined);
});
