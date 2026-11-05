// stderr logging, every line prefixed "sofa-yt:" (Sofa forwards the sidecar's stderr into its log).
// stdout is reserved for the single readiness line.
let quiet = false;
let debugOn = !!process.env.SOFA_YT_DEBUG;

export function setQuiet(q: boolean): void { quiet = q; }
export function setDebug(d: boolean): void { debugOn = d; }

function fmt(args: unknown[]): string {
  return args.map((a) => (a instanceof Error ? a.message : typeof a === 'string' ? a : JSON.stringify(a))).join(' ');
}

export function log(...args: unknown[]): void {
  if (!quiet) process.stderr.write(`sofa-yt: ${fmt(args)}\n`);
}

export function debug(...args: unknown[]): void {
  if (debugOn && !quiet) process.stderr.write(`sofa-yt: [debug] ${fmt(args)}\n`);
}
