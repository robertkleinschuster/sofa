// The codecs this browser decodes in fragmented MP4, told to Sofa with every play (docs/pwa.md §8):
// Sofa serves a stored video's tracks as they are where the browser decodes them (Firefox, Chrome: VP9,
// AV1, Opus) and converts the rest to H.264/AAC (Safari, iOS: a downloaded YouTube video).

// One MP4 type per sample entry Sofa names (SFAVBrowserCodec)
export const FORMAT_PROBES: Readonly<Record<string, string>> = {
  avc1: 'video/mp4; codecs="avc1.640028"',
  hvc1: 'video/mp4; codecs="hvc1.1.6.L120.90"',
  vp09: 'video/mp4; codecs="vp09.00.40.08"',
  av01: 'video/mp4; codecs="av01.0.08M.08"',
  mp4a: 'audio/mp4; codecs="mp4a.40.2"',
  opus: 'audio/mp4; codecs="opus"',
};

// `mse`: the browser's MediaSource test (hls.js plays through it); null: the browser's own HLS player
// (Safari, iOS) - it is told only what every Apple player decodes in HLS, H.264 and AAC.
export function browserFormats(mse: ((type: string) => boolean) | null): string[] {
  if (!mse) return ['avc1', 'mp4a'];
  return Object.entries(FORMAT_PROBES).filter(([, type]) => { try { return mse(type); } catch { return false; } }).map(([name]) => name);
}

// The MediaSource test of this browser (ManagedMediaSource on iOS 17+), null without one
export function mediaSourceTest(): ((type: string) => boolean) | null {
  const g = globalThis as unknown as { ManagedMediaSource?: { isTypeSupported(t: string): boolean }; MediaSource?: { isTypeSupported(t: string): boolean } };
  const ms = g.MediaSource ?? g.ManagedMediaSource;
  return ms ? (type: string) => ms.isTypeSupported(type) : null;
}
