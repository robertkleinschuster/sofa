// The parts of YouTube's raw WEB player response (camelCase Innertube JSON) the engine reads.
// Every field is optional: YouTube changes the response at will, and every reader coerces (Number,
// String) and guards (?.) what it uses. asPlayerResponse() is the one boundary where untrusted JSON
// becomes this type: the containers we descend into are checked to be objects/arrays of objects.
import type { FormatStream } from 'googlevideo/shared-types';
import { isRecord, records } from './json.ts';
import type { JsonObject } from './json.ts';

/** Innertube text: either `simpleText` or a list of runs. */
export interface RawText {
  simpleText?: string;
  runs?: { text?: string }[];
}

/** One `adaptiveFormats` entry (what googlevideo's buildSabrFormat reads, plus what Sofa reads). */
export interface RawFormat extends FormatStream {
  audioTrack?: { id?: string; displayName?: string; audioIsDefault?: boolean };
  initRange?: { start: string; end: string };
  indexRange?: { start: string; end: string };
}

export interface RawCaptionTrack {
  baseUrl?: string;
  languageCode?: string;
  kind?: string;            // 'asr' = automatic
  isTranslatable?: boolean;
  name?: RawText;
  vssId?: string;
}

export interface RawCaptions {
  playerCaptionsTracklistRenderer?: {
    captionTracks?: RawCaptionTrack[];
    translationLanguages?: { languageCode?: string }[];
  };
}

export interface RawEndscreenElement {
  endscreenElementRenderer?: {
    style?: string;
    endpoint?: {
      watchEndpoint?: { videoId?: string; playlistId?: string };
      browseEndpoint?: { browseId?: string };
    };
    image?: { thumbnails?: { url?: string }[] };
    title?: RawText;
    left?: number;
    top?: number;
    width?: number;
    aspectRatio?: number;
    startMs?: string;
    endMs?: string;
  };
}

export interface RawPlayabilityStatus {
  status?: string;
  reason?: string;
  errorScreen?: { playerErrorMessageRenderer?: { subreason?: RawText } };
  liveStreamability?: {
    liveStreamabilityRenderer?: {
      videoId?: string;
      offlineSlate?: { liveStreamOfflineSlateRenderer?: { scheduledStartTime?: string } };
    };
  };
}

export interface RawVideoDetails {
  title?: string;
  author?: string;
  lengthSeconds?: string;
  isLive?: boolean;
  isUpcoming?: boolean;
  isPostLiveDvr?: boolean;
}

export interface RawStreamingData {
  serverAbrStreamingUrl?: string;
  hlsManifestUrl?: string;
  expiresInSeconds?: string;
  adaptiveFormats?: RawFormat[];
}

export interface RawPlayerResponse {
  playabilityStatus?: RawPlayabilityStatus;
  videoDetails?: RawVideoDetails;
  microformat?: {
    playerMicroformatRenderer?: { liveBroadcastDetails?: { isLiveNow?: boolean; startTimestamp?: string }; publishDate?: string; uploadDate?: string };
  };
  streamingData?: RawStreamingData;
  playerConfig?: {
    mediaCommonConfig?: { mediaUstreamerRequestConfig?: { videoPlaybackUstreamerConfig?: string } };
  };
  captions?: RawCaptions;
  endscreen?: { endscreenRenderer?: { elements?: RawEndscreenElement[] } };
  /** Where youtube.com's player reports a view (stats/playback, watchtime, ptracking, atr, qoe). */
  playbackTracking?: Partial<Record<'videostatsPlaybackUrl' | 'videostatsWatchtimeUrl' | 'ptrackingUrl' | 'atrUrl' | 'qoeUrl', { baseUrl?: string }>>
    & { videostatsScheduledFlushWalltimeSeconds?: unknown[]; videostatsDefaultFlushIntervalSeconds?: unknown };
}

const CONTAINERS = ['playabilityStatus', 'videoDetails', 'microformat', 'streamingData', 'playerConfig',
  'captions', 'endscreen', 'playbackTracking'] as const;

/**
 * Untrusted JSON -> RawPlayerResponse. Non-objects become `{}`; a top-level container that is not an
 * object is dropped; `streamingData.adaptiveFormats` keeps only its objects.
 */
export function asPlayerResponse(x: unknown): RawPlayerResponse {
  if (!isRecord(x)) return {};
  const out: JsonObject = { ...x };
  for (const k of CONTAINERS) if (k in out && !isRecord(out[k])) delete out[k];
  const sd = out.streamingData;
  if (isRecord(sd) && 'adaptiveFormats' in sd) {
    out.streamingData = { ...sd, adaptiveFormats: records(sd.adaptiveFormats) };
  }
  // the shape of everything below the checked containers is read defensively (see above)
  return out as RawPlayerResponse;
}

/** The text of an Innertube text object (simpleText, else the joined runs), '' if none. */
export function rawText(t: RawText | undefined): string {
  return t?.simpleText || (t?.runs || []).map((x) => x.text).join('');
}
