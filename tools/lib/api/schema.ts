// A JSON Schema validator (draft 2020-12, the dialect of OpenAPI 3.1) for the keywords api/openapi.yaml
// uses. Strict: a schema with a keyword it doesn't implement is refused when compiled (`check`), so no
// part of the contract is silently left unchecked. Annotations (description, examples, format, ...) are
// read as such. `closed`: objects without `additionalProperties` accept no undeclared property - the
// test's stricter reading (the server says nothing the contract doesn't name); clients still ignore
// unknown fields.

import type { Json } from './yaml.ts';

type Schema = { [k: string]: Json } | boolean;

const ASSERTIONS = new Set(['type', 'enum', 'const', 'properties', 'required', 'additionalProperties', 'items', 'minItems', 'maxItems',
  'minimum', 'maximum', 'minLength', 'maxLength', 'pattern', 'oneOf', 'anyOf', 'allOf', '$ref', 'maxProperties', 'minProperties']);
const ANNOTATIONS = new Set(['description', 'title', 'examples', 'example', 'format', 'default', 'deprecated', 'readOnly', 'writeOnly']);
const TYPES = new Set(['null', 'boolean', 'object', 'array', 'number', 'integer', 'string']);

export interface Problem { path: string; message: string }

export class SchemaSet {
  private patterns = new Map<string, RegExp>();
  private readonly root: { [k: string]: Json };
  private readonly closed: boolean;
  constructor(root: { [k: string]: Json }, closed = true) { this.root = root; this.closed = closed; }

  // The schema a local reference names ("#/components/schemas/Item")
  resolve(ref: string): Schema {
    if (!ref.startsWith('#/')) throw new Error(`only local references: ${ref}`);
    let cur: Json = this.root;
    for (const part of ref.slice(2).split('/').map((p) => p.replace(/~1/g, '/').replace(/~0/g, '~'))) {
      if (!cur || typeof cur !== 'object' || Array.isArray(cur) || !(part in cur)) throw new Error(`unresolved reference ${ref}`);
      cur = cur[part]!;
    }
    if (typeof cur !== 'boolean' && (!cur || typeof cur !== 'object' || Array.isArray(cur))) throw new Error(`${ref} is no schema`);
    return cur as Schema;
  }

  // Every keyword known, every reference resolvable, every pattern a regular expression - throws otherwise
  check(schema: Json, where: string, seen = new Set<string>()): void {
    if (typeof schema === 'boolean') return;
    if (!schema || typeof schema !== 'object' || Array.isArray(schema)) throw new Error(`${where}: not a schema`);
    for (const [k, v] of Object.entries(schema)) {
      if (k.startsWith('x-')) continue;
      if (!ASSERTIONS.has(k) && !ANNOTATIONS.has(k)) throw new Error(`${where}: keyword "${k}" is not implemented by the validator`);
      if (k === '$ref') {
        if (typeof v !== 'string') throw new Error(`${where}: $ref must be a string`);
        if (Object.keys(schema).some((o) => o !== '$ref' && !ANNOTATIONS.has(o))) throw new Error(`${where}: $ref beside other assertions`);
        if (!seen.has(v)) { seen.add(v); this.check(this.resolve(v) as Json, v, seen); }
      }
      if (k === 'type') for (const t of Array.isArray(v) ? v : [v]) if (typeof t !== 'string' || !TYPES.has(t)) throw new Error(`${where}: unknown type ${String(t)}`);
      if (k === 'pattern') { if (typeof v !== 'string') throw new Error(`${where}: pattern`); this.regex(v); }
      if (k === 'enum' && (!Array.isArray(v) || !v.length)) throw new Error(`${where}: enum must be a non-empty list`);
      if (k === 'required' && (!Array.isArray(v) || v.some((r) => typeof r !== 'string'))) throw new Error(`${where}: required must list names`);
      if (k === 'properties') {
        if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error(`${where}: properties`);
        for (const [p, s] of Object.entries(v)) this.check(s, `${where}.${p}`, seen);
      }
      if (k === 'additionalProperties' || k === 'items') this.check(v, `${where}/${k}`, seen);
      if (k === 'oneOf' || k === 'anyOf' || k === 'allOf') {
        if (!Array.isArray(v) || !v.length) throw new Error(`${where}: ${k} must be a non-empty list`);
        v.forEach((s, n) => this.check(s, `${where}/${k}/${n}`, seen));
      }
    }
    if (Array.isArray(schema.required) && schema.properties && typeof schema.properties === 'object' && !Array.isArray(schema.properties))
      for (const r of schema.required as string[]) if (!(r in schema.properties)) throw new Error(`${where}: required "${r}" is not among its properties`);
  }

  private regex(p: string): RegExp {
    let r = this.patterns.get(p);
    if (!r) { r = new RegExp(p, 'u'); this.patterns.set(p, r); }
    return r;
  }

