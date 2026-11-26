// The screens around the content: connecting (host name), pairing (the TV's code), not reachable,
// settings. German texts for the user; every step says what to do next.

import { ApiError, type Api } from './api.ts';
import { discoveryURL, needsDiscovery, normalizeHost, shortName, type Connection } from './connection.ts';
import { h, icon, ICONS } from './dom.ts';

export function appURL(): string { return location.origin + location.pathname; }

export function connectScreen(prefill: string, onHost: (host: string) => void, error?: string): HTMLElement {
  const input = h('input.field', {
    type: 'text', inputmode: 'url', autocapitalize: 'off', autocomplete: 'off', spellcheck: false,
    placeholder: 'imac', value: prefill, 'aria-label': 'Name des Macs im Tailnet',
  });
  const problem = h('p.form-error', { role: 'alert' }, error ?? '');
  problem.hidden = !error;
  const submit = (e: Event): void => {
    e.preventDefault();
    const host = normalizeHost(input.value || 'imac');
    if (!host) { problem.textContent = 'Das ist kein gültiger Name.'; problem.hidden = false; return; }
    if (needsDiscovery(host)) {
      // the short name has no certificate: Sofa's connect route answers with the full name
      location.href = discoveryURL(host, appURL());
      return;
    }
    onHost(host);
  };
  return h('div.screen', null,
    h('div.screen-card', null,
      h('h1.wordmark-big', null, 'Sofa'),
      h('p.lead', null, 'Sofa im Browser – schau, was auf deinem Fernseher ist, auf diesem Gerät.'),
      h('ol.steps', null,
        h('li', null, 'Dieses Gerät ist mit Tailscale verbunden (dasselbe Tailnet wie der Mac).'),
        h('li', null, 'Gib den Namen des Macs ein – meist einfach „imac“.')),
      h('form.form', { onsubmit: submit }, input, h('button.button.primary', { type: 'submit' }, 'Verbinden')),
      problem,
      h('p.hint', null, 'Fragt der Browser nach Zugriff auf Geräte im lokalen Netzwerk, bitte erlauben – so erreicht er Sofa über Tailscale.')));
}

function deviceName(): string {
  const ua = navigator.userAgent;
  const os = /iPhone/.test(ua) ? 'iPhone' : /iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ? 'iPad'
    : /Android/.test(ua) ? 'Android' : /Mac OS X/.test(ua) ? 'Mac' : /Windows/.test(ua) ? 'Windows' : /Linux/.test(ua) ? 'Linux' : 'Gerät';
  const browser = /Edg\//.test(ua) ? 'Edge' : /Firefox|FxiOS/.test(ua) ? 'Firefox' : /Chrome|CriOS/.test(ua) ? 'Chrome' : /Safari/.test(ua) ? 'Safari' : 'Browser';
  return `${browser} auf ${os}`;
}

// `scanned`: the code of the TV's pairing link (its QR code) - entered and sent at once; `notice`: why
// this device has to pair (again), e.g. it was removed on the TV
export function pairScreen(api: Api, onPaired: (token: string) => void, onOtherHost: () => void, scanned?: string, notice?: string): HTMLElement {
  const code = h('input.field.code', {
    type: 'text', inputmode: 'numeric', autocomplete: 'one-time-code', maxlength: 6, pattern: '[0-9]{6}',
    placeholder: '000000', 'aria-label': 'Code vom Fernseher',
  });
  const name = h('input.field', { type: 'text', value: deviceName(), maxlength: 40, 'aria-label': 'Name dieses Geräts' });
  const problem = h('p.form-error', { role: 'alert' });
  problem.hidden = true;
  const button = h('button.button.primary.wide', { type: 'submit' }, 'Verbinden');
  const submit = async (e: Event): Promise<void> => {
    e.preventDefault();
    const c = code.value.replace(/\D/g, '');
    if (c.length !== 6) { problem.textContent = 'Der Code hat sechs Ziffern.'; problem.hidden = false; return; }
    button.disabled = true;
    try {
      const r = await api.pair(c, name.value.trim() || deviceName());
      onPaired(r.token);
    } catch (err) {
      problem.textContent = err instanceof ApiError ? err.message : 'Das hat nicht geklappt.';
      problem.hidden = false;
      code.select();
    } finally { button.disabled = false; }
  };
  code.addEventListener('input', () => { code.value = code.value.replace(/\D/g, '').slice(0, 6); });
  if (scanned) { code.value = scanned; queueMicrotask(() => { void submit(new Event('submit')); }); }
  else requestAnimationFrame(() => code.focus());
  return h('div.screen', null,
    h('div.screen-card', null,
      h('h1.wordmark-big', null, 'Sofa'),
      h('p.lead', null, `Mit „${shortName(api.connection.host)}“ verbinden`),
      notice ? h('p.notice', { role: 'status' }, notice) : null,
      h('ol.steps', null,
        h('li', null, 'Am Fernseher: Einstellungen → Sofa im Browser.'),
        h('li', null, 'Den sechsstelligen Code hier eingeben – oder den QR-Code daneben mit der Handykamera scannen.')),
      h('form.form', { onsubmit: submit },
        code,
        h('label.label', null, 'Name dieses Geräts', name),
        button),
      problem,
      h('p.hint', null, 'Fragt der Browser nach Zugriff auf Geräte im lokalen Netzwerk, bitte erlauben – sonst erreicht er Sofa nicht.'),
      h('button.link', { type: 'button', onclick: onOtherHost }, 'Anderen Mac wählen')));
}

