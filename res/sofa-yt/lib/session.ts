// Playback session: the tracks of one opened video as sparse virtual files, fed by SABR pumps that
// follow the consumer (mpv) instead of downloading the whole file.
//
// Demands: every open HTTP response on a track is a demand at its current byte position; a closed one
// lingers briefly (mpv reconnects); /open may add a time "hint" (resume position) so media is
// prefetched before mpv connects.
// Scheduling (schedule(), run on every segment, read progress and a 1 s tick):
//   - a demand whose position is not buffered and not covered by a running pump starts a pump at the
//     demand's media time (seek = new SABR run at that playerTimeMs; no player request);
//   - a buffered demand starts a pump at the end of its contiguous run once less than LOW_MS is
//     buffered ahead, and stops being a reason to keep a pump running at HIGH_MS ahead (pacing);
//   - pumps that no demand needs for GRACE_MS are aborted.
// Video pumps carry the audio track read most recently (SABR has no video-only mode); other audio
// tracks (language switch) get audio-only pumps. Memory: media more than KEEP_BEHIND_MS behind every
// demand is evicted, plus a byte cap per track; init segment + index are always kept.
import { randomHex } from './bytes.ts';
import { background } from './timers.ts';
import { VirtualFile } from './vfile.ts';
import type { Segment } from './vfile.ts';
import { errorMessage, toError } from './errors.ts';
import { log, debug } from './log.ts';
import type { AudioTrackChoice, DescribedFormat, SubtitleTrack } from './formats.ts';
import type { VodInfo } from './youtube.ts';

export type TrackKind = 'video' | 'audio';

/** Media pulled from YouTube per track kind (video seconds as ms, bytes). */
export type MediaCounters = Record<TrackKind, { ms: number; bytes: number }>;

export interface SessionConfig {
  LOW_MS: number;
  HIGH_MS: number;
  HIGH_BYTES: Record<TrackKind, number>;
  MAX_BYTES: Record<TrackKind, number>;
  KEEP_BEHIND_MS: number;
  COVER_SLACK_MS: number;
  GRACE_MS: number;
  STALL_MS: number;
  LINGER_MS: number;
  HINT_TTL_MS: number;
  WAIT_MS: number;
  MAX_PUMPS: number;
  START_BURST: number;
  START_WINDOW_MS: number;
  MAX_FAILURES: number;
  TICK_MS: number;
  CHUNK: number;
}

export type PumpEnd = 'finished' | 'aborted' | 'error';

/** What a session asks of its pump factory (sabrpump.startSabrPump or a test fake). */
export interface PumpRequest {
  video: DescribedFormat | null;     // null: audio only
  audio: DescribedFormat;
  startMs: number;
  onSegment: (kind: TrackKind, seg: Required<Segment>) => void;
  onEnd: (err: Error | null, how: PumpEnd) => void;
}

export interface PumpHandle {
  abort(): void;
  /** What the source last said about this run, for stall reports (e.g. SABR's protection status, backoff). */
  diag?(): string;
}

export type StartPump = (o: PumpRequest) => PumpHandle;

/** An open HTTP response on a track (its current byte position). */
export interface Reader {
  pos: number;
  since?: number;
}

/** A reason to have media: a byte position (reader) or only a time (hint, off null). */
export interface Demand {
  off: number | null;
  ms: number;
  linger?: boolean;
}

/** How much is buffered from a demand on (Infinity: init region / end of file). */
export interface Satisfied {
  aheadMs: number;
  aheadBytes: number;
  endMs: number;
  toEof: boolean;
}

/** The part of a node http.ServerResponse serve() uses (tests pass a fake). */
export interface ServeTarget {
  write(chunk: Uint8Array): boolean;
  on(event: 'close' | 'drain', listener: () => void): unknown;
  off(event: 'close' | 'drain', listener: () => void): unknown;
}

export interface TrackStatus {
  itag: number;
  bytes: number;
  segments: number;
  readers: number;
  demands: { off: number | null; ms: number; ahead: number }[];
  indexed: boolean;
}

