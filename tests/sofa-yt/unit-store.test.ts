// lib/store.ts + lib/filestore.ts: the engine's state behind one interface (docs/youtube-engine.md);
// the file layout of the node sidecar stays as it was. Plus what YouTube keeps there: the visitor.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { MemoryStore } from '../../res/sofa-yt/lib/store.ts';
import type { StateStore } from '../../res/sofa-yt/lib/store.ts';
import { FileStore } from '../../res/sofa-yt/lib/filestore.ts';
import { mod, tempDir, noSessions } from './helpers.ts';

const { YouTube } = await mod('lib/youtube.ts');

for (const [name, make] of [['MemoryStore', () => new MemoryStore()], ['FileStore', () => new FileStore(tempDir('sofa-yt-store-'))]] as const) {
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
