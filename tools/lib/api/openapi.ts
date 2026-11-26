// api/openapi.yaml as a checker: which operation a request is, whether the request and the answer keep
// the contract (statuses, content types, headers, bodies), and what of the contract a run exercised.

import { readFileSync } from 'node:fs';
import { parseYaml, type Json } from './yaml.ts';
import { SchemaSet, type Problem } from './schema.ts';

type Obj = { [k: string]: Json };
const METHODS = ['get', 'post', 'delete', 'put', 'patch', 'head', 'options'];

export interface Operation { id: string; method: string; template: string; op: Obj; params: Obj[] }
export interface Exchange {
  method: string; path: string; query: Record<string, string>; headers?: Record<string, string>;
  body?: unknown; bodyType?: string; invalidRequest?: boolean;
  status: number; contentType: string; responseHeaders: Record<string, string>; responseBody: Buffer;
}

const obj = (v: Json | undefined): Obj => (v && typeof v === 'object' && !Array.isArray(v) ? v : {});

export class Contract {
  readonly doc: Obj;
  readonly schemas: SchemaSet;
  readonly operations: Operation[] = [];
  readonly seen = new Map<string, Set<number>>();   // operation id -> statuses answered
  readonly codes = new Set<string>();                // error codes answered

  constructor(file: string) {
    this.doc = obj(parseYaml(readFileSync(file, 'utf8')));
    this.schemas = new SchemaSet(this.doc, true);
    if (this.doc.openapi !== '3.1.0') throw new Error('openapi: 3.1.0 expected');
    // every schema of the document compiled: unknown keywords, references, patterns
    for (const [name, s] of Object.entries(obj(obj(this.doc.components).schemas))) this.schemas.check(s, `#/components/schemas/${name}`);
    const ids = new Set<string>();
    for (const [template, item] of Object.entries(obj(this.doc.paths))) {
      for (const m of Object.keys(obj(item))) {
        if (m === 'servers' || m === 'parameters' || m === 'summary' || m === 'description') continue;
        if (!METHODS.includes(m)) throw new Error(`${template}: unknown key ${m}`);
        const op = obj(obj(item)[m]);
        const id = op.operationId;
        if (typeof id !== 'string' || ids.has(id)) throw new Error(`${m} ${template}: a unique operationId is required`);
        ids.add(id);
        const params = [...((obj(item).parameters ?? []) as Json[]), ...((op.parameters ?? []) as Json[])].map((p) => this.deref(p));
        for (const name of template.match(/\{[^}]+\}/g) ?? [])
          if (!params.some((p) => p.in === 'path' && `{${String(p.name)}}` === name)) throw new Error(`${id}: path parameter ${name} not declared`);
        for (const p of params) if (p.schema) this.schemas.check(p.schema, `${id} parameter ${String(p.name)}`);
        if (!Object.keys(obj(op.responses)).length) throw new Error(`${id}: no responses`);
        for (const [st, r] of Object.entries(obj(op.responses))) {
          if (!/^[1-5][0-9][0-9]$/.test(st)) throw new Error(`${id}: response ${st} is no status`);
          const resp = this.deref(r);
          if (typeof resp.description !== 'string') throw new Error(`${id} ${st}: a description is required`);
          for (const [type, media] of Object.entries(obj(resp.content))) {
            const s = obj(media).schema;
            if (s === undefined) throw new Error(`${id} ${st} ${type}: a schema is required`);
            this.schemas.check(s, `${id} ${st} ${type}`);
          }
        }
        for (const [type, media] of Object.entries(obj(obj(this.deref(op.requestBody ?? {})).content)))
          this.schemas.check(obj(media).schema ?? true, `${id} request ${type}`);
        this.operations.push({ id, method: m, template, op, params });
      }
    }
  }

  // A reference object -> what it names (parameters, responses, request bodies)
  deref(v: Json | undefined): Obj {
    const o = obj(v);
    if (typeof o.$ref !== 'string') return o;
    if (!o.$ref.startsWith('#/')) throw new Error(`only local references: ${o.$ref}`);
    let cur: Json = this.doc;
    for (const part of o.$ref.slice(2).split('/')) cur = obj(cur)[part] ?? null;
    if (!cur) throw new Error(`unresolved reference ${o.$ref}`);
    return this.deref(cur);
  }

  // The operation a request is: /api/<route> and /api/v<n>/<route> are the contract's /api/v1/<route>;
  // literal segments win over parameters; a parameter marked x-sofa-rest takes the rest of the path
  match(method: string, path: string): { op: Operation; params: Record<string, string> } | null {
    const norm = path.replace(/^\/api\/(v[0-9]+\/)?/, '/api/v1/');
    const parts = norm.split('/').filter(Boolean).map(decodeURIComponent);
    let best: { op: Operation; params: Record<string, string>; score: number } | null = null;
    for (const op of this.operations) {
      if (op.method !== method.toLowerCase()) continue;
      const tpl = op.template.split('/').filter(Boolean);
      const params: Record<string, string> = {};
      let score = 0, ok = true, rest = false;
      for (let k = 0; k < tpl.length && ok; k++) {
        const t = tpl[k]!, m = /^\{(.+)\}$/.exec(t);
        if (!m) { ok = parts[k] === t; score++; continue; }
        const decl = op.params.find((p) => p.in === 'path' && p.name === m[1]);
        rest = decl?.['x-sofa-rest'] === true && k === tpl.length - 1;
        ok = parts[k] !== undefined;
        params[m[1]!] = rest ? parts.slice(k).join('/') : parts[k] ?? '';
      }
      if (ok && (rest ? parts.length >= tpl.length : tpl.length === parts.length) && (!best || score > best.score)) best = { op, params, score };
    }
    return best ? { op: best.op, params: best.params } : null;
  }

  // Every problem of one exchange with the contract ([] = kept)
  check(x: Exchange): string[] {
    const m = this.match(x.method, x.path);
    if (!m) return [`${x.method} ${x.path}: no operation of the contract`];
    const { op, params } = m, out: string[] = [], at = `${op.id} (${x.method} ${x.path})`;
    const fail = (where: string, ps: Problem[]): void => { for (const p of ps.slice(0, 8)) out.push(`${at} ${where} ${p.path}: ${p.message}`); };
    // the request
    for (const p of op.params) {
      const v = p.in === 'path' ? params[String(p.name)] : p.in === 'query' ? x.query[String(p.name)] : p.in === 'header' ? x.headers?.[String(p.name).toLowerCase()] : undefined;
      if (v === undefined) { if (p.required === true) out.push(`${at}: required ${String(p.in)} parameter ${String(p.name)} missing`); continue; }
      const s = obj(p.schema), value = s.type === 'integer' || s.type === 'number' ? Number(v) : v;
      fail(`parameter ${String(p.name)}`, this.schemas.validate(value, s));
    }
    for (const q of Object.keys(x.query)) if (!op.params.some((p) => p.in === 'query' && p.name === q)) out.push(`${at}: query parameter ${q} is not in the contract`);
    const reqBody = this.deref(op.op.requestBody ?? {});
    if (x.invalidRequest) { /* refused on purpose: only the answer counts */ }
    else if (x.body !== undefined) {
      const media = obj(obj(reqBody.content)[x.bodyType ?? 'application/json']);
      if (!Object.keys(obj(reqBody.content)).length) out.push(`${at}: sends a body the contract doesn't take`);
      else if (!media.schema) out.push(`${at}: request type ${x.bodyType} is not in the contract`);
      else if ((x.bodyType ?? 'application/json') === 'application/json') fail('request', this.schemas.validate(x.body, media.schema as Obj));
    } else if (reqBody.required === true) out.push(`${at}: the request body is required`);
    if (x.invalidRequest && x.status < 400) out.push(`${at}: a request the contract refuses was answered ${x.status}`);
    // the answer
    if (!this.seen.has(op.id)) this.seen.set(op.id, new Set());
    this.seen.get(op.id)!.add(x.status);
    const resp = obj(op.op.responses)[String(x.status)];
    if (!resp) return [...out, `${at}: status ${x.status} is not in the contract (${x.responseBody.toString('utf8', 0, 200)})`];
    const r = this.deref(resp);
    for (const [h, decl] of Object.entries(obj(r.headers)))
      if (obj(decl).required === true && !(h.toLowerCase() in x.responseHeaders)) out.push(`${at} ${x.status}: header ${h} missing`);
    const content = obj(r.content);
    const type = x.contentType.split(';')[0]!.trim().toLowerCase();
    if (!Object.keys(content).length) {
      if (x.responseBody.length && x.method !== 'HEAD') out.push(`${at} ${x.status}: a body where the contract has none`);
      return out;
    }
    const media = content[type];
    if (!media) return [...out, `${at} ${x.status}: content type "${type}" is not in the contract (${Object.keys(content).join(', ')})`];
    if (type === 'application/json') {
      let body: unknown;
      try { body = JSON.parse(x.responseBody.toString('utf8')); } catch { return [...out, `${at} ${x.status}: not JSON`]; }
      fail(String(x.status), this.schemas.validate(body, obj(media).schema as Obj));
      const code = (body as { code?: unknown } | null)?.code;
      if (x.status >= 400 && typeof code === 'string') this.codes.add(code);
    }
    return out;
  }

  // What the run did not exercise: operations never called, statuses never answered
  coverage(): { missing: string[]; unseen: string[]; total: number; statuses: number; seenStatuses: number } {
    const missing: string[] = [], unseen: string[] = [];
    let statuses = 0, seenStatuses = 0;
    for (const op of this.operations) {
      const seen = this.seen.get(op.id);
      if (!seen) missing.push(op.id);
      for (const st of Object.keys(obj(op.op.responses))) {
        statuses++;
        if (seen?.has(Number(st))) seenStatuses++; else unseen.push(`${op.id} ${st}`);
      }
    }
    return { missing, unseen, total: this.operations.length, statuses, seenStatuses };
  }

  errorCodes(): string[] {
    return (obj(obj(obj(this.doc.components).schemas).ErrorCode).enum as string[]).slice().sort();
  }
}
