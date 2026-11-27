// The codecs this browser decodes in fragmented MP4, told to Sofa with every play (docs/pwa.md §8,
// docs/api.md "Playing: formats"), in the order Sofa should prefer them: the newest the device decodes
// in hardware first - AV1, then VP9, HEVC, H.264; Opus before AAC - for the fewest bytes per picture.
// Sofa opens YouTube in the first of them it offers (biggest picture first), serves a stored video's
// tracks as they are where the browser decodes them and converts the rest to H.264/AAC.
//
// Hardware first: a codec the browser decodes only in software (AV1 on an iPhone before the 15 Pro has
// none at all; on a Mac without a decoder it would be dav1d on the CPU) is left out while one decodes in
// hardware, so a newer codec never costs the battery - Media Capabilities' powerEfficient says which.
// The browser's own HLS player (Safari, iOS) is asked only for Apple's HLS codecs (HLS Authoring
// Specification: H.264, HEVC, AV1 + AAC; VP9 and Opus are no HLS codecs there).

// One MP4 type per sample entry Sofa names (SFAVBrowserCodec)
export const FORMAT_PROBES: Readonly<Record<string, string>> = {
  avc1: 'video/mp4; codecs="avc1.640028"',
  hvc1: 'video/mp4; codecs="hvc1.1.6.L120.90"',
  vp09: 'video/mp4; codecs="vp09.00.40.08"',
  av01: 'video/mp4; codecs="av01.0.08M.08"',
  mp4a: 'audio/mp4; codecs="mp4a.40.2"',
  opus: 'audio/mp4; codecs="opus"',
};

const VIDEO = ['av01', 'vp09', 'hvc1', 'avc1'];     // newest first
const AUDIO = ['opus', 'mp4a'];
const APPLE_HLS = new Set(['av01', 'hvc1', 'avc1', 'mp4a']);

export interface Probe { supported: boolean; efficient: boolean }
export type Prober = (codec: string) => Promise<Probe>;

// `native`: the browser's own HLS player plays it (Apple's codecs only; H.264 + AAC always)
export async function browserFormats(probe: Prober, native: boolean): Promise<string[]> {
  const ask = async (c: string): Promise<Probe> => {
    if (native && !APPLE_HLS.has(c)) return { supported: false, efficient: false };
    try { return await probe(c); } catch { return { supported: false, efficient: false }; }
  };
  const v = await Promise.all(VIDEO.map(ask)), a = await Promise.all(AUDIO.map(ask));
  const hw = VIDEO.filter((_, i) => v[i]!.supported && v[i]!.efficient);
  const video = hw.length ? hw : VIDEO.filter((_, i) => v[i]!.supported);
  const audio = AUDIO.filter((_, i) => a[i]!.supported);
  if (native) {   // every Apple player decodes these, whatever a probe said
    if (!video.includes('avc1')) video.push('avc1');
    if (!audio.includes('mp4a')) audio.push('mp4a');
  }
  return [...video, ...audio];
}

// The MediaSource test of this browser (ManagedMediaSource on iOS 17+), null without one
export function mediaSourceTest(): ((type: string) => boolean) | null {
  const g = globalThis as unknown as { ManagedMediaSource?: { isTypeSupported(t: string): boolean }; MediaSource?: { isTypeSupported(t: string): boolean } };
  const ms = g.MediaSource ?? g.ManagedMediaSource;
  return ms ? (type: string) => ms.isTypeSupported(type) : null;
}

// This browser's answer: can it play the type (MediaSource for hls.js, the element for its own HLS
// player), and does it do so in hardware (Media Capabilities; without them: as supported)
export function browserProber(native: boolean, video: HTMLVideoElement): Prober {
  const mse = native ? null : mediaSourceTest();
  return async (codec) => {
    const type = FORMAT_PROBES[codec];
    if (!type) return { supported: false, efficient: false };
    const supported = native ? video.canPlayType(type) !== '' : !!mse?.(type);
    if (!supported) return { supported, efficient: false };
    const mc = (navigator as Navigator & { mediaCapabilities?: MediaCapabilities }).mediaCapabilities;
    if (!mc?.decodingInfo || type.startsWith('audio/')) return { supported, efficient: true };
    try {
      const r = await mc.decodingInfo({ type: native ? 'file' : 'media-source',
        video: { contentType: type, width: 1920, height: 1080, bitrate: 3_000_000, framerate: 30 } });
      return { supported: r.supported, efficient: r.supported && r.powerEfficient };
    } catch { return { supported, efficient: true }; }
  };
}

// Once per page: the answers don't change while it lives
const known = new Map<boolean, Promise<string[]>>();
export function formatsOf(native: boolean, video: HTMLVideoElement): Promise<string[]> {
  let p = known.get(native);
  if (!p) { p = browserFormats(browserProber(native, video), native); known.set(native, p); }
  return p;
}
