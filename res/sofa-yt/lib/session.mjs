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
import crypto from 'node:crypto';
import { VirtualFile } from './vfile.mjs';
import { log, debug } from './log.mjs';

export const DEFAULTS = {
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
  constructor(session, kind, fmt) {
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
  demands(now) {
    const out = [];
    for (const r of this.readers) out.push({ off: r.pos, ms: this.file.timeAt(r.pos) });
    if (!this.readers.size && this.lastPos !== null && now - this.lastReadAt < this.session.cfg.LINGER_MS) {
      // between two requests (seek, reconnect): only protects the buffer from eviction
      out.push({ off: this.lastPos, ms: this.file.timeAt(this.lastPos), linger: true });
    }
    if (this.hint) {
      // consumed once a reader reads media at (or just after) the hinted position; a reader at 0
      // (mpv probing the first cluster before it seeks to the resume position) does not consume it
      const consumed = out.some((d) => d.off >= this.initEnd && d.ms >= this.hint.ms - 2000 && d.ms <= this.hint.ms + 15000);
      if (consumed || now > this.hint.until) this.hint = null;
      else out.push({ off: null, ms: this.hint.ms });
    }
    return out;
  }

  /** End of the init region (header + index) - known from the format before any data arrived. */
  get initEnd() {
    if (this.file.initEnd) return this.file.initEnd;
    const ir = this.fmt.raw?.indexRange;
    return ir ? Number(ir.end) + 1 : 0;
  }

  /**
   * Is the demand's position buffered? -> {aheadMs, aheadBytes, endMs, toEof} (Infinity ahead for
   * the init region and the end of the file), or null.
   */
  satisfied(d) {
    const f = this.file;
    if (d.off !== null) {
      if (d.off >= f.total) return { aheadMs: Infinity, aheadBytes: Infinity, endMs: f.durationMs, toEof: true };
      const e = f.entryAt(d.off);
      if (!e) return null;
      if (e.init) return { aheadMs: Infinity, aheadBytes: Infinity, endMs: 0, toEof: false };
      const c = f.contiguousFrom(d.off);
      return { aheadMs: c.toEof ? Infinity : c.endMs - d.ms, aheadBytes: c.toEof ? Infinity : c.end - d.off, endMs: c.endMs, toEof: c.toEof };
    }
    if (!f.init) return null;
    const e = f.entryAtTime(d.ms);
    if (!e) return null;
    const c = f.contiguousFrom(e.start);
    return { aheadMs: c.toEof ? Infinity : c.endMs - d.ms, aheadBytes: c.toEof ? Infinity : c.end - e.start, endMs: c.endMs, toEof: c.toEof };
  }
}

class Pump {
  constructor({ video, audio, startMs, now }) {
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

  get driver() { return this.video || this.audio; }

  feeds(t) { return this.video === t || this.audio === t; }

  covers(t, ms, slack) {
    if (!this.alive || !this.feeds(t)) return false;
    const from = Math.min(this.startMs, this.first.get(t) ?? Infinity) - 1000;
    const to = Math.max(this.startMs, this.frontier.get(t) ?? 0) + slack;
    return ms >= from && ms <= to;
  }
}

export class PlaybackSession {
  /**
   * @param {object} o
   * @param {object} o.info          cached player info
   * @param {object[]} o.formats     described formats
   * @param {object} o.video         chosen video format
   * @param {object} o.audio         chosen (main) audio format
   * @param {object[]} o.audioChoices formats that may be requested as audio tracks
   * @param {object[]} o.subs        subtitle tracks (formats.subtitleTracks)
   * @param {(opts) => {abort}} o.startPump   pump factory (sabrpump.startSabrPump or a test fake)
   * @param {object} [o.cfg]
   */
  constructor({ info, formats, video, audio, audioChoices = [], subs = [], startPump, cfg = {} }) {
    this.sid = crypto.randomBytes(8).toString('hex');
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
    this.timer = setInterval(() => this.schedule(), this.cfg.TICK_MS);
    this.timer.unref?.();
  }

  /** Track for a URL key ('video' or an audio format key); audio tracks are created on demand. */
  track(key) {
    if (this.tracks.has(key)) return this.tracks.get(key);
    const f = this.audioFormats.get(key);
    if (!f) return null;
    const t = new Track(this, 'audio', f);
    this.tracks.set(key, t);
    return t;
  }

  get mainAudio() { return this.track(this.mainAudioKey); }

  /** The audio track most recently read (video pumps carry it), default the main one. */
  activeAudio() {
    let best = null;
    for (const t of this.tracks.values()) {
      if (t.kind === 'audio' && (t.readers.size || t.lastReadAt) && (!best || t.lastReadAt > best.lastReadAt)) best = t;
    }
    return best || this.mainAudio;
  }

  /** Prefetch from `ms` (resume position) before mpv connects. */
  hint(ms) {
    const until = Date.now() + this.cfg.HINT_TTL_MS;
    this.video.hint = { ms, until };
    this.mainAudio.hint = { ms, until };
    this.schedule();
  }

  // ---- scheduling ---------------------------------------------------------------------------

  /** Coalesce bursts of triggers into one pass. */
  poke() {
    if (this.scheduled || this.closed) return;
    this.scheduled = true;
    setImmediate(() => { this.scheduled = false; this.schedule(); });
  }

  schedule() {
    if (this.closed) return;
    const now = Date.now();
    const cfg = this.cfg;
    const useful = new Set();
    const paced = new Set();
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

  startPump(t, ms, now) {
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
      const oldest = [...this.pumps].sort((a, b) => a.lastUseful - b.lastUseful)[0];
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
      this.onPumpEnd(p, e, 'error');
      return null;
    }
    return p;
  }

  stopPump(p, why) {
    if (!p.alive) return;
    debug(`${this.tag}: stop pump @${(p.startMs / 1000).toFixed(1)}s (${why})`);
    p.alive = false;
    this.pumps.delete(p);
    try { p.handle?.abort(); } catch { /* already gone */ }
  }

  onSegment(p, t, seg) {
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

  onPumpEnd(p, err, how) {
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
  noteFailure(err) {
    this.failures++;
    this.backoffUntil = Date.now() + Math.min(8000, 500 * 2 ** this.failures);
    if (this.failures >= this.cfg.MAX_FAILURES) this.fail(err);
  }

  fail(err) {
    if (this.failed) return;
    this.failed = err;
    log(`${this.tag}: giving up after ${this.failures} failed SABR runs: ${err.message}`);
    for (const p of [...this.pumps]) this.stopPump(p, 'session failed');
    for (const t of this.tracks.values()) t.file.setFailed(err);
  }

  evict(now) {
    for (const t of this.tracks.values()) {
      const ds = t.demands(now);
      const keepFromMs = ds.length ? Math.min(...ds.map((d) => d.ms)) - this.cfg.KEEP_BEHIND_MS : Infinity;
      const readOff = ds.length && ds[0].off !== null ? ds[0].off : 0;
      const freed = t.file.evict({ keepFromMs, readOff, maxBytes: this.cfg.MAX_BYTES[t.kind] });
      if (freed) debug(`${this.tag}: ${t.key}: evicted ${(freed / 1048576).toFixed(1)} MB, holding ${(t.file.bytes / 1048576).toFixed(1)} MB`);
    }
  }

  get tag() { return `session ${this.sid.slice(0, 6)} ${this.info.id}`; }

  get bytes() { let n = 0; for (const t of this.tracks.values()) n += t.file.bytes; return n; }

  get activeReaders() { let n = 0; for (const t of this.tracks.values()) n += t.readers.size; return n; }

  // ---- serving ----------------------------------------------------------------------------

  /**
   * Stream [start, end) of track `t` into `res` (node http.ServerResponse or compatible), waiting for
   * missing bytes up to WAIT_MS each time. Returns the number of bytes written.
   */
  async serve(t, start, end, res) {
    const reader = { pos: start, since: Date.now() };
    t.readers.add(reader);
    t.lastPos = start;
    t.lastReadAt = Date.now();
    this.lastActivity = Date.now();
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
            why = e.message;
            if (e.message === 'timeout') log(`${this.tag}: ${t.key}: no data at ${reader.pos} within ${this.cfg.WAIT_MS / 1000} s - ending response`);
            break;
          }
          continue;
        }
        piece = Buffer.from(piece); // copy: the entry may be evicted while the socket holds it
        reader.pos += piece.length;
        written += piece.length;
        t.lastPos = reader.pos;
        t.lastReadAt = Date.now();
        this.lastActivity = t.lastReadAt;
        if (!res.write(piece)) {
          this.poke();
          await new Promise((resolve) => {
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

  close(why = 'closed') {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.timer);
    for (const p of [...this.pumps]) { p.alive = false; try { p.handle?.abort(); } catch { /* gone */ } }
    this.pumps.clear();
    for (const t of this.tracks.values()) t.file.clear();
    this.subCache.clear();
    log(`${this.tag}: closed (${why})`);
  }

  status() {
    const now = Date.now();
    const tracks = {};
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
        frontier: Object.fromEntries([...p.frontier].map(([t, ms]) => [t.key, ms])) })),
      tracks, fetched: this.fetched, sabrRuns: this.runs, idleMs: now - this.lastActivity,
    };
  }
}