export interface SessionStatus {
  sid: string;
  id: string;
  failed: string | null;
  /** diag: what SABR's server last said (stream protection, backoff; PumpHandle.diag) */
  pumps: { startMs: number; video: string | null; audio: string; delivered: number; frontier: Record<string, number>; diag: string | null }[];
  tracks: Record<string, TrackStatus>;
  fetched: MediaCounters;
  sabrRuns: number | undefined;
  idleMs: number;
}

export const DEFAULTS: SessionConfig = {
  LOW_MS: 30000,             // resume pulling below this much buffered ahead
  HIGH_MS: 90000,            // pause pulling above this much buffered ahead
  HIGH_BYTES: { video: 96 << 20, audio: 12 << 20 },  // ...or above this many bytes ahead
  MAX_BYTES: { video: 160 << 20, audio: 24 << 20 },  // hard cap per track (eviction)
  KEEP_BEHIND_MS: 30000,     // keep this much behind the read position (mpv seeks back a little)
  COVER_SLACK_MS: 20000,     // a pump this close behind a demand will reach it -> wait for it
  GRACE_MS: 1000,            // abort pumps nobody needed for this long (SABR answers in bursts: keep short)
  STALL_MS: 20000,           // a needed run that delivered nothing for this long is restarted
  LINGER_MS: 20000,          // a closed response stays a demand this long (reconnects)
  HINT_TTL_MS: 60000,        // an unconsumed /open start hint expires
  WAIT_MS: 25000,            // a response waits this long for missing bytes, then ends (mpv reconnects)
  MAX_PUMPS: 3,              // concurrent SABR runs per session
  START_BURST: 12,           // pump starts allowed per START_WINDOW_MS (guards seek storms / bugs)
  START_WINDOW_MS: 60000,
  MAX_FAILURES: 3,           // consecutive pumps that failed before delivering anything -> session failed
  TICK_MS: 1000,
  CHUNK: 256 << 10,          // HTTP write size
};

class Track {
  session: PlaybackSession;
  kind: TrackKind;
  fmt: DescribedFormat;
  key: string;
  file: VirtualFile;
  readers: Set<Reader>;
  lastPos: number | null;
  lastReadAt: number;
  hint: { ms: number; until: number } | null;

  constructor(session: PlaybackSession, kind: TrackKind, fmt: DescribedFormat) {
    this.session = session;
    this.kind = kind;
    this.fmt = fmt;
    this.key = kind === 'video' ? 'video' : fmt.key;
    this.file = new VirtualFile({ total: fmt.contentLength, durationMs: fmt.durationMs || session.info.durationMs, mimeType: fmt.mimeType });
    this.readers = new Set(); // {pos, since, last}
    this.lastPos = null;
    this.lastReadAt = 0;
    this.hint = null;         // {ms, until}
  }

  /** Current demands: [{off|null, ms}] */
  demands(now: number): Demand[] {
    const out: Demand[] = [];
    for (const r of this.readers) out.push({ off: r.pos, ms: this.file.timeAt(r.pos) });
    if (!this.readers.size && this.lastPos !== null && now - this.lastReadAt < this.session.cfg.LINGER_MS) {
      // between two requests (seek, reconnect): only protects the buffer from eviction
      out.push({ off: this.lastPos, ms: this.file.timeAt(this.lastPos), linger: true });
    }
    if (this.hint) {
      // consumed once a reader reads media at (or just after) the hinted position; a reader at 0
      // (mpv probing the first cluster before it seeks to the resume position) does not consume it
      const hint = this.hint;
      const consumed = out.some((d) => d.off !== null && d.off >= this.initEnd && d.ms >= hint.ms - 2000 && d.ms <= hint.ms + 15000);
      if (consumed || now > this.hint.until) this.hint = null;
      else out.push({ off: null, ms: this.hint.ms });
    }
    return out;
  }

  /** End of the init region (header + index) - known from the format before any data arrived. */
  get initEnd(): number {
    if (this.file.initEnd) return this.file.initEnd;
    const ir = this.fmt.raw?.indexRange;
    return ir ? Number(ir.end) + 1 : 0;
  }

