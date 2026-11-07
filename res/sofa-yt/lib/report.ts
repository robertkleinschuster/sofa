// A view's reporting as youtube.com's own player does it (docs/youtube-engine.md "Playback
// reporting"): the stats pings of one playback - stats/playback + ptracking when it first plays,
// stats/watchtime on the player response's flush schedule and at pauses, the end and the close
// (pe=1, then final=1), stats/qoe (streamingstats) at start, after ~10 s, every 30 s and at the end.
// Modelled on captures of the real player (2026-11-07, Firefox 153, a fresh profile, IPv4): the
// parameters, their order, the bodies (session_token = the page's XSRF token) and the transports
// (XHR for stats, fetch for qoe and ptracking) are the player's. Sofa reports the player's state
// (state, position, time since the last key press); this module turns it into the pings. Pure:
// time, randomness and the network are injected (tests/sofa-yt/unit-report.test.ts).
//
// Not sent (not reproducible without guessing): stats/atr (a BotGuard attestation whose challenge
// does not come with the player response), qoe's ctmp/vfs/afs details (counters of the player's
// internal state).
import type { PlaybackTracking } from './youtube.ts';

/** What the page knows once (ytcfg, the player script, the InnerTube client context). */
export interface ReportClient {
  cl: string;        // the player script's build (base.js: cl:(N).toString())
  fexp: string;      // the page's experiment ids, encoded as the player sends them (encodeFexp)
  xsrf: string;      // ytcfg XSRF_TOKEN: every POST's body
  hl: string;        // de_DE
  cr: string;        // AT
  cbrand: string; cbr: string; cbrver: string; c: string; cver: string; cos: string; cosver: string; cplatform: string;
  view: { w: number; h: number } | null;   // the player element's size, when the page has one
}

/** One view: the session's playback. */
export interface ViewInfo {
  cpn: string;
  tracking: PlaybackTracking;
  lenS: number;      // the format's duration
  fmt: number;       // video itag
  afmt: number;      // audio itag
}

export type PlayerStateName = 'playing' | 'paused' | 'buffering' | 'ended';

/** What Sofa reports: the player's state now. */
export interface PlayerState {
  state: PlayerStateName;
  position: number;      // media seconds
  lactMs?: number;       // ms since the viewer's last key press (absent: since the view began)
}

/** What a session's media fetching knows (qoe's buffer and bandwidth). */
export interface MediaStats { aheadS: number; bytes: number; seconds: number }

export type Transport = 'xhr' | 'fetch';
export interface ReportDeps {
  send(transport: Transport, method: 'GET' | 'POST', url: string, body: string | null, contentType: string | null): void;
  now(): number;          // ms
  random(): number;       // [0, 1)
  media(): MediaStats;
}

const HOST = 'https://www.youtube.com';
const FORM = 'application/x-www-form-urlencoded';
// the player's flush slots are walltimes of its page (videostatsScheduledFlushWalltimeSeconds, then
// every videostatsDefaultFlushIntervalSeconds); measured from the player's start they came ~2 s
// earlier (slots 8, 18, 28 for 10, 20, 30)
const SLOT_OFFSET_S = 2;
const DEFAULT_SLOTS = [10, 20, 30];
const DEFAULT_INTERVAL_S = 40;
const QOE_FIRST_S = 1.2;      // seq 1: shortly after the player starts (before it plays)
const QOE_SECOND_S = 10;      // seq 2, then every 30 s
const QOE_INTERVAL_S = 30;
const SEEK_SLACK_S = 1.5;     // a position this far off the extrapolated one is a seek

/** The page's serializedExperimentIds as the player's fexp: "v1", ids >= 1e8 first, deltas. */
export function encodeFexp(serialized: string): string {
  const ids = serialized.split(',').map((s) => Number(s.trim())).filter((n) => Number.isInteger(n) && n > 0);
  const ordered = [...ids.filter((n) => n >= 1e8), ...ids.filter((n) => n < 1e8)];
  return ['v1', ...ordered.map((n, i) => String(i === 0 ? n : n - ordered[i - 1]!))].join(',');
}

/** The player script's build number (base.js), '' when it has none. */
export function playerBuild(source: string): string {
  return /\bcl[:=]\((\d{6,})\)\.toString\(\)/.exec(source)?.[1] ?? '';
}

/** Seconds as the stats pings write them: up to 3 decimals, no trailing zeros. */
export function secs(s: number): string { return String(Number(Math.max(0, s).toFixed(3))); }
const fixed3 = (s: number): string => Math.max(0, s).toFixed(3);