// Sofa did not answer: what to check, a retry - and it comes back by itself: every few seconds and
// when the device is online again a quiet probe asks Sofa (no reload flashing the screen).
const PROBE_MS = 8_000;
export function unreachableScreen(c: Connection, error: ApiError, probe: () => Promise<unknown>, retry: () => void, onOtherHost: () => void): HTMLElement {
  const reasons = error.unreachable
    ? [
      'Ist Tailscale auf diesem Gerät eingeschaltet?',
      'Läuft der Mac (und Sofa)?',
      'Hat der Browser nach Zugriff auf das lokale Netzwerk gefragt? Dann bitte erlauben (in den Website-Einstellungen änderbar).',
    ]
    : [error.message];
  const state = h('p.hint', { role: 'status', 'aria-live': 'polite' }, 'Sobald Sofa erreichbar ist, geht es von selbst weiter.');
  const button = h('button.button.primary', { type: 'button' }, 'Erneut versuchen');
  let busy = false;
  const attempt = async (byUser: boolean): Promise<void> => {
    if (busy || !el.isConnected) return;
    busy = true;
    if (byUser) { button.disabled = true; button.textContent = 'Wird versucht …'; }
    try { await probe(); stop(); retry(); } catch {
      if (byUser) state.textContent = 'Immer noch nicht erreichbar. Es wird weiter versucht.';
    } finally { busy = false; button.disabled = false; button.textContent = 'Erneut versuchen'; }
  };
  button.addEventListener('click', () => void attempt(true));
  const timer = setInterval(() => { if (!el.isConnected) stop(); else if (!document.hidden) void attempt(false); }, PROBE_MS);
  const online = (): void => void attempt(false);
  const stop = (): void => { clearInterval(timer); removeEventListener('online', online); };
  addEventListener('online', online);
  const el = h('div.screen', null,
    h('div.screen-card', null,
      h('div.screen-icon', null, icon(ICONS.offline)),
      h('h1', null, `„${shortName(c.host)}“ ist gerade nicht erreichbar`),
      h('ul.steps', null, ...reasons.map((r) => h('li', null, r))),
      h('div.form', null, button),
      state,
      h('button.link', { type: 'button', onclick: () => { stop(); onOtherHost(); } }, 'Anderen Mac wählen')));
  return el;
}

export function settingsScreen(c: Connection, device: string, version: string, unpair: () => Promise<void>, onOtherHost: () => void): HTMLElement {
  const confirm = h('div.confirm');
  confirm.hidden = true;
  const ask = h('button.button.wide', { type: 'button', onclick: () => { confirm.hidden = false; ask.hidden = true; (confirm.querySelector('.danger') as HTMLElement | null)?.focus(); } }, 'Dieses Gerät trennen');
  confirm.append(
    h('p', null, 'Danach braucht dieses Gerät wieder einen Code vom Fernseher.'),
    h('div.form', null,
      h('button.button.danger', { type: 'button', onclick: () => { void unpair(); } }, 'Ja, trennen'),
      h('button.button', { type: 'button', onclick: () => { confirm.hidden = true; ask.hidden = false; ask.focus(); } }, 'Abbrechen')));
  return h('div.screen', null,
    h('div.screen-card', null,
      h('h1', null, 'Einstellungen'),
      h('dl.facts', null,
        h('div', null, h('dt', null, 'Verbunden mit'), h('dd', null, shortName(c.host))),
        h('div', null, h('dt', null, 'Dieses Gerät'), h('dd', null, device || '–')),
        h('div', null, h('dt', null, 'Sofa-Version'), h('dd.version', null, version || '–'))),
      h('p.hint', null, 'Verlauf, „Später ansehen“ und gefolgte Sendungen sind dieselben wie am Fernseher.'),
      h('div.stack', null, ask, confirm,
        h('button.button.wide.quiet', { type: 'button', onclick: onOtherHost }, 'Anderen Mac wählen'))));
}