  /**
   * Is the demand's position buffered? -> {aheadMs, aheadBytes, endMs, toEof} (Infinity ahead for
   * the init region and the end of the file), or null.
   */
  satisfied(d: Demand): Satisfied | null {
    const f = this.file;
    if (d.off !== null) {
      if (d.off >= f.total) return { aheadMs: Infinity, aheadBytes: Infinity, endMs: f.durationMs, toEof: true };
      const e = f.entryAt(d.off);
      if (!e) return null;
      if (e.init) return { aheadMs: Infinity, aheadBytes: Infinity, endMs: 0, toEof: false };
      const c = f.contiguousFrom(d.off);
      if (!c) return null;   // not reached: d.off is inside entry e
      return { aheadMs: c.toEof ? Infinity : c.endMs - d.ms, aheadBytes: c.toEof ? Infinity : c.end - d.off, endMs: c.endMs, toEof: c.toEof };
    }
    if (!f.init) return null;
    const e = f.entryAtTime(d.ms);
    if (!e) return null;
    const c = f.contiguousFrom(e.start);
    if (!c) return null;   // not reached: e is stored
    return { aheadMs: c.toEof ? Infinity : c.endMs - d.ms, aheadBytes: c.toEof ? Infinity : c.end - e.start, endMs: c.endMs, toEof: c.toEof };
  }
}

class Pump {
  video: Track | null;
  audio: Track;
  startMs: number;
  startedAt: number;
  lastUseful: number;
  lastDataAt: number;
  alive: boolean;
  delivered: number;
  first: Map<Track, number>;
  frontier: Map<Track, number>;
  handle: PumpHandle | null;

  constructor({ video, audio, startMs, now }: { video: Track | null; audio: Track; startMs: number; now: number }) {
    this.video = video;   // Track or null
    this.audio = audio;   // Track
    this.startMs = startMs;
    this.startedAt = now;
    this.lastUseful = now;
    this.lastDataAt = now;
    this.alive = true;
    this.delivered = 0;
    this.first = new Map();    // track -> first segment startMs
    this.frontier = new Map(); // track -> end ms of the newest segment
    this.handle = null;
  }

  get driver(): Track { return this.video || this.audio; }

  feeds(t: Track): boolean { return this.video === t || this.audio === t; }

  covers(t: Track, ms: number, slack: number): boolean {
    if (!this.alive || !this.feeds(t)) return false;
    // SABR delivers from the start of the segment containing startMs: a run started at an estimate
    // (extra language track before its index arrived) covers that whole segment, no second run
    const begin = t.file.segmentStartAt(this.startMs) ?? this.startMs;
    const from = Math.min(begin, this.first.get(t) ?? Infinity) - 1000;
    const to = Math.max(this.startMs, this.frontier.get(t) ?? 0) + slack;
    return ms >= from && ms <= to;
  }
}

export interface PlaybackSessionOptions {
  info: VodInfo;                       // cached player info
  formats: DescribedFormat[];          // described formats
  video: DescribedFormat;              // chosen video format
  audio: DescribedFormat;              // chosen (main) audio format
  audioChoices?: DescribedFormat[];    // formats that may be requested as audio tracks
  subs?: SubtitleTrack[];              // subtitle tracks (formats.subtitleTracks)
  startPump: StartPump;                // pump factory (sabrpump.startSabrPump or a test fake)
  cfg?: Partial<SessionConfig>;
}

export class PlaybackSession {
  readonly kind: 'sabr';
  sid: string;
  info: VodInfo;
  formats: DescribedFormat[];
  cfg: SessionConfig;
  startPumpFn: StartPump;
  video: Track;
  tracks: Map<string, Track>;
  audioFormats: Map<string, DescribedFormat>;
  mainAudioKey: string;
  subs: SubtitleTrack[];
  subCache: Map<string, string>;
  pumps: Set<Pump>;
  fetched: MediaCounters;
  starts: number[];
  failures: number;
  failed: Error | null;
  closed: boolean;
  created: number;
  lastActivity: number;
  scheduled: boolean;
  backoffUntil: number;
  throttleLogged: number;
  timer: ReturnType<typeof setTimeout>;
  // set on first use (absent from status() until then)
  runs?: number;
  reqs?: number;
  everRead?: boolean;
  lastReadAt?: number;
  // the choice this session was opened with (engine.ts: reuse for the same open)
  audioList?: AudioTrackChoice[];
  maxHeight?: number;
  lang?: string;
  vcodec?: string | null;
  acodec?: string | null;

