// A strict reader of the YAML subset api/openapi.yaml is written in (YAML 1.2 core schema): block
// mappings and sequences by indentation (spaces), plain, single- and double-quoted scalars, flow
// sequences of scalars (`[a, b]`), the empty flow mapping `{}`, literal and folded blocks (`|`, `>`,
// with `-`/`+` chomping), comments. Anything else - anchors, aliases, tags, flow mappings with
// content, multi-line plain or quoted scalars, duplicate keys, tabs - is refused with its line, never
// read approximately: what this reader accepts means the same to every YAML parser.

export type Json = null | boolean | number | string | Json[] | { [k: string]: Json };

export class YamlError extends Error {
  constructor(line: number, message: string) { super(`yaml line ${line}: ${message}`); }
}

interface Line { no: number; indent: number; text: string }   // text: without indentation and comment

// A comment starts at a # preceded by a space (or at the line's start), outside quotes
function stripComment(s: string, no: number): string {
  let quote: string | null = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i]!;
    if (quote) {
      if (quote === "'" && c === "'" && s[i + 1] === "'") { i++; continue; }
      if (quote === '"' && c === '\\') { i++; continue; }
      if (c === quote) quote = null;
      continue;
    }
    if ((c === "'" || c === '"') && (i === 0 || /[\s[,:-]/.test(s[i - 1]!))) { quote = c; continue; }
    if (c === '#' && (i === 0 || s[i - 1] === ' ')) return s.slice(0, i).trimEnd();
  }
  if (quote) throw new YamlError(no, 'a quoted scalar must end on its line');
  return s.trimEnd();
}

const INT = /^[-+]?[0-9]+$/, FLOAT = /^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$/;

