// The messages between Sofa and the engine page (docs/youtube-engine.md "Channel"). Sofa sends
// commands; the page answers each by id and sends events on its own. Structured values on the
// extension's hops (page-main.ts <-> bridge.ts <-> background.ts: bytes stay Uint8Array); on the
// WebSocket to Sofa a batch of them is JSON text, or the binary container when it carries bytes.
import type { EngineEvent, SofaEngine } from './engine.ts';

/** The engine calls Sofa may make (everything of SofaEngine except connect). */
export const METHODS = ['health', 'start', 'block', 'open', 'read', 'playlist', 'segment', 'subtitles', 'status', 'report', 'startsAt', 'close', 'innertube', 'suggest',
  'availability', 'image', 'loungeRequest', 'loungePoll', 'stop'] as const;
export type Method = typeof METHODS[number];
// Every engine call must be listed - the compiler names a missing one here. (image and the lounge
// calls were missing on 2026-11-07: the page dropped them unanswered, Sofa waited out its timeouts.)
type Unlisted = Exclude<Exclude<keyof SofaEngine, 'connect'>, Method>;
const everyCallListed: [Unlisted] extends [never] ? true : Unlisted = true;
void everyCallListed;

export interface Command { id: number; method: Method; args: unknown[] }
export type Answer = { id: number; value: unknown } | { id: number; error: string };
/** One engine event as the page hands it to the bridge. */
export interface EventMessage { event: EngineEvent }

/** What the extension sends Sofa in one WebSocket message. */
export interface Upload { answers: Answer[]; events: EngineEvent[] }

/**
 * One upload as a WebSocket message: JSON text, or - when values carry bytes (media, pictures,
 * lounge data) - binary: u32 BE length + that JSON, then per Uint8Array its u32 BE length + bytes,
 * the JSON holding `{"$blob": n}` in its place (no base64: 8 MB of media is a copy, not 11 MB of
 * text to encode and parse). Sofa's decoder: SFYTChannelDecodeBinary.
 */
export function encodeUpload(up: Upload): string | Uint8Array<ArrayBuffer> {
  const blobs: Uint8Array[] = [];
  const json = JSON.stringify(up, (_k, v: unknown) => {
    if (v instanceof Uint8Array) { blobs.push(v); return { $blob: blobs.length - 1 }; }
    return v;
  });
  if (!blobs.length) return json;
  const head = new TextEncoder().encode(json);
  const out = new Uint8Array(4 + head.length + blobs.reduce((n, b) => n + 4 + b.length, 0));
  const view = new DataView(out.buffer);
  let at = 0;
  for (const part of [head, ...blobs]) {
    view.setUint32(at, part.length);
    out.set(part, at + 4);
    at += 4 + part.length;
  }
  return out;
}

/** The inverse of encodeUpload (tests play Sofa with it); throws on a malformed message. */
export function decodeUpload(m: string | Uint8Array): Upload {
  if (typeof m === 'string') return JSON.parse(m) as Upload;
  const view = new DataView(m.buffer, m.byteOffset, m.byteLength);
  const parts: Uint8Array[] = [];
  for (let at = 0; at < m.length;) {
    if (at + 4 > m.length) throw new Error('channel: truncated length');
    const n = view.getUint32(at);
    if (at + 4 + n > m.length) throw new Error('channel: truncated block');
    parts.push(m.subarray(at + 4, at + 4 + n));
    at += 4 + n;
  }
  const [head, ...blobs] = parts;
  if (!head) throw new Error('channel: empty message');
  return JSON.parse(new TextDecoder().decode(head), (_k, v: unknown) => {
    if (typeof v === 'object' && v !== null && !Array.isArray(v) && Object.keys(v).length === 1 && typeof (v as { $blob?: unknown }).$blob === 'number') {
      const b = blobs[(v as { $blob: number }).$blob];
      if (!b) throw new Error('channel: missing block');
      return b;
    }
    return v;
  }) as Upload;
}

/** A command with a method this page does not have: answered at once instead of dropped (no timeout). */
export function unknownCommand(x: unknown): Answer | null {
  if (typeof x !== 'object' || x === null) return null;
  const c = x as Partial<Command>;
  return typeof c.id === 'number' && !isCommand(x) ? { id: c.id, error: `unknown engine call: ${String(c.method)}` } : null;
}

export function isCommand(x: unknown): x is Command {
  if (typeof x !== 'object' || x === null) return false;
  const c = x as Partial<Command>;
  return typeof c.id === 'number' && typeof c.method === 'string' && (METHODS as readonly string[]).includes(c.method) && Array.isArray(c.args);
}

/** Run one command on the engine; never throws (a failed call is an error answer). */
export async function dispatch(engine: SofaEngine, cmd: Command): Promise<Answer> {
  try {
    const fn = engine[cmd.method] as (...a: unknown[]) => unknown;
    return { id: cmd.id, value: (await fn(...cmd.args)) ?? null };
  } catch (e) {
    return { id: cmd.id, error: e instanceof Error ? e.message : String(e) };
  }
}

/**
 * The page and the bridge meet once at document_start, before any page script runs: the page posts
 * a MessagePort with this marker; from then on everything goes over that private port, which the
 * page's own scripts never see.
 */
export const HELLO = 'sofa-engine-hello-7f3c9a';