  constructor({ info, formats, video, audio, audioChoices = [], subs = [], startPump, cfg = {} }: PlaybackSessionOptions) {
    this.kind = 'sabr';
    this.sid = randomHex(8);
    this.info = info;
    this.formats = formats;
    this.cfg = { ...DEFAULTS, ...cfg };
    this.startPumpFn = startPump;
    this.video = new Track(this, 'video', video);
    this.tracks = new Map([['video', this.video]]);
    this.audioFormats = new Map();
    for (const f of [audio, ...audioChoices]) this.audioFormats.set(f.key, f);
    this.mainAudioKey = audio.key;
    this.subs = subs;
    this.subCache = new Map();
    this.pumps = new Set();
    this.fetched = { video: { ms: 0, bytes: 0 }, audio: { ms: 0, bytes: 0 } }; // media pulled from YouTube
    this.starts = [];
    this.failures = 0;
    this.failed = null;
    this.closed = false;
    this.created = Date.now();
    this.lastActivity = Date.now();
    this.scheduled = false;
    this.backoffUntil = 0;
    this.throttleLogged = 0;
    this.timer = background(setInterval(() => this.schedule(), this.cfg.TICK_MS));
  }

  /** Track for a URL key ('video' or an audio format key); audio tracks are created on demand. */
  track(key: string): Track | null {
    const have = this.tracks.get(key);
    if (have) return have;
    const f = this.audioFormats.get(key);
    if (!f) return null;
    const t = new Track(this, 'audio', f);
    this.tracks.set(key, t);
    return t;
  }

  get mainAudio(): Track {
    const t = this.track(this.mainAudioKey);
    if (!t) throw new Error(`main audio track ${this.mainAudioKey} missing`); // the constructor registered it
    return t;
  }

  /** The audio track most recently read (video pumps carry it), default the main one. */
  activeAudio(): Track {
    let best: Track | null = null;
    for (const t of this.tracks.values()) {
      if (t.kind === 'audio' && (t.readers.size || t.lastReadAt) && (!best || t.lastReadAt > best.lastReadAt)) best = t;
    }
    return best || this.mainAudio;
  }

  /** Prefetch from `ms` (resume position) before mpv connects. */
  hint(ms: number): void {
    const until = Date.now() + this.cfg.HINT_TTL_MS;
    this.video.hint = { ms, until };
    this.mainAudio.hint = { ms, until };
    this.schedule();
  }

  // ---- scheduling ---------------------------------------------------------------------------

  /** Coalesce bursts of triggers into one pass. */
  poke(): void {
    if (this.scheduled || this.closed) return;
    this.scheduled = true;
    setTimeout(() => { this.scheduled = false; this.schedule(); }, 0);   // next turn of the event loop (node and browser)
  }

