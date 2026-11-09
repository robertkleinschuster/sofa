// A one-line description of a SABR answer (UMP stream) for the debug log: the parts in order and
// the decoded policies that steer the next request (backoff, readahead, context, protection).
// Used for raw data on the start delay (NOTES.md: YouTube start): what the server answers to
// request 1. Opaque values (cookies, context signatures) are reported by size only.
import { UmpReader } from 'googlevideo/ump';
import type { CompositeBuffer } from 'googlevideo/ump';
import {
  UMPPartId, NextRequestPolicy, SabrError, SabrRedirect, SabrContextUpdate, SabrContextSendingPolicy,
  StreamProtectionStatus, PlaybackStartPolicy,
} from 'googlevideo/protos';

function bytesOf(data: CompositeBuffer): Uint8Array {
  const out = new Uint8Array(data.getLength());
  let o = 0;
  for (const c of data.chunks) { out.set(c, o); o += c.length; }
  return out;
}

const defined = (o: Record<string, unknown>): string =>
  Object.entries(o).filter(([, v]) => v !== undefined).map(([k, v]) => `${k}=${v}`).join(' ');

/** The decoded detail of the parts that matter for request pacing; undefined for the rest. */
function detail(type: number, b: Uint8Array): string | undefined {
  switch (type) {
    case UMPPartId.NEXT_REQUEST_POLICY: {
      const { playbackCookie, videoId: _v, ...p } = NextRequestPolicy.decode(b);
      return defined({ ...p, playbackCookie: playbackCookie ? `${playbackCookie.length}B` : undefined });
    }
    case UMPPartId.SABR_ERROR: return defined({ ...SabrError.decode(b) });
    case UMPPartId.SABR_REDIRECT: return SabrRedirect.decode(b).url ? 'url set' : 'no url';
    case UMPPartId.SABR_CONTEXT_UPDATE: {
      const u = SabrContextUpdate.decode(b);
      return defined({ type: u.type, scope: u.scope, sendByDefault: u.sendByDefault, writePolicy: u.writePolicy,
        value: u.value ? `${u.value.length}B` : undefined });
    }
    case UMPPartId.SABR_CONTEXT_SENDING_POLICY: {
      const s = SabrContextSendingPolicy.decode(b);
      return `start=[${s.startPolicy}] stop=[${s.stopPolicy}] discard=[${s.discardPolicy}]`;
    }
    case UMPPartId.STREAM_PROTECTION_STATUS: return defined({ ...StreamProtectionStatus.decode(b) });
    case UMPPartId.PLAYBACK_START_POLICY: {
      const p = PlaybackStartPolicy.decode(b);
      return defined({ startMs: p.startMinReadaheadPolicy?.minReadaheadMs, startTimeoutMs: p.startTimeoutMs,
        resumeMs: p.resumeMinReadaheadPolicy?.minReadaheadMs, resumeTimeoutMs: p.resumeTimeoutMs });
    }
    default: return undefined;
  }
}

/** "PART(detail), PART x3, ..." - consecutive parts of one type without detail are collapsed. */
export async function describeUmp(bytes: Uint8Array): Promise<string> {
  const parts: string[] = [];
  let last = '', run = 0;
  const flush = (): void => { if (run) parts.push(run > 1 ? `${last} x${run}` : last); run = 0; };
  const reader = new UmpReader({
    onPart(type: UMPPartId, data: CompositeBuffer) {
      const name = UMPPartId[type] ?? `PART_${type}`;
      let d: string | undefined;
      try { d = detail(type, bytesOf(data)); } catch { d = 'undecodable'; }
      if (d !== undefined) { flush(); parts.push(`${name}(${d})`); return; }
      if (name !== last) flush();
      last = name; run++;
    },
  });
  await reader.feed(bytes);
  flush();
  return parts.length ? parts.join(', ') : 'empty';
}