export function scalar(raw: string, no: number): Json {
  const s = raw.trim();
  if (s === '' || s === '~' || s === 'null') return null;
  if (s.startsWith("'")) {
    if (!s.endsWith("'") || s.length < 2) throw new YamlError(no, `unterminated single-quoted scalar: ${s}`);
    const body = s.slice(1, -1);
    if (/(^|[^'])'($|[^'])/.test(body.replace(/''/g, ''))) throw new YamlError(no, `a lone quote inside: ${s}`);
    return body.replace(/''/g, "'");
  }
  if (s.startsWith('"')) {
    if (!s.endsWith('"') || s.length < 2) throw new YamlError(no, `unterminated double-quoted scalar: ${s}`);
    try { return JSON.parse(s) as string; } catch { throw new YamlError(no, `a double-quoted scalar outside JSON's escapes: ${s}`); }
  }
  if (s === '{}') return {};
  if (s.startsWith('[')) {
    if (!s.endsWith(']')) throw new YamlError(no, `a flow sequence must end on its line: ${s}`);
    const inner = s.slice(1, -1).trim();
    if (!inner) return [];
    return inner.split(',').map((part) => {
      const p = part.trim();
      if (!p || /^[[\]{}]/.test(p) || /[[\]{}]/.test(p)) throw new YamlError(no, `only scalars in a flow sequence: ${s}`);
      return scalar(p, no);
    });
  }
  if (/^[&*!|>%@`{]/.test(s)) throw new YamlError(no, `not in the subset (anchor, alias, tag, block or reserved indicator): ${s}`);
  if (/^[-?:,\]}](\s|$)/.test(s)) throw new YamlError(no, `an indicator can't start a plain scalar: ${s}`);
  if (/:\s/.test(s) || s.endsWith(':')) throw new YamlError(no, `": " inside a plain scalar - quote it: ${s}`);
  if (/\s#/.test(s)) throw new YamlError(no, `" #" inside a plain scalar - quote it: ${s}`);
  if (s === 'true') return true;
  if (s === 'false') return false;
  if (INT.test(s)) return Number(s);
  if (FLOAT.test(s)) return Number(s);
  if (/^(True|TRUE|False|FALSE|Null|NULL|\.inf|\.nan|-\.inf|0x|0o)/i.test(s)) throw new YamlError(no, `ambiguous between YAML versions - quote it: ${s}`);
  return s;
}

export function parseYaml(text: string): Json {
  const raw = text.split('\n');
  const lines: (Line & { raw: string })[] = [];
  raw.forEach((r, i) => {
    const no = i + 1;
    if (r.includes('\t')) throw new YamlError(no, 'tabs are not allowed');
    if (/^(---|\.\.\.)(\s|$)/.test(r)) throw new YamlError(no, 'one document only, no markers');
    const indent = r.length - r.trimStart().length;
    lines.push({ no, indent, text: r.trim() === '' ? '' : r.slice(indent), raw: r });
  });
  let i = 0;

  const next = (): (Line & { raw: string }) | null => {   // the next line with content (comments and blanks skipped)
    while (i < lines.length) {
      const l = lines[i]!;
      if (l.text === '' || l.text.startsWith('#')) { i++; continue; }
      return { ...l, text: stripComment(l.text, l.no) };
    }
    return null;
  };

  // A literal (|) or folded (>) block: the lines indented deeper than `parent`
  const block = (indicator: string, parent: number, no: number): string => {
    const m = /^([|>])([-+]?)$/.exec(indicator);
    if (!m) throw new YamlError(no, `a block indicator of the subset is |, >, |-, |+, >-, >+: ${indicator}`);
    const body: string[] = [];
    let indent = -1;
    while (i < lines.length) {
      const l = lines[i]!;
      if (l.raw.trim() === '') { body.push(''); i++; continue; }
      if (l.indent <= parent) break;
      if (indent < 0) indent = l.indent;
      if (l.indent < indent) throw new YamlError(l.no, 'a block line less indented than its first');
      body.push(l.raw.slice(indent));
      i++;
    }
    while (body.length && body[body.length - 1] === '' && m[2] !== '+') body.pop();
    let out: string;
    if (m[1] === '|') out = body.join('\n');
    else {   // folded: lines of one paragraph joined by a space, an empty line is a newline
      out = '';
      for (let k = 0; k < body.length; k++) {
        const b = body[k]!;
        if (b === '') out += '\n';
        else out += (k > 0 && body[k - 1] !== '' && !out.endsWith('\n') ? ' ' : '') + b;
      }
    }
    return m[2] === '-' ? out : out + '\n';
  };

  // The value after "key:" or "- " (its line already consumed): a scalar, a block, or the nested node
  // on the following lines
  const value = (rest: string, indent: number, no: number): Json => {
    if (rest === '') {
      const n = next();
      if (!n || n.indent < indent || (n.indent === indent && !(n.text === '-' || n.text.startsWith('- ')))) return null;
      return node(n.indent);   // deeper, or a sequence at the key's own indentation
    }
    if (/^[|>][-+]?$/.test(rest)) return block(rest, indent, no);
    return scalar(rest, no);
  };

  const KEY = /^("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s'"#[{][^:#]*?):(?:\s+(.*))?$/;
  const isItem = (t: string): boolean => t === '-' || t.startsWith('- ');

  const node = (indent: number): Json => {
    const first = next();
    if (!first) return null;
    if (first.indent !== indent) throw new YamlError(first.no, `indentation ${first.indent}, expected ${indent}`);
    if (isItem(first.text)) {
      const seq: Json[] = [];
      for (let l = next(); l && l.indent === indent && isItem(l.text); l = next()) {
        const rest = l.text.slice(1).trimStart();
        if (KEY.test(rest)) {
          // "- key: value": a mapping whose first key sits after the dash - read as if it were indented there
          const inner = indent + (l.text.length - rest.length);
          lines[i] = { ...lines[i]!, indent: inner, text: rest, raw: ' '.repeat(inner) + rest };
          seq.push(node(inner));
        } else { i++; seq.push(value(rest, indent + 1, l.no)); }
      }
      const after = next();
      if (after && after.indent > indent) throw new YamlError(after.no, 'unexpected indentation after a sequence');
      return seq;
    }
    const map: { [k: string]: Json } = {};
    for (let l = next(); l && l.indent === indent && !isItem(l.text); l = next()) {
      const m = KEY.exec(l.text);
      if (!m) throw new YamlError(l.no, `expected "key: value": ${l.text}`);
      const k = scalar(m[1]!, l.no);
      if (typeof k !== 'string' && typeof k !== 'number') throw new YamlError(l.no, `a key must be a string: ${m[1]}`);
      const key = String(k);
      if (Object.prototype.hasOwnProperty.call(map, key)) throw new YamlError(l.no, `duplicate key ${key}`);
      i++;
      Object.defineProperty(map, key, { value: value((m[2] ?? '').trim(), indent, l.no), enumerable: true, writable: true, configurable: true });
    }
    const after = next();
    if (after && after.indent > indent) throw new YamlError(after.no, `unexpected indentation (${after.indent}) - a value on its own line after a scalar?`);
    return map;
  };

  const root = next();
  if (!root) return null;
  if (root.indent !== 0) throw new YamlError(root.no, 'the document starts indented');
  const doc = node(0);
  const rest = next();
  if (rest) throw new YamlError(rest.no, `content after the document: ${rest.text}`);
  return doc;
}