  schedule(): void {
    if (this.closed) return;
    const now = Date.now();
    const cfg = this.cfg;
    const useful = new Set<Pump>();
    const paced = new Set<Pump>();
    for (const t of this.tracks.values()) {
      for (const d of t.demands(now)) {
        if (d.linger) continue;
        if (d.off !== null && d.off < t.initEnd) {
          // reading the header/index: every SABR run starts with the init segment
          if (t.file.init) continue;
          const feeder = [...this.pumps].find((x) => x.alive && x.feeds(t));
          if (feeder) { if (feeder.driver === t) useful.add(feeder); continue; }
          if (this.failed) continue;
          const np = this.startPump(t, t.hint ? t.hint.ms : 0, now);
          if (np) useful.add(np);
          continue;
        }
        const sat = t.satisfied(d);
        if (sat && sat.aheadMs === Infinity) continue;
        const target = sat ? sat.endMs : d.ms;
        const p = [...this.pumps].find((x) => x.covers(t, target, cfg.COVER_SLACK_MS));
        const enough = sat && (sat.aheadMs >= cfg.HIGH_MS || sat.aheadBytes >= cfg.HIGH_BYTES[t.kind]);
        if (p) {
          // video pumps are kept alive by video demands only (audio is read in sync anyway)
          if (p.driver === t) (enough ? paced : useful).add(p);
          continue;
        }
        // hysteresis: buffered but no pump -> resume only below LOW_MS (or half the byte cap)
        if (sat && (sat.aheadMs >= cfg.LOW_MS || sat.aheadBytes >= cfg.HIGH_BYTES[t.kind] / 2)) continue;
        if (this.failed) continue;
        const np = this.startPump(t, target, now);
        if (np) useful.add(np);
      }
    }
    for (const p of [...this.pumps]) {
      if (useful.has(p) && now - p.lastDataAt > cfg.STALL_MS) {
        // googlevideo would only give up after 30 s request timeouts x retries
        this.stopPump(p, `stalled: no data for ${Math.round((now - p.lastDataAt) / 1000)} s`);
        if (!p.delivered) this.noteFailure(new Error('SABR stalled'));
      } else if (useful.has(p)) p.lastUseful = now;
      else if (paced.has(p)) this.stopPump(p, 'paced: enough buffered ahead');
      else if (now - p.lastUseful > cfg.GRACE_MS) this.stopPump(p, 'not needed');
    }
    this.evict(now);
  }

  startPump(t: Track, ms: number, now: number): Pump | null {
    const cfg = this.cfg;
    if (now < this.backoffUntil) return null;
    this.starts = this.starts.filter((s) => now - s < cfg.START_WINDOW_MS);
    if (this.starts.length >= cfg.START_BURST) {
      if (now - this.throttleLogged > 10000) { log(`${this.tag}: pump starts throttled (${this.starts.length} in ${cfg.START_WINDOW_MS / 1000} s)`); this.throttleLogged = now; }
      return null;
    }
    const video = t.kind === 'video' ? t : null;
    const audio = t.kind === 'video' ? this.activeAudio() : t;
    // one feeder per track: a new run for the same driver replaces older ones once they are useless
    while (this.pumps.size >= cfg.MAX_PUMPS) {
      const oldest = [...this.pumps].sort((a, b) => a.lastUseful - b.lastUseful)[0]!;
      this.stopPump(oldest, 'pump limit');
    }
    this.starts.push(now);
    this.runs = (this.runs || 0) + 1;
    const p = new Pump({ video, audio, startMs: Math.max(0, Math.floor(ms)), now });
    this.pumps.add(p);
    debug(`${this.tag}: start ${video ? 'video+' : 'audio-only '}${audio.key} at ${(p.startMs / 1000).toFixed(1)}s`);
    try {
      p.handle = this.startPumpFn({
        video: video ? video.fmt : null,
        audio: audio.fmt,
        startMs: p.startMs,
        onSegment: (kind, seg) => this.onSegment(p, kind === 'video' ? video : audio, seg),
        onEnd: (err, how) => this.onPumpEnd(p, err, how),
      });
    } catch (e) {
      this.onPumpEnd(p, toError(e), 'error');
      return null;
    }
    return p;
  }

  stopPump(p: Pump, why: string): void {
    if (!p.alive) return;
    debug(`${this.tag}: stop pump @${(p.startMs / 1000).toFixed(1)}s (${why})`);
    p.alive = false;
    this.pumps.delete(p);
    try { p.handle?.abort(); } catch { /* already gone */ }
  }

  onSegment(p: Pump, t: Track | null, seg: Required<Segment>): void {
    if (this.closed || !t) return;
    p.lastDataAt = Date.now();
    const r = t.file.add(seg);
    debug(`${this.tag}: seg ${t.key} ${seg.init ? 'init' : `${seg.startMs}+${seg.durationMs}ms`} @${seg.start}+${seg.buf.length} ${r}`);
    if (!seg.init) { this.fetched[t.kind].ms += seg.durationMs; this.fetched[t.kind].bytes += seg.buf.length; }
    if (r === 'overlap') log(`${this.tag}: ${t.key}: dropped inconsistent segment at ${seg.start} (+${seg.buf.length})`);
    if (!seg.init) {
      p.delivered++;
      if (!p.first.has(t)) p.first.set(t, seg.startMs);
      p.frontier.set(t, Math.max(p.frontier.get(t) ?? 0, seg.startMs + seg.durationMs));
      this.failures = 0;
    }
    this.poke();
  }

