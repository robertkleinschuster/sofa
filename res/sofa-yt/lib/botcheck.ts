// Recognising YouTube's bot check in an answer - plain text logic, runs in node and in the browser
// engine (the pause itself is Sofa's breaker file, lib/breaker.ts / SFYTBreaker).

/** Does a playability status / error text mean YouTube's bot check? */
export function isBotCheck(text: string | null | undefined): boolean {
  const m = String(text || '').toLowerCase();
  return m.includes('not a bot') || m.includes('sign in to confirm');
}
