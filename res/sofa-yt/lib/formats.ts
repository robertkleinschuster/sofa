// Format / track choice for Sofa (the rules of the former yt-dlp resolver: best video up to the
// height asked, original audio language first, subtitle tracks). Pure functions over the raw player
// response (camelCase JSON).
import { buildSabrFormat } from 'googlevideo/utils';
import { FormatXTags } from 'googlevideo/protos';
import type { SabrFormat } from 'googlevideo/shared-types';
import { rawText } from './ytraw.ts';
import { fromBase64 } from './bytes.ts';
import type { RawCaptionTrack, RawCaptions, RawFormat } from './ytraw.ts';

export const DEFAULT_MAX_HEIGHT = 1080;
export const MAX_FPS = 60;

/** An adaptive format with everything the choice (and SABR) needs. */
export interface DescribedFormat {
  key: string;                       // unique per format, names the local audio URL
  raw: RawFormat;
  sabr: SabrFormat;                  // what googlevideo needs
  isAudio: boolean;
  xtags: Record<string, string>;
  itag: number;
  mimeType: string;
  codec: string;
  height: number;
  fps: number;
  bitrate: number;
  contentLength: number;
  durationMs: number;
  lang: string | null;
  trackName: string | null;
  isDefaultTrack: boolean;
  drc: boolean;
  vb: boolean;
  hdr: boolean;
  sr: boolean;
}

export interface AudioTrackChoice {
  lang: string;
  format: DescribedFormat;
  name: string | null;
  original: boolean;
  dubbed: boolean;
  described: boolean;
}

export type SubtitleKind = 'manual' | 'auto' | 'translated';

export interface SubtitleTrack {
  key: string;
  lang: string;
  name: string;
  kind: SubtitleKind;
  baseUrl: string;
  tlang?: string;
}

function decodeXtags(xtags: string | undefined): Record<string, string> {
  if (!xtags) return {};
  try {
    const bytes = fromBase64(decodeURIComponent(xtags));
    const out: Record<string, string> = {};
    for (const kv of FormatXTags.decode(new Uint8Array(bytes)).xtags || []) if (kv.key !== undefined) out[kv.key] = kv.value ?? '';
    return out;
  } catch {
    return {};
  }
}

/** Short codec name as Sofa's mpv code expects it: vp9 / av01 / avc1 / opus / mp4a. */
export function codecOf(mimeType: string | undefined): string {
  const m = /codecs="([^"]+)"/.exec(mimeType || '');
  const c = (m?.[1] ?? '').split(',')[0]!.trim().split('.')[0]!;
  return c === 'vp09' ? 'vp9' : c;
}

/**
 * Enrich every adaptive format: the SabrFormat googlevideo needs (`sabr`) plus what the choice needs.
 * `key` is unique per format (itag alone is not: DRC / voice boost / several audio languages share it).
 */
export function describeFormats(adaptiveFormats: RawFormat[] | undefined): DescribedFormat[] {
  const out: DescribedFormat[] = [];
  const seen = new Map<string, number>();
  for (const raw of adaptiveFormats || []) {
    if (!raw || !raw.mimeType || !raw.contentLength) continue;
    const sabr = buildSabrFormat(raw);
    const x = decodeXtags(raw.xtags);
    const isAudio = raw.mimeType.startsWith('audio/');
    let key = String(raw.itag);
    if (isAudio) {
      if (raw.audioTrack?.id) key += '-' + raw.audioTrack.id;
      if (sabr.isDrc) key += '-drc';
      if (sabr.isVb) key += '-vb';
    }
    const n = seen.get(key) || 0;
    seen.set(key, n + 1);
    if (n) key += '-' + n;
    out.push({
      key, raw, sabr, isAudio, xtags: x,
      itag: raw.itag,
      mimeType: raw.mimeType,
      codec: codecOf(raw.mimeType),
      height: raw.height || 0,
      fps: raw.fps || 0,
      bitrate: raw.averageBitrate || raw.bitrate || 0,
      contentLength: Number(raw.contentLength),
      durationMs: Number(raw.approxDurationMs) || 0,
      lang: isAudio ? (raw.audioTrack?.id || '').split('.')[0] || x.lang || sabr.language || null : null,
      trackName: raw.audioTrack?.displayName || null,
      isDefaultTrack: !!raw.audioTrack?.audioIsDefault,
      drc: !!sabr.isDrc,
      vb: !!sabr.isVb,
      hdr: !!sabr.isHdr,
      sr: !!sabr.isSr,
    });
  }
  return out;
}

/** 10 original, 5 default, 0 unknown, -1 dubbed, -2 auto-dubbed, -10 audio description. */
export function audioPref(f: DescribedFormat): number {
  const acont = f.xtags.acont || '';
  if (acont === 'original') return 10;
  if (acont === 'dubbed-auto') return -2;
  if (acont.startsWith('dubbed') || acont === 'secondary') return -1;
  if (acont === 'descriptive') return -10;
  if (f.trackName && /original/i.test(f.trackName)) return 10;
  if (f.isDefaultTrack) return 5;
  return 0;
}

/** Ranking tuple (compared lexicographically): original first, no DRC/voice boost, Opus, bitrate. */
export function audioRank(f: DescribedFormat): number[] {
  return [audioPref(f), f.drc || f.vb ? 0 : 1, f.codec === 'opus' ? 1 : 0, f.bitrate];
}

function cmpTuple(a: number[], b: number[]): number {
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i]! > b[i]! ? 1 : -1;
  return 0;
}

