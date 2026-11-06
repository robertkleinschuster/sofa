// One SABR "pump": a googlevideo SabrStream run from `startMs` for a video+audio pair (or audio only)
// whose segments are handed out with their absolute byte position in the original file.
//
// googlevideo's public output is two plain byte streams. To place the bytes, every segment's
// MediaHeader is needed: Track#recordCompletedSegment is called synchronously right after the
// segment was enqueued into that track's stream (SabrSegmentBuffer#finalizeSegment, googlevideo
// 5.0.1 - pinned in package-lock.json), so a per-track FIFO pairs each chunk read from the stream with
// its header. Every pairing is verified (length == segmentLengthBytes, init at 0); a mismatch ends the
// pump instead of serving misplaced bytes. Streams error out on abort, dropping queued chunks from the
// tail only, so the FIFO head stays aligned.
import { SabrStream } from 'googlevideo/sabr-stream';
import { EnabledTrackTypes, Logger, LogLevel } from 'googlevideo/utils';
import type { ReloadPlaybackContext } from 'googlevideo/protos';
import type { ReloadResponse, SegmentInfo } from 'googlevideo/sabr-stream';
import type { Track, TrackCollection } from 'googlevideo/utils';
import { toError } from './errors.ts';
import { log, debug } from './log.ts';
import type { DescribedFormat } from './formats.ts';
import type { PumpEnd, PumpHandle, PumpRequest, TrackKind } from './session.ts';
import type { VodInfo } from './youtube.ts';

Logger.getInstance().setLogLevels(LogLevel.ERROR);

const MAX_RETRIES = 2; // googlevideo default 10 = ~39 s of 403 retries; surface errors instead

let nextId = 1;

/** One SABR run: the session's request plus what this process adds (main.ts). */
export interface SabrPumpOptions extends PumpRequest {
  info: VodInfo;                                   // cached player info (youtube.ts)
  formats: DescribedFormat[];                      // described formats (formats.ts)
  poToken?: string | undefined;                    // pre-minted websafe token (avoids SPS 3 + backoff on seek starts)
  mintPoToken: () => Promise<Uint8Array>;
  /** YouTube rejected this run's PO token (stream protection status 3): the token must not be reused. */
  onTokenRejected?: () => void;
  reload: (ctx?: ReloadPlaybackContext) => Promise<ReloadResponse>;
}

/** Placement of one completed segment, recorded when googlevideo finalizes it. */
interface SegmentHeader {
  init: boolean;
  start: number;
  length: number;
  startMs: number;
  durationMs: number;
}

