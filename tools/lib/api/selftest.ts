// The checker's own checks, run before every tools/test-api: a validator that accepts everything
// would pass every contract - so it must refuse what it is shown to refuse.

import { parseYaml, YamlError, type Json } from './yaml.ts';
import { SchemaSet } from './schema.ts';

function expect(what: string, cond: boolean): void { if (!cond) throw new Error(`selftest: ${what}`); }
function refuses(what: string, f: () => unknown): void {
  try { f(); } catch (e) { if (e instanceof YamlError || e instanceof Error) return; }
  throw new Error(`selftest: ${what} was accepted`);
}

export function selftest(): void {
  // YAML: the subset, read as every YAML parser reads it
  const y = parseYaml([
    'a: 1', 'b: "x: y"', "c: 'it''s'", 'd: [x, 2, true]', 'e:', '  - f: g', '    h: [ ]', '  - plain text', 'i: |', '  one', '  two', 'j: >-',
    '  folded', '  line', 'k: {}', 'l: 1.5', "m: '200'", 'n: null', 'o: no', '# a comment', 'p: a #not', 'q: x # comment',
  ].join('\n'));
  expect('yaml values', JSON.stringify(y) === JSON.stringify({ a: 1, b: 'x: y', c: "it's", d: ['x', 2, true], e: [{ f: 'g', h: [] }, 'plain text'],
    i: 'one\ntwo\n', j: 'folded line', k: {}, l: 1.5, m: '200', n: null, o: 'no', p: 'a', q: 'x' }));
  refuses('an anchor', () => parseYaml('a: &x 1'));
  refuses('an alias', () => parseYaml('a: *x'));
  refuses('a tab', () => parseYaml('a:\n\tb: 1'));
  refuses('a duplicate key', () => parseYaml('a: 1\na: 2'));
  refuses('a colon in a plain scalar', () => parseYaml('a: b: c'));
  refuses('an ambiguous boolean', () => parseYaml('a: True'));
  refuses('a flow mapping', () => parseYaml('a: {b: 1}'));
  refuses('a bad indentation', () => parseYaml('a: 1\n  b: 2'));

  // the validator
  const root: { [k: string]: Json } = { components: { schemas: {
    Thing: { type: 'object', required: ['n'], properties: { n: { type: 'integer', minimum: 1 }, s: { type: 'string', pattern: '^[a-z]+$' },
      e: { type: 'string', enum: ['x', 'y'] }, c: { const: true }, l: { type: 'array', items: { $ref: '#/components/schemas/Leaf' } },
      u: { anyOf: [{ type: 'null' }, { $ref: '#/components/schemas/Leaf' }] }, o: { type: 'object', additionalProperties: true } } },
    Leaf: { type: 'object', properties: { v: { type: 'number' } } },
    One: { oneOf: [{ type: 'string' }, { type: 'string', enum: ['a'] }] },
  } } };
  const set = new SchemaSet(root, true);
  for (const k of ['Thing', 'Leaf', 'One']) set.check({ $ref: `#/components/schemas/${k}` }, k);
  const thing = { $ref: '#/components/schemas/Thing' };
  expect('a valid object', set.validate({ n: 2, s: 'ab', e: 'x', c: true, l: [{ v: 1 }], u: null, o: { any: 1 } }, thing).length === 0);
  expect('missing required', set.validate({}, thing).length === 1);
  expect('a wrong type', set.validate({ n: 'x' }, thing).length > 0);
  expect('below the minimum', set.validate({ n: 0 }, thing).length > 0);
  expect('an integer that is none', set.validate({ n: 1.5 }, thing).length > 0);
  expect('a pattern', set.validate({ n: 1, s: 'A' }, thing).length > 0);
  expect('an enum', set.validate({ n: 1, e: 'z' }, thing).length > 0);
  expect('a const', set.validate({ n: 1, c: false }, thing).length > 0);
  expect('an item through $ref', set.validate({ n: 1, l: [{ v: 'x' }] }, thing).length > 0);
  expect('closed objects', set.validate({ n: 1, extra: 1 }, thing).length > 0);
  expect('a closed nested object', set.validate({ n: 1, l: [{ v: 1, w: 2 }] }, thing).length > 0);
  expect('anyOf: no branch', set.validate({ n: 1, u: 3 }, thing).length > 0);
  expect('oneOf: two branches', set.validate('a', { $ref: '#/components/schemas/One' }).length > 0);
  expect('oneOf: one branch', set.validate('b', { $ref: '#/components/schemas/One' }).length === 0);
  refuses('an unknown keyword', () => set.check({ type: 'string', minimumLength: 3 }, 'x'));
  refuses('an unresolved reference', () => set.check({ $ref: '#/components/schemas/Nope' }, 'x'));
  refuses('a required name without a property', () => set.check({ type: 'object', required: ['a'], properties: {} }, 'x'));
}