/** One query in the player's order; `null` = left out, '' = a bare key (euri). */
function query(pairs: [string, string | number | null][]): string {
  return pairs.filter(([, v]) => v !== null).map(([k, v]) => (v === '' ? k : `${k}=${encodeURIComponent(String(v))}`)).join('&');
}

function base(url: string | undefined): { path: string; params: URLSearchParams } | null {
  if (!url) return null;
  try { const u = new URL(url); return { path: u.pathname, params: u.searchParams }; } catch { return null; }
}

/** qoe's protobuf of {1: cpn, 2: seq}, base64url without padding. */
export function qclc(cpn: string, seq: number): string {
  const b = [0x0a, cpn.length, ...Array.from(cpn, (c) => c.charCodeAt(0)), 0x10];
  for (let n = seq; ; n >>>= 7) { if (n < 0x80) { b.push(n); break; } b.push((n & 0x7f) | 0x80); }
  return btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

const VPS: Record<PlayerStateName, string> = { playing: 'PL', paused: 'PA', buffering: 'B', ended: 'EN' };

export class ViewReporter {
  private readonly start: number;
  private readonly slots: number[];
  private readonly interval: number;
  private readonly idpj: number;
  private readonly ldpj: number;
  private state: PlayerStateName = 'buffering';
  private pos = 0;                      // at `posAt`
  private posAt: number;
  private lactBase: number;             // when the last key was pressed (ms, our clock)
  private st: number[] = [];            // watchtime segments since the last flush
  private et: number[] = [];
  private segStart: number | null = null;
  private played = false;               // stats/playback sent
  private slot = 0;                     // index of the next flush slot
  private qoeSeq = 0;
  private qoeNext: number;
  private qoeLog: { cmt: string[]; vps: string[]; bh: string[] } = { cmt: [], vps: [], bh: [] };
  private closed = false;
  private readonly view: ViewInfo;
  private readonly client: ReportClient;
  private readonly deps: ReportDeps;

  constructor(view: ViewInfo, client: ReportClient, deps: ReportDeps) {
    this.view = view; this.client = client; this.deps = deps;
    this.start = deps.now();
    this.posAt = this.start;
    this.lactBase = this.start;
    const t = view.tracking;
    this.slots = (t.flushSlots?.length ? t.flushSlots : DEFAULT_SLOTS).map((w) => w - SLOT_OFFSET_S).filter((s) => s > 0);
    this.interval = t.flushInterval && t.flushInterval > 0 ? t.flushInterval : DEFAULT_INTERVAL_S;
    // per view constants of the watchtime pings (observed -9..-1 and -40..-1)
    this.idpj = -1 - Math.floor(deps.random() * 9);
    this.ldpj = -1 - Math.floor(deps.random() * 40);
    this.qoeNext = QOE_FIRST_S;
    this.qoeLog.vps.push(`${fixed3(0)}:N`);
  }

  /** Seconds since the view began (the pings' rt). */
  private rt(): number { return (this.deps.now() - this.start) / 1000; }
  /** The position now: extrapolated while playing. */
  private cmt(): number {
    const p = this.state === 'playing' ? this.pos + (this.deps.now() - this.posAt) / 1000 : this.pos;
    return Math.min(p, this.view.lenS || p);
  }
  private slotAt(i: number): number {
    if (i < this.slots.length) return this.slots[i]!;
    const last = this.slots.length ? this.slots[this.slots.length - 1]! : 0;
    let s = this.interval - SLOT_OFFSET_S;
    while (s <= last) s += this.interval;
    return s + (i - this.slots.length) * this.interval;
  }

  /** Sofa's report of the player's state. */
  update(s: PlayerState): void {
    if (this.closed) return;
    const now = this.deps.now();
    if (typeof s.lactMs === 'number' && s.lactMs >= 0) this.lactBase = now - s.lactMs;
    const expected = this.cmt();
    const was = this.state;
    const seek = Math.abs(s.position - expected) > SEEK_SLACK_S;
    // a rebuffer keeps the segment open (the position stands still meanwhile); a pause, the end or a
    // seek closes it
    if (this.segStart !== null && (seek || s.state === 'paused' || s.state === 'ended')) this.endSegment(seek ? expected : s.position);
    this.pos = s.position;
    this.posAt = now;
    this.state = s.state;
    if (was !== s.state || seek) this.qoeEvent();
    if (s.state === 'playing' || (s.state === 'buffering' && this.segStart !== null)) {
      if (this.segStart === null) this.segStart = s.position;
      if (!this.played && s.state === 'playing') this.firstPlay();
    }
    if (this.played && was === 'playing' && (s.state === 'paused' || s.state === 'ended')) {
      this.watchtime({ scheduled: false });
      if (s.state === 'ended') this.qoe();
    }
    this.tick();
  }

  /** Time passes (the engine calls this every 250 ms while there is a view). */
  tick(): void {
    if (this.closed) return;
    const rt = this.rt();
    if (rt >= this.qoeNext) {
      this.qoe();
      this.qoeNext = this.qoeSeq < 2 ? QOE_SECOND_S : this.qoeNext + QOE_INTERVAL_S;
      while (this.qoeNext <= rt) this.qoeNext += QOE_INTERVAL_S;
    }
    if (this.played && rt >= this.slotAt(this.slot)) {
      // a slot while nothing played since the last ping passes silently
      if (this.state === 'playing' || this.st.length) this.watchtime({ scheduled: true });
      else this.slot++;
    }
  }

  /** The player left this view (closed, another video): pe=1, then final=1. */
  close(): void {
    if (this.closed) return;
    if (this.played) {
      if (this.segStart !== null) this.endSegment(this.cmt());
      const p = this.cmt();
      if (!this.st.length) { this.st.push(p); this.et.push(p); }
      this.watchtime({ scheduled: false, pe: true });
      this.qoeLog.vps.push(`${fixed3(this.rt())}:N`, `${fixed3(this.rt())}:SU`);
      this.qoeLog.bh.push(`${fixed3(this.rt())}:0.000`);
      this.qoe({ closing: true });
      this.st.push(p); this.et.push(p);
      this.watchtime({ scheduled: false, pe: true, final: true });
    }
    this.closed = true;
  }

  get isClosed(): boolean { return this.closed; }

  private endSegment(at: number): void {
    if (this.segStart === null) return;
    this.st.push(this.segStart);
    this.et.push(Math.max(this.segStart, at));
    this.segStart = null;
  }

  private qoeEvent(): void {
    const t = fixed3(this.rt());
    this.qoeLog.cmt.push(`${t}:${fixed3(this.cmt())}`);
    this.qoeLog.vps.push(`${t}:${VPS[this.state]}`);
  }

  private lact(): number { return Math.max(0, Math.round(this.deps.now() - this.lactBase)); }

  /** The parameters every stats ping starts with (the player's order). */
  private head(): [string, string | number | null][] {
    const b = base(this.view.tracking.playback);
    return [['ns', b?.params.get('ns') ?? 'yt'], ['el', b?.params.get('el') ?? 'detailpage'], ['cpn', this.view.cpn], ['ver', 2],
      ['cmt', secs(this.cmt())], ['fmt', this.view.fmt], ['fs', 0], ['rt', secs(this.rt())], ['euri', ''], ['lact', this.lact()], ['cl', this.client.cl]];
  }
  private clientParams(final = false): [string, string | number | null][] {
    const c = this.client;
    return [['cbrand', c.cbrand], ['cbr', c.cbr], ['cbrver', c.cbrver], ['c', c.c], ['cver', c.cver], ['cplayer', 'UNIPLAYER'],
      ['cos', c.cos], ['cosver', c.cosver], ['cplatform', c.cplatform], ['final', final ? 1 : null], ['hl', c.hl], ['cr', c.cr]];
  }
  /** The base URL's own parameters the player did not set itself, in the base's order (empty ones -
   * the base's `fexp=` - left out, as the player's watchtime pings do). */
  private rest(url: string | undefined, set: [string, unknown][]): [string, string][] {
    const b = base(url);
    if (!b) return [];
    const have = new Set(set.map(([k]) => k));
    return [...b.params].filter(([k, v]) => !have.has(k) && v !== '');
  }
  private post(url: string | undefined, transport: Transport, contentType: string | null, pairs: [string, string | number | null][], extraBody = ''): void {
    const b = base(url);
    if (!b) return;
    const all = [...pairs, ...this.rest(url, pairs)];
    const body = `${extraBody}session_token=${encodeURIComponent(this.client.xsrf)}`;
    this.deps.send(transport, 'POST', `${HOST}${b.path}?${query(all)}`, body, contentType);
  }

  private firstPlay(): void {
    this.played = true;
    const v = this.view;
    this.post(v.tracking.playback, 'xhr', FORM, [...this.head(), ['mos', 0], ['volume', 100], ...this.clientParams(),
      ['len', secs(v.lenS)], ['fexp', this.client.fexp], ['rtn', Math.floor(this.slotAt(this.slot))], ['afmt', v.afmt], ['muted', 0]]);
    const p = base(v.tracking.ptracking);
    if (p) {
      const g = (k: string) => p.params.get(k);
      this.deps.send('fetch', 'GET', `${HOST}${p.path}?${query([['html5', 1], ['video_id', g('video_id')], ['cpn', v.cpn], ['ei', g('ei')],
        ['ptk', g('ptk')], ['oid', g('oid')], ['ptchn', g('ptchn')], ['pltype', g('pltype')]])}`, null, null);
    }
  }

  private watchtime({ scheduled, pe = false, final = false }: { scheduled: boolean; pe?: boolean; final?: boolean }): void {
    if (this.segStart !== null) {   // the running segment up to now, continued after the ping
      const p = this.cmt();
      this.st.push(this.segStart); this.et.push(p);
      this.segStart = p;
    }
    if (!this.st.length) { const p = this.cmt(); this.st.push(p); this.et.push(p); }
    const v = this.view;
    const playing = this.state === 'playing' || this.state === 'buffering';
    const slot = Math.floor(this.slotAt(this.slot));
    if (!pe) this.slot++;                         // a pause / end ping takes the pending slot
    const pairs: [string, string | number | null][] = [...this.head(), ['state', playing ? 'playing' : 'paused'], ['volume', 100],
      ...this.clientParams(final), ['len', secs(v.lenS)], ['rtn', scheduled ? Math.floor(this.slotAt(this.slot)) : null], ['afmt', v.afmt],
      ['idpj', this.idpj], ['ldpj', this.ldpj], ['rti', pe ? null : slot],
      ['st', this.st.map(secs).join(',')], ['et', this.et.map(secs).join(',')], ['pe', pe ? 1 : null], ['muted', 0]];
    this.st = []; this.et = [];
    this.post(v.tracking.watchtime, 'xhr', FORM, pairs);
  }

  private qoe({ closing = false }: { closing?: boolean } = {}): void {
    const v = this.view;
    const b = base(v.tracking.qoe);
    if (!b) return;
    this.qoeSeq++;
    const t = fixed3(this.rt());
    const m = this.deps.media();
    const log = this.qoeLog;
    log.cmt.push(`${t}:${fixed3(this.cmt())}`);
    // the state at this ping, unless the closing N/SU or the same state at this very moment is already there
    if (!closing && log.vps[log.vps.length - 1] !== `${t}:${VPS[this.state]}`) log.vps.push(`${t}:${VPS[this.state]}`);
    log.bh.push(`${t}:${fixed3(m.aheadS)}`);
    const first = this.qoeSeq === 1;
    const bps = m.seconds > 0 ? Math.round((m.bytes * 8) / m.seconds) : 0;
    const g = (k: string) => b.params.get(k);
    const pairs: [string, string | number | null][] = [['fmt', v.fmt], ['afmt', first ? null : v.afmt], ['cpn', v.cpn], ['el', g('el')], ['ns', g('ns')],
      ['fexp', this.client.fexp], ['cl', this.client.cl], ['dai', 'unspecified'], ['seq', this.qoeSeq], ['docid', g('docid')], ['ei', g('ei')],
      ['event', g('event') ?? 'streamingstats'], ['plid', g('plid')],
      ...this.clientParams().filter(([k]) => k !== 'final' && k !== 'hl' && k !== 'cr'),
      ['vps', log.vps.join(',')], ['cat', first ? 'streaming,sabr' : null], ['cmt', log.cmt.join(',')],
      ['view', first && this.client.view ? `${t}:${this.client.view.w}:${this.client.view.h}` : null],
      ['bwm', m.seconds > 0 ? `${t}:${m.bytes}:${fixed3(m.seconds)}` : null], ['bwe', bps ? `${t}:${bps}` : null],
      ['vis', first ? `${t}:0` : null], ['bh', log.bh.join(',')], ['df', first ? null : `${t}:0`], ['qclc', qclc(v.cpn, this.qoeSeq)]];
    this.qoeLog = { cmt: [], vps: [], bh: [] };
    this.deps.send('fetch', 'POST', `${HOST}${b.path}?${query(pairs)}`, `session_token=${encodeURIComponent(this.client.xsrf)}`, null);
  }
}