/** Start a run; segments go to o.onSegment, the end (once) to o.onEnd. */
export function startSabrPump(o: SabrPumpOptions): PumpHandle & { id: number } {
  const id = nextId++;
  const tag = `pump#${id} ${o.info.id} ${o.video ? `${o.video.itag}+` : 'audio-only '}${o.audio.key} @${(o.startMs / 1000).toFixed(1)}s`;
  let ended = false;
  const end = (err: Error | null, how: PumpEnd): void => {
    if (ended) return;
    ended = true;
    debug(`${tag}: end (${how}${err ? `: ${err.message}` : ''})`);
    o.onEnd(err, how);
  };

  const sabr = new SabrStream({
    videoId: o.info.id,
    formats: o.formats.map((f) => f.sabr),
    serverAbrStreamingUrl: o.info.sabrUrl,
    videoPlaybackUstreamerConfig: o.info.ustreamer,
    clientInfo: { clientName: o.info.clientName, clientVersion: o.info.clientVersion },
    poToken: o.poToken,
    // SabrStream calls this.fetchFunction(...): the browser's fetch must not run with `this` set to the
    // stream ("does not implement interface Window"; node does not care) - always call the global one
    fetchFunction: (input, init) => fetch(input, init),
    callbacks: {
      onMintPoToken: () => o.mintPoToken(),
      onReloadPlayerResponse: (ctx?: ReloadPlaybackContext) => { reloads++; log(`${tag}: SABR asks for a player reload`); return o.reload(ctx); },
    },
  });

  const fifo: Record<TrackKind, SegmentHeader[]> = { video: [], audio: [] };
  // private in googlevideo's types; bracket access is TypeScript's typed escape hatch for it
  const tracks: TrackCollection | undefined = sabr['trackCollection'];
  for (const kind of ['video', 'audio'] as const) {
    const track: Track | undefined = tracks?.[kind];
    if (!track || typeof track.recordCompletedSegment !== 'function') {
      throw new Error('googlevideo internals changed (Track#recordCompletedSegment) - check the pinned version');
    }
    const orig = track.recordCompletedSegment.bind(track);
    track.recordCompletedSegment = (info: SegmentInfo, emsg?: Parameters<Track['recordCompletedSegment']>[1]) => {
      orig(info, emsg);
      const done = track.trackedSegments.get(info.segmentNumber);
      const h = info.mediaHeader || {};
      fifo[kind].push({
        init: !!h.isInitializationSegment,
        start: h.isInitializationSegment ? 0 : Number(h.segmentByteRangeStart),
        length: Number(h.segmentLengthBytes || 0),
        startMs: done?.startTimeMs ?? info.startTimeMs ?? 0,
        durationMs: done?.durationMs ?? info.durationMs ?? 0,
      });
    };
  }

  // what the server last said, for the session's stall report (2026-11-06: runs that stop at 60 s)
  let sps = 0, spsAt = 0, redirects = 0, reloads = 0;
  sabr.on('streamProtectionStatusUpdate', (s) => {
    const was = sps;
    sps = s?.status ?? 0; spsAt = Date.now();
    if (sps !== 1) debug(`${tag}: SPS ${sps}`);
    if (sps === 3 && was !== 3) { log(`${tag}: stream protection rejected the PO token`); o.onTokenRejected?.(); }
  });
  const setUrl = sabr.setStreamingURL.bind(sabr);
  sabr.setStreamingURL = (url: string | URL) => { redirects++; setUrl(url); };
  /** The server's last word on this run: protection status, requested backoff, the player time we report. */
  const diag = (): string => {
    const backoff = sabr['nextRequestPolicy']?.backoffTimeMs || 0;
    const player = Number(sabr['runtime']?.playerTimeMs ?? -1);
    return `[sps=${sps}${spsAt ? `@${((Date.now() - spsAt) / 1000).toFixed(0)}s` : ''} backoff=${backoff}ms`
      + ` player=${(player / 1000).toFixed(1)}s reloads=${reloads} redirects=${redirects}]`;
  };
  sabr.on('error', (e) => end(e instanceof Error ? e : new Error(String(e)), 'error'));
  // 'finish' closes both streams; the readers below report it once they drained every chunk

  let started: ReturnType<SabrStream['start']>;
  try {
    started = sabr.start({
      videoFormat: o.video ? o.video.sabr : undefined,
      audioFormat: o.audio.sabr,
      // SABR has no video-only mode; audio-only for an extra language track
      enabledTrackTypes: o.video ? EnabledTrackTypes.VIDEO_AND_AUDIO : EnabledTrackTypes.AUDIO_ONLY,
      startTimeMs: Math.max(0, Math.round(o.startMs)),
      maxRetries: MAX_RETRIES,
      isPostLiveDvr: false,
    });
  } catch (e) {
    queueMicrotask(() => end(toError(e), 'error'));
    return { id, abort() {} };
  }
  debug(`${tag}: started`);

  const pumpReader = async (kind: TrackKind, stream: ReadableStream<ArrayBufferView>): Promise<void> => {
    const reader = stream.getReader();
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        const h = fifo[kind].shift();
        const buf = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
        if (!h || (h.length && h.length !== buf.length) || !Number.isFinite(h.start)) {
          throw new Error(`segment bookkeeping mismatch on ${kind}: header=${JSON.stringify(h)} bytes=${buf.length}`);
        }
        o.onSegment(kind, { start: h.start, buf, startMs: h.startMs, durationMs: h.durationMs, init: h.init });
      }
    } finally {
      reader.releaseLock();
    }
  };
  const readers = [pumpReader('audio', started.audioStream)];
  if (o.video) readers.push(pumpReader('video', started.videoStream));
  Promise.all(readers).then(() => {
    // both streams closed normally: googlevideo emits 'finish' as well
    if (!sabr.isAborted && !sabr.isErrored) end(null, 'finished');
  }, (e) => {
    if (sabr.isAborted || ended) return end(null, 'aborted');
    sabr.abort().catch(() => {});
    return end(toError(e), 'error');
  });

  return {
    id,
    abort() {
      if (ended) return;
      sabr.abort().catch(() => {});
      end(null, 'aborted');
    },
    diag,
  };
}
