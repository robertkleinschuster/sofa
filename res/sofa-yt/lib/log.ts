// Logging, every line prefixed "sofa-yt:". Where it goes depends on the runtime: in node stderr
// (Sofa forwards the sidecar's stderr into its log; stdout is reserved for the readiness line), in the
// browser engine the console (Sofa reads it over WebDriver BiDi, docs/youtube-engine.md). No node
// types here: the module runs in both.

/** The bits of node's `process` this module uses, when it exists. */
interface NodeProcessLike {
  stderr?: { write(s: string): unknown };
  env?: Record<string, string | undefined>;
}
const proc = (globalThis as { process?: NodeProcessLike }).process;

/** Where finished log lines go (one line, no newline). */
export type LogSink = (line: string) => void;

let sink: LogSink = proc?.stderr ? (line) => { proc.stderr!.write(`${line}\n`); } : (line) => { console.log(line); };
let quiet = false;
let debugOn = !!proc?.env?.SOFA_YT_DEBUG;

export function setQuiet(q: boolean): void { quiet = q; }
export function setDebug(d: boolean): void { debugOn = d; }
export function setLogSink(s: LogSink): void { sink = s; }

function fmt(args: unknown[]): string {
  return args.map((a) => (a instanceof Error ? a.message : typeof a === 'string' ? a : JSON.stringify(a))).join(' ');
}

export function log(...args: unknown[]): void {
  if (!quiet) sink(`sofa-yt: ${fmt(args)}`);
}

export function debug(...args: unknown[]): void {
  if (debugOn && !quiet) sink(`sofa-yt: [debug] ${fmt(args)}`);
}
