// Segment index parsers: map byte offsets of a YouTube DASH file to media time.
// The SABR init segment of a track covers [0, indexRange.end] of the original file, i.e. it contains
// the WebM Cues (webm) or the sidx box (mp4). Each returns a sorted array of {off, ms} entries,
// one per cluster / subsegment, where `off` is the absolute byte offset in the file.

/** Read an EBML variable-length integer (element ID keeps its marker bit, size strips it). */
function readVint(buf, pos, keepMarker) {
  if (pos >= buf.length) return null;
  const first = buf[pos];
  let len = 1;
  let mask = 0x80;
  while (len <= 8 && !(first & mask)) { len++; mask >>= 1; }
  if (len > 8 || pos + len > buf.length) return null;
  let value = keepMarker ? first : first & (mask - 1);
  let allOnes = (first & (mask - 1)) === mask - 1;
  for (let i = 1; i < len; i++) {
    value = value * 256 + buf[pos + i];
    if (buf[pos + i] !== 0xff) allOnes = false;
  }
  return { value, len, unknown: !keepMarker && allOnes };
}

function readUint(buf, pos, len) {
  let v = 0;
  for (let i = 0; i < len; i++) v = v * 256 + buf[pos + i];
  return v;
}

const EBML_SEGMENT = 0x18538067;
const EBML_INFO = 0x1549a966;
const EBML_TIMECODE_SCALE = 0x2ad7b1;
const EBML_CUES = 0x1c53bb6b;
const EBML_CUEPOINT = 0xbb;
const EBML_CUETIME = 0xb3;
const EBML_CUETRACKPOS = 0xb7;
const EBML_CUECLUSTERPOS = 0xf1;
const EBML_CLUSTER = 0x1f43b675;

/** Iterate child elements of [start, end). Yields {id, dataStart, dataEnd}. Stops on truncation. */
function* ebmlChildren(buf, start, end) {
  let pos = start;
  while (pos < end) {
    const id = readVint(buf, pos, true);
    if (!id) return;
    const size = readVint(buf, pos + id.len, false);
    if (!size) return;
    const dataStart = pos + id.len + size.len;
    const truncated = !size.unknown && dataStart + size.value > end;
    const dataEnd = size.unknown ? end : Math.min(end, dataStart + size.value);
    yield { id: id.value, dataStart, dataEnd, unknown: size.unknown, truncated };
    if (size.unknown) return;
    pos = dataStart + size.value;
  }
}

/** WebM: parse Segment > Info(TimecodeScale) + Cues from the file prefix `buf`. */
export function parseWebmIndex(buf) {
  let segment = null;
  for (const el of ebmlChildren(buf, 0, buf.length)) {
    if (el.id === EBML_SEGMENT) { segment = el; break; }
  }
  if (!segment) return null;
  let timecodeScale = 1000000; // ns per tick (WebM default = 1 ms)
  let cues = null;
  for (const el of ebmlChildren(buf, segment.dataStart, segment.dataEnd)) {
    if (el.id === EBML_INFO) {
      for (const c of ebmlChildren(buf, el.dataStart, el.dataEnd)) {
        if (c.id === EBML_TIMECODE_SCALE) timecodeScale = readUint(buf, c.dataStart, c.dataEnd - c.dataStart);
      }
    } else if (el.id === EBML_CUES) {
      cues = el;
    } else if (el.id === EBML_CLUSTER) {
      break; // media data starts: Cues (if any) came before
    }
  }
  if (!cues || cues.truncated) return null; // partial Cues would map later offsets to wrong times
  const out = [];
  for (const cp of ebmlChildren(buf, cues.dataStart, cues.dataEnd)) {
    if (cp.id !== EBML_CUEPOINT) continue;
    let time = null;
    let pos = null;
    for (const c of ebmlChildren(buf, cp.dataStart, cp.dataEnd)) {
      if (c.id === EBML_CUETIME) time = readUint(buf, c.dataStart, c.dataEnd - c.dataStart);
      else if (c.id === EBML_CUETRACKPOS && pos === null) {
        for (const t of ebmlChildren(buf, c.dataStart, c.dataEnd)) {
          if (t.id === EBML_CUECLUSTERPOS) pos = readUint(buf, t.dataStart, t.dataEnd - t.dataStart);
        }
      }
    }
    if (time !== null && pos !== null) {
      out.push({ off: segment.dataStart + pos, ms: Math.round((time * timecodeScale) / 1e6) });
    }
  }
  return normalize(out);
}

/** MP4: find the top-level sidx box in the file prefix `buf` and expand its references. */
export function parseMp4Index(buf) {
  let pos = 0;
  while (pos + 8 <= buf.length) {
    let size = readUint(buf, pos, 4);
    const type = buf.toString('latin1', pos + 4, pos + 8);
    let header = 8;
    if (size === 1) { if (pos + 16 > buf.length) return null; size = readUint(buf, pos + 8, 8); header = 16; }
    if (size < header) return null;
    if (type === 'sidx') {
      if (pos + size > buf.length) return null;
      return parseSidx(buf, pos, header, size);
    }
    if (type === 'moof' || type === 'mdat') return null; // media started, no index
    pos += size;
  }
  return null;
}

function parseSidx(buf, boxStart, header, boxSize) {
  let p = boxStart + header;
  const version = buf[p]; p += 4; // version + flags
  p += 4; // reference_ID
  const timescale = readUint(buf, p, 4); p += 4;
  let earliest; let firstOffset;
  if (version === 0) { earliest = readUint(buf, p, 4); firstOffset = readUint(buf, p + 4, 4); p += 8; }
  else { earliest = readUint(buf, p, 8); firstOffset = readUint(buf, p + 8, 8); p += 16; }
  p += 2; // reserved
  const count = readUint(buf, p, 2); p += 2;
  if (!timescale || p + count * 12 > boxStart + boxSize) return null;
  let off = boxStart + boxSize + firstOffset;
  let t = earliest;
  const out = [];
  for (let i = 0; i < count; i++) {
    const ref = readUint(buf, p, 4);
    const dur = readUint(buf, p + 4, 4);
    p += 12;
    if (ref & 0x80000000) return null; // hierarchical sidx: not used by YouTube
    out.push({ off, ms: Math.round((t * 1000) / timescale) });
    off += ref & 0x7fffffff;
    t += dur;
  }
  return normalize(out);
}

function normalize(entries) {
  if (!entries.length) return null;
  entries.sort((a, b) => a.off - b.off);
  return entries.filter((e, i) => i === 0 || e.off > entries[i - 1].off);
}

/** Parse whichever index the init segment carries (by MIME type). */
export function parseIndex(initBuf, mimeType) {
  try {
    return (mimeType || '').includes('webm') ? parseWebmIndex(initBuf) : parseMp4Index(initBuf);
  } catch {
    return null;
  }
}

/** Index entry with the greatest offset <= off (binary search), or null. */
export function indexLookup(index, off) {
  if (!index || !index.length || off < index[0].off) return null;
  let lo = 0; let hi = index.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (index[mid].off <= off) lo = mid; else hi = mid - 1;
  }
  return index[lo];
}
