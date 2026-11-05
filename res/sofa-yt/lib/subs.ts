// Captions as WebVTT, fetched on demand from YouTube's timedtext endpoint (fmt=vtt) with this
// session's web identity. Caption URLs marked exp=xpe need a PO token bound to the video id.
const FETCH_TIMEOUT_MS = 15000;
const MAX_BYTES = 4 << 20;

/** What a caption URL is built from (a SubtitleTrack of formats.ts). */
export interface CaptionSource {
  baseUrl: string;
  tlang?: string;
}

export interface CaptionAuth {
  poToken?: string | null;
  clientVersion?: string;
}

export function captionUrl(track: CaptionSource, { poToken, clientVersion }: CaptionAuth = {}): string {
  const u = new URL(track.baseUrl);
  u.searchParams.set('fmt', 'vtt');
  if (track.tlang) u.searchParams.set('tlang', track.tlang);
  if (poToken && (u.searchParams.get('exp') || '').includes('xpe')) {
    u.searchParams.set('pot', poToken);
    u.searchParams.set('c', 'WEB');
    if (clientVersion) u.searchParams.set('cver', clientVersion);
  }
  return u.toString();
}

/** Minimal sanity check + normalization (BOM, CRLF) of a WebVTT body. */
export function normalizeVtt(text: string | null | undefined): string {
  const t = String(text || '').replace(/^﻿/, '').replace(/\r\n?/g, '\n');
  if (!t.startsWith('WEBVTT')) throw new Error('not WebVTT');
  return t;
}

export async function fetchVtt(track: CaptionSource,
  { headers, poToken, clientVersion, fetchFn = fetch }: CaptionAuth & { headers: Record<string, string>; fetchFn?: typeof fetch }): Promise<string> {
  const r = await fetchFn(captionUrl(track, { poToken, clientVersion }), {
    headers, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (!r.ok) throw new Error(`timedtext HTTP ${r.status}`);
  const body = await r.text();
  if (body.length > MAX_BYTES) throw new Error('caption track too large');
  if (!body.trim()) throw new Error('empty caption track (PO token rejected?)');
  return normalizeVtt(body);
}