  onPumpEnd(p: Pump, err: Error | null, how: PumpEnd): void {
    const wasAlive = p.alive;
    p.alive = false;
    this.pumps.delete(p);
    if (this.closed) return;
    if (how === 'error') {
      log(`${this.tag}: SABR run @${(p.startMs / 1000).toFixed(1)}s failed: ${err?.message}`);
      if (!p.delivered) this.noteFailure(err || new Error('SABR failed'));
    } else if (wasAlive) {
      debug(`${this.tag}: SABR run @${(p.startMs / 1000).toFixed(1)}s ${how}`);
    }
    this.poke();
  }

  /** A run ended without delivering media: back off, give up after MAX_FAILURES in a row. */
  noteFailure(err: Error): void {
    this.failures++;
    this.backoffUntil = Date.now() + Math.min(8000, 500 * 2 ** this.failures);
    if (this.failures >= this.cfg.MAX_FAILURES) this.fail(err);
  }

  fail(err: Error): void {
    if (this.failed) return;
    this.failed = err;
    log(`${this.tag}: giving up after ${this.failures} failed SABR runs: ${err.message}`);
    for (const p of [...this.pumps]) this.stopPump(p, 'session failed');
    for (const t of this.tracks.values()) t.file.setFailed(err);
  }

  evict(now: number): void {
    for (const t of this.tracks.values()) {
      const ds = t.demands(now);
      const keepFromMs = ds.length ? Math.min(...ds.map((d) => d.ms)) - this.cfg.KEEP_BEHIND_MS : Infinity;
      const readOff = ds[0]?.off ?? 0;
      const freed = t.file.evict({ keepFromMs, readOff, maxBytes: this.cfg.MAX_BYTES[t.kind] });
      if (freed) debug(`${this.tag}: ${t.key}: evicted ${(freed / 1048576).toFixed(1)} MB, holding ${(t.file.bytes / 1048576).toFixed(1)} MB`);
    }
  }

  /**
   * Why nothing feeds a waiting reader, in one line (the stall log): the session's pumps (start,
   * tracks, segments delivered, frontier, idle time), the track's demands with what is buffered
   * ahead of them, and what holds back new pumps (backoff, start throttle, failures).
   */
  stallState(t: Track, now: number): string {
    const sec = (ms: number) => (ms / 1000).toFixed(1);
    const pumps = [...this.pumps].map((p) => {
      const fr = [...p.frontier].map(([tr, ms]) => `${tr.key}@${sec(ms)}`).join('/') || '-';
      const said = p.handle?.diag?.();
      return `@${sec(p.startMs)} ${p.video ? 'video+' : ''}${p.audio.key} seg=${p.delivered} to=${fr} idle=${sec(now - p.lastDataAt)}s${said ? ` ${said}` : ''}`;
    });
    const demands = t.demands(now).map((d) => {
      const sat = t.satisfied(d);
      return `${d.off ?? 'hint'}@${sec(d.ms)}${d.linger ? ' linger' : ''} ${sat ? `ahead=${sat.aheadMs === Infinity ? 'eof/init' : sec(sat.aheadMs)}` : 'missing'}`;
    });
    const recent = this.starts.filter((x) => now - x < this.cfg.START_WINDOW_MS).length;
    return `pumps: ${pumps.join('; ') || 'none'} | demands: ${demands.join('; ') || 'none'} | runs=${this.runs ?? 0} recent=${recent}`
      + `${now < this.backoffUntil ? ` backoff=${sec(this.backoffUntil - now)}s` : ''} failures=${this.failures}${this.failed ? ' FAILED' : ''}`;
  }

  get tag(): string { return `session ${this.sid.slice(0, 6)} ${this.info.id}`; }

  get bytes(): number { let n = 0; for (const t of this.tracks.values()) n += t.file.bytes; return n; }

  get activeReaders(): number { let n = 0; for (const t of this.tracks.values()) n += t.readers.size; return n; }

  // ---- serving ----------------------------------------------------------------------------