const VIDEO_CODEC_RANK: Record<string, number> = { vp9: 2, av01: 1, avc1: 0 };

/**
 * Video choice (user requirement: max 1080p60): highest resolution, then fps, then
 * VP9 > AV1 > H.264 (mpv decodes in software; VP9 is the cheapest, see docs/codecs-research.md).
 * HDR and super-resolution variants only if nothing else is left.
 */
export function pickVideo(formats: DescribedFormat[], maxHeight = DEFAULT_MAX_HEIGHT, preferCodec: string | null = null): DescribedFormat | null {
  const vids = formats.filter((f) => !f.isAudio && f.codec in VIDEO_CODEC_RANK && f.height > 0);
  const ok = (f: DescribedFormat): boolean => f.height <= maxHeight && (f.fps || 30) <= MAX_FPS;
  const plain = vids.filter((f) => ok(f) && !f.hdr && !f.sr);
  const pool = plain.length ? plain : vids.filter(ok).length ? vids.filter(ok) : vids;
  if (!pool.length) return null;
  // preferCodec (downloads: avc1, so the file is a plain MP4) wins at equal resolution and fps
  const rank = (f: DescribedFormat): number => (f.codec === preferCodec ? 9 : VIDEO_CODEC_RANK[f.codec]!);
  const key = (f: DescribedFormat): number[] => [ok(f) ? 1 : 0, ok(f) ? f.height : -f.height, f.fps, rank(f), f.bitrate];
  return pool.reduce((best, f) => (cmpTuple(key(f), key(best)) > 0 ? f : best));
}

/** Best audio format overall (original language first, never auto-dubbed when anything else exists). */
export function pickAudio(formats: DescribedFormat[], preferCodec: string | null = null): DescribedFormat | null {
  const auds = formats.filter((f) => f.isAudio && (f.codec === 'opus' || f.codec === 'mp4a'));
  if (!auds.length) return null;
  // preferCodec (downloads: mp4a) replaces the opus preference; the original track still wins first
  const rank = (f: DescribedFormat): number[] => {
    const r = audioRank(f);
    if (preferCodec) r[2] = f.codec === preferCodec ? 1 : 0;
    return r;
  };
  return auds.reduce((best, f) => (cmpTuple(rank(f), rank(best)) > 0 ? f : best));
}

/** Best audio format per language (for the language choice), original first; [] for one language. */
export function audioTracks(formats: DescribedFormat[]): AudioTrackChoice[] {
  const best = new Map<string, DescribedFormat>();
  for (const f of formats) {
    if (!f.isAudio || !(f.codec === 'opus' || f.codec === 'mp4a')) continue;
    const lang = f.lang || 'und';
    const cur = best.get(lang);
    if (!cur || cmpTuple(audioRank(f), audioRank(cur)) > 0) best.set(lang, f);
  }
  if (best.size < 2) return [];
  const out = [...best.entries()].map(([lang, f]): AudioTrackChoice => {
    const p = audioPref(f);
    return { lang, format: f, name: f.trackName, original: p === 10, dubbed: p < 0 && p > -10, described: p === -10 };
  });
  out.sort((a, b) => (Number(b.original) - Number(a.original)) || (Number(a.described) - Number(b.described))
    || a.lang.localeCompare(b.lang));
  return out;
}

/**
 * Subtitle tracks: all manual tracks, the automatic track in the
 * spoken language ("auto"), and the automatic translation into `userLang` only if there is no real
 * track in that language and the video is not spoken in it.
 * Returns [{key, lang, name, kind, baseUrl, tlang?}]; `key` names the local URL.
 */
export function subtitleTracks(captions: RawCaptions | null | undefined, userLang = 'de'): SubtitleTrack[] {
  const r = captions?.playerCaptionsTracklistRenderer;
  const tracks = r?.captionTracks || [];
  const name = (t: RawCaptionTrack): string => rawText(t.name) || String(t.languageCode);
  const out: SubtitleTrack[] = [];
  const have = new Set<string>();
  let spoken: string | null = null;
  for (const t of tracks) {
    if (!t.baseUrl || !t.languageCode) continue;
    if (t.kind === 'asr') {
      spoken = spoken || t.languageCode;
      out.push({ key: `a-${t.languageCode}`, lang: t.languageCode, name: name(t), kind: 'auto', baseUrl: t.baseUrl });
    } else {
      const k = `m-${t.languageCode}${out.some((o) => o.key === `m-${t.languageCode}`) ? '-' + out.length : ''}`;
      out.push({ key: k, lang: t.languageCode, name: name(t), kind: 'manual', baseUrl: t.baseUrl });
      have.add(t.languageCode.split('-')[0]!);
    }
  }
  const ul = (userLang || 'de').split('-')[0]!;
  const translatable = tracks.find((t) => t.kind === 'asr' && t.isTranslatable) || tracks.find((t) => t.isTranslatable);
  const canTranslate = (r?.translationLanguages || []).some((l) => l.languageCode === ul);
  if (!have.has(ul) && (spoken || '').split('-')[0] !== ul && translatable && canTranslate) {
    out.push({ key: `t-${ul}`, lang: ul, name: `${name(translatable)} -> ${ul}`, kind: 'translated',
      baseUrl: String(translatable.baseUrl), tlang: ul });
  }
  // manual first (as yt-dlp lists them), then auto, then translated
  const order: Record<SubtitleKind, number> = { manual: 0, auto: 1, translated: 2 };
  return out.sort((a, b) => order[a.kind] - order[b.kind]);
}
