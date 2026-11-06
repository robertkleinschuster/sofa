// youtube.com enforces Trusted Types (CSP require-trusted-types-for 'script'): a string handed to a
// script sink - <script src>, new Function - is blocked and raises a securitypolicyviolation, which
// the page can report (measured 2026-11-06 in Firefox 153). The engine passes its strings through one
// policy of its own, as YouTube's code does with its policies; no violation, no report.

interface TrustedTypePolicyLike {
  createScript(s: string): unknown;
  createScriptURL(s: string): unknown;
}

const INTERPRETER_ORIGIN = 'https://www.google.com';   // BotGuard's interpreter (attest())

let policy: TrustedTypePolicyLike | null | undefined;

function engineType(): TrustedTypePolicyLike | null {
  if (policy === undefined) {
    const tt = (globalThis as { trustedTypes?: { createPolicy(name: string, rules: object): TrustedTypePolicyLike } }).trustedTypes;
    policy = tt ? tt.createPolicy('sofa-engine', {
      createScript: (s: string) => s,
      createScriptURL: (u: string) => {
        if (new URL(u).origin !== INTERPRETER_ORIGIN) throw new TypeError(`sofa-engine: script URL outside ${INTERPRETER_ORIGIN}: ${u}`);
        return u;
      },
    }) : null;
  }
  return policy;
}

/** A script URL the page lets a <script> load (BotGuard's interpreter only). */
export function scriptURL(url: string): string {
  return (engineType()?.createScriptURL(url) ?? url) as string;
}

/** Compile `code` as a function body (youtubei.js' player transforms). */
export function compile(code: string): () => unknown {
  const p = engineType();
  // eslint-disable-next-line no-new-func -- the player's own n/sig code, through the engine's policy
  return new Function((p ? p.createScript(code) : code) as string) as () => unknown;
}

/** Create the policy now: at preload time, before the page's scripts run. */
export function initTrustedTypes(): void { engineType(); }