  /**
   * Stream [start, end) of track `t` into `res` (node http.ServerResponse or compatible), waiting for
   * missing bytes up to WAIT_MS each time. Returns the number of bytes written.
   */
  async serve(t: Track, start: number, end: number, res: ServeTarget): Promise<number> {
    const reader: Reader = { pos: start, since: Date.now() };
    t.readers.add(reader);
    t.lastPos = start;
    t.lastReadAt = Date.now();
    this.lastActivity = Date.now();
    this.everRead = true;          // eviction: sessions that were never read are preloads
    this.lastReadAt = Date.now();
    const ac = new AbortController();
    const onClose = () => ac.abort();
    res.on('close', onClose);
    let written = 0;
    let why = 'done';
    const rid = (this.reqs = (this.reqs || 0) + 1);
    debug(`${this.tag}: req#${rid} ${t.key} bytes=${start}-${end - 1} (t=${(t.file.timeAt(start) / 1000).toFixed(1)}s, buffered=${!!t.file.entryAt(start)})`);
    this.poke();
    try {
      while (reader.pos < end && !ac.signal.aborted && !this.closed) {
        let piece = t.file.sliceAt(reader.pos, Math.min(end, reader.pos + this.cfg.CHUNK));
        if (!piece) {
          this.schedule();
          try {
            await t.file.waitFor(reader.pos, this.cfg.WAIT_MS, ac.signal);
          } catch (e) {
            why = errorMessage(e);
            if (why === 'timeout') log(`${this.tag}: ${t.key}: no data at ${reader.pos} within ${this.cfg.WAIT_MS / 1000} s - ending response (${this.stallState(t, Date.now())})`);
            break;
          }
          continue;
        }
        piece = new Uint8Array(piece); // copy: the entry may be evicted while the socket holds it
        reader.pos += piece.length;
        written += piece.length;
        t.lastPos = reader.pos;
        t.lastReadAt = Date.now();
        this.lastActivity = t.lastReadAt;
        if (!res.write(piece)) {
          this.poke();
          await new Promise<void>((resolve) => {
            const fin = () => { res.off('drain', fin); ac.signal.removeEventListener('abort', fin); resolve(); };
            res.on('drain', fin);
            ac.signal.addEventListener('abort', fin);
          });
        }
        if (t.file.entryAt(reader.pos - 1) !== t.file.entryAt(reader.pos)) this.poke(); // crossed a segment
      }
    } finally {
      if (ac.signal.aborted) why = 'client closed';
      debug(`${this.tag}: req#${rid} ${t.key} end at ${reader.pos} (${written} bytes, ${why})`);
      res.off('close', onClose);
      t.readers.delete(reader);
      t.lastReadAt = Date.now();
      this.poke();
    }
    return written;
  }

  close(why = 'closed'): void {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.timer);
    for (const p of [...this.pumps]) { p.alive = false; try { p.handle?.abort(); } catch { /* gone */ } }
    this.pumps.clear();
    for (const t of this.tracks.values()) t.file.clear();
    this.subCache.clear();
    log(`${this.tag}: closed (${why})`);
  }

  status(): SessionStatus {
    const now = Date.now();
    const tracks: Record<string, TrackStatus> = {};
    for (const [k, t] of this.tracks) {
      const ds = t.demands(now);
      tracks[k] = {
        itag: t.fmt.itag, bytes: t.file.bytes, segments: t.file.entries.length, readers: t.readers.size,
        demands: ds.map((d) => ({ off: d.off, ms: d.ms, ahead: (t.satisfied(d) || {}).aheadMs ?? 0 })),
        indexed: !!t.file.index,
      };
    }
    return {
      sid: this.sid, id: this.info.id, failed: this.failed?.message || null, pumps: [...this.pumps].map((p) => ({
        startMs: p.startMs, video: p.video?.key || null, audio: p.audio.key, delivered: p.delivered,
        frontier: Object.fromEntries([...p.frontier].map(([t, ms]) => [t.key, ms])), diag: p.handle?.diag?.() ?? null })),
      tracks, fetched: this.fetched, sabrRuns: this.runs, idleMs: now - this.lastActivity,
    };
  }
}
