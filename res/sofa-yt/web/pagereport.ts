// The page's side of a view's stats pings (lib/report.ts): the client facts youtube.com's player
// takes from its page and player script, and its transports - XHR for stats/playback and watchtime,
// fetch for qoe and ptracking, all same-origin from this page (its cookies, Firefox's connection).
import type { Reporting } from '../lib/engine.ts';
import type { ReportClient, Transport } from '../lib/report.ts';
import { encodeFexp, playerBuild } from '../lib/report.ts';
import { isRecord } from '../lib/json.ts';
import { log } from '../lib/log.ts';
import { errorMessage } from '../lib/errors.ts';
import { pageClient, pageString, pageValue } from './page.ts';

const WATCH_PLAYER = 'WEB_PLAYER_CONTEXT_CONFIG_ID_KEVLAR_WATCH';

async function clientFacts(): Promise<ReportClient | null> {
  const js = pageString('PLAYER_JS_URL');
  const xsrf = pageString('XSRF_TOKEN');
  const players = pageValue('WEB_PLAYER_CONTEXT_CONFIGS');
  const watch = isRecord(players) && isRecord(players[WATCH_PLAYER]) ? players[WATCH_PLAYER] : null;
  const ids = watch && typeof watch.serializedExperimentIds === 'string' ? watch.serializedExperimentIds : '';
  if (!js || !xsrf || !ids) { log(`report: page lacks ${[!js && 'PLAYER_JS_URL', !xsrf && 'XSRF_TOKEN', !ids && 'experiment ids'].filter(Boolean).join(', ')}`); return null; }
  // the player script the page loaded (its HTTP cache): the build number the player reports
  const cl = playerBuild(await (await fetch(js, { cache: 'force-cache' })).text());
  if (!cl) { log('report: no build number in the player script'); return null; }
  const c = pageClient();
  const s = (k: string): string => (typeof c[k] === 'string' ? c[k] as string : '');
  const locale = /\/([a-z]{2,3}_[A-Z]{2})\/base\.js/.exec(js)?.[1] ?? '';
  const facts: ReportClient = {
    cl, fexp: encodeFexp(ids), xsrf, hl: locale || s('hl'), cr: pageString('GL') || s('gl'),
    cbrand: s('deviceMake').toLowerCase(), cbr: s('browserName'), cbrver: s('browserVersion'), c: s('clientName'), cver: s('clientVersion'),
    cos: s('osName'), cosver: s('osVersion'), cplatform: s('platform'), view: null,
  };
  const missing = Object.entries(facts).filter(([k, v]) => k !== 'view' && !v).map(([k]) => k);
  if (missing.length) { log(`report: page client lacks ${missing.join(', ')}`); return null; }
  return facts;
}

function send(transport: Transport, method: 'GET' | 'POST', url: string, body: string | null, contentType: string | null): void {
  const path = new URL(url).pathname;
  const failed = (what: string): void => log(`report: ${path} ${what}`);
  if (transport === 'xhr') {
    const x = new XMLHttpRequest();
    x.open(method, url);
    if (contentType) x.setRequestHeader('Content-Type', contentType);
    x.onloadend = () => { if (x.status < 200 || x.status >= 300) failed(x.status ? `-> ${x.status}` : 'failed'); };
    x.send(body);
    return;
  }
  fetch(url, { method, body, ...(contentType ? { headers: { 'Content-Type': contentType } } : {}) })
    .then((r) => { if (!r.ok) failed(`-> ${r.status}`); }, (e: unknown) => failed(errorMessage(e)));
}

export function pageReporting(): Reporting {
  return { client: clientFacts, deps: { send, now: () => Date.now(), random: () => Math.random() } };
}
