// The messages between Sofa and the engine page (docs/youtube-engine.md "Channel"). Sofa sends
// commands; the page answers each by id and sends events on its own. Plain JSON, the same on every
// hop: Sofa's loopback server <-> the extension's bridge (bridge.ts) <-> the page (page-main.ts).
import type { SofaEngine } from './engine.ts';

/** The engine calls Sofa may make (everything of SofaEngine except connect). */
export const METHODS = ['health', 'start', 'block', 'open', 'read', 'playlist', 'subtitles', 'status', 'close', 'innertube', 'suggest', 'stop'] as const;
export type Method = typeof METHODS[number];

export interface Command { id: number; method: Method; args: unknown[] }
export type Answer = { id: number; value: unknown } | { id: number; error: string };
/** One engine event, JSON as connect() sends it (EngineEvent). */
export interface EventMessage { event: string }

/** What the bridge sends Sofa in one POST. */
export interface Upload { answers: Answer[]; events: string[] }

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