  validate(value: unknown, schema: Schema, path = '$'): Problem[] {
    const out: Problem[] = [];
    this.walk(value, schema, path, out);
    return out;
  }

  private walk(v: unknown, s: Schema, path: string, out: Problem[]): void {
    if (s === true) return;
    if (s === false) { out.push({ path, message: 'nothing is allowed here' }); return; }
    if (typeof s.$ref === 'string') { this.walk(v, this.resolve(s.$ref), path, out); return; }
    const bad = (message: string): void => { out.push({ path, message }); };
    if (s.type !== undefined) {
      const types = (Array.isArray(s.type) ? s.type : [s.type]) as string[];
      if (!types.some((t) => typeOk(v, t))) { bad(`${describe(v)} is not ${types.join(' or ')}`); return; }
    }
    if (s.const !== undefined && !same(v, s.const)) bad(`${JSON.stringify(v)} is not ${JSON.stringify(s.const)}`);
    if (Array.isArray(s.enum) && !s.enum.some((e) => same(v, e))) bad(`${JSON.stringify(v)} is none of ${JSON.stringify(s.enum)}`);
    if (typeof v === 'string') {
      if (typeof s.minLength === 'number' && [...v].length < s.minLength) bad(`shorter than ${s.minLength}`);
      if (typeof s.maxLength === 'number' && [...v].length > s.maxLength) bad(`longer than ${s.maxLength}`);
      if (typeof s.pattern === 'string' && !this.regex(s.pattern).test(v)) bad(`${JSON.stringify(v)} does not match ${s.pattern}`);
    }
    if (typeof v === 'number') {
      if (typeof s.minimum === 'number' && v < s.minimum) bad(`${v} < ${s.minimum}`);
      if (typeof s.maximum === 'number' && v > s.maximum) bad(`${v} > ${s.maximum}`);
    }
    if (Array.isArray(v)) {
      if (typeof s.minItems === 'number' && v.length < s.minItems) bad(`fewer than ${s.minItems} items`);
      if (typeof s.maxItems === 'number' && v.length > s.maxItems) bad(`more than ${s.maxItems} items`);
      if (s.items !== undefined) v.forEach((x, n) => this.walk(x, s.items as Schema, `${path}[${n}]`, out));
    }
    if (v && typeof v === 'object' && !Array.isArray(v)) {
      const o = v as Record<string, unknown>;
      const props = (s.properties ?? {}) as Record<string, Schema>;
      for (const r of (s.required ?? []) as string[]) if (!(r in o)) bad(`missing "${r}"`);
      if (typeof s.maxProperties === 'number' && Object.keys(o).length > s.maxProperties) bad(`more than ${s.maxProperties} properties`);
      if (typeof s.minProperties === 'number' && Object.keys(o).length < s.minProperties) bad(`fewer than ${s.minProperties} properties`);
      for (const [k, x] of Object.entries(o)) {
        if (k in props) this.walk(x, props[k]!, `${path}.${k}`, out);
        else if (s.additionalProperties !== undefined) this.walk(x, s.additionalProperties as Schema, `${path}.${k}`, out);
        else if (this.closed && (s.properties !== undefined || s.type === 'object')) bad(`"${k}" is not in the contract`);
      }
    }
    const branches = (key: 'oneOf' | 'anyOf' | 'allOf'): Problem[][] =>
      ((s[key] ?? []) as Schema[]).map((b) => this.validate(v, b, path));
    if (s.allOf) for (const r of branches('allOf')) out.push(...r);
    if (s.anyOf) { const r = branches('anyOf'); if (!r.some((p) => !p.length)) bad(`matches no anyOf branch: ${best(r)}`); }
    if (s.oneOf) {
      const r = branches('oneOf'), n = r.filter((p) => !p.length).length;
      if (n !== 1) bad(n ? `matches ${n} oneOf branches` : `matches no oneOf branch: ${best(r)}`);
    }
  }
}

function typeOk(v: unknown, t: string): boolean {
  switch (t) {
    case 'null': return v === null;
    case 'boolean': return typeof v === 'boolean';
    case 'number': return typeof v === 'number' && Number.isFinite(v);
    case 'integer': return typeof v === 'number' && Number.isInteger(v);
    case 'string': return typeof v === 'string';
    case 'array': return Array.isArray(v);
    case 'object': return !!v && typeof v === 'object' && !Array.isArray(v);
    default: return false;
  }
}

function describe(v: unknown): string { return v === null ? 'null' : Array.isArray(v) ? 'an array' : `a ${typeof v}`; }

function same(a: unknown, b: unknown): boolean { return JSON.stringify(a) === JSON.stringify(b); }

// The closest failing branch: the one with the fewest problems
function best(results: Problem[][]): string {
  const r = [...results].sort((a, b) => a.length - b.length)[0] ?? [];
  return r.slice(0, 3).map((p) => `${p.path}: ${p.message}`).join('; ');
}
