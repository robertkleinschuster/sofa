// The EU consent dialog of a fresh profile (docs/youtube-engine.md "Consent"): YouTube's overlay
// <ytd-consent-bump-v2-lightbox> on www.youtube.com itself. The engine profile accepts it once, as a
// user does: Sofa clicks with the pointer of the engine's display (XTest) - a trusted event, where a
// click from page script would be isTrusted=false. This module only finds the accept button and
// reports where it is on the screen; it never clicks.
//
// The button is found by what it does, not by its (localised) label: its renderer's command is a
// saveConsentAction ("Alle ablehnen" carries a disablePersonalizationAction, measured 2026-11-07).
import { isRecord } from '../lib/json.ts';

/** The accept button on the display, in screen pixels. */
export interface ConsentTarget { x: number; y: number; width: number; height: number }

const DIALOG = 'ytd-consent-bump-v2-lightbox';
const CHECK_MS = 500;
const STABLE_MS = 1000;    // the same position this long: layout (fonts, animation) has settled
const REPEAT_MS = 15000;   // still there after a click this long: report it again

function acceptButton(): Element | null {
  const dialog = document.querySelector(DIALOG);
  if (!dialog) return null;
  for (const r of dialog.querySelectorAll('ytd-button-renderer')) {
    const data: unknown = (r as Element & { data?: unknown }).data;
    if (isRecord(data) && isRecord(data.command) && isRecord(data.command.saveConsentAction)) return r.querySelector('button') ?? r;
  }
  return null;
}

/** Where the accept button is, or null: no dialog, not laid out, or covered by something else. */
export function consentTarget(): ConsentTarget | null {
  const button = acceptButton();
  if (!button) return null;
  const r = button.getBoundingClientRect();
  if (r.width < 4 || r.height < 4) return null;
  const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
  if (!hit || !button.contains(hit)) return null;
  // the viewport's origin on the screen (Firefox), CSS -> device pixels
  const w = window as Window & { mozInnerScreenX?: number; mozInnerScreenY?: number };
  if (typeof w.mozInnerScreenX !== 'number' || typeof w.mozInnerScreenY !== 'number') return null;
  const s = window.devicePixelRatio;
  return {
    x: Math.round((w.mozInnerScreenX + r.x) * s), y: Math.round((w.mozInnerScreenY + r.y) * s),
    width: Math.round(r.width * s), height: Math.round(r.height * s),
  };
}

/** Reports the accept button once its position is settled, again if it is still there later. */
export function watchConsent(report: (target: ConsentTarget) => void): void {
  let last = '';
  let since = 0;
  let reportedAt = -Infinity;
  setInterval(() => {
    const target = consentTarget();
    const key = target ? JSON.stringify(target) : '';
    const now = performance.now();
    if (key !== last) { last = key; since = now; return; }
    if (!target || now - since < STABLE_MS || now - reportedAt < REPEAT_MS) return;
    reportedAt = now;
    report(target);
  }, CHECK_MS);
}
