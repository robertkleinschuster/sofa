# Media store: buffer and download are one thing

Status: agreed with the user 2026-11-08; phase 1 built (store, YouTube read-through, eviction).

## What the user sees

- Two states only. **geladen**: what playback (or pre-buffering) fetched stays on disk for a while
  - leaving a video and coming back starts at once from it, nothing is fetched twice. **Heruntergeladen**:
  the user chose "Herunterladen"; kept until the user deletes it.
- "Herunterladen" on a video watched (or half watched) fetches only what is missing.
- Subscriptions no longer download: new episodes are **pre-buffered** and stay for a while (until
  watched plus a few days, at most two weeks) - then they go like any buffer.
- All sources (YouTube and the mediatheks), not one alone.
- The space is computed from the disk: the buffer may use the free space minus a reserve that always
  stays free; downloads count against the disk, never get evicted.

## Where the bytes flow today

- YouTube: mpv (and ffmpeg for downloads) read `http://127.0.0.1:<port>/s/<sid>/video|audio` from
  Sofa's loopback server (`SFYTEngine+Media.m`), which asks the engine page for 1 MiB pieces; the page
  holds the SABR segments in memory (`res/sofa-yt/lib/session.ts`, capped and evicted).
- Mediatheks: mpv plays the CDN's HLS / MP4 URLs directly; downloads run ffmpeg into an MP4.

## The design

### 1. SFMediaStore (src/Library) - bytes on disk, by track

- A **track** is one byte stream with a stable identity: `key` = source-specific. YouTube:
  `yt:<video>:<format key>:<lastModified>:<length>` - named by the engine (open and read answers), so
  the sofa, a lounge video and a download of the same format share one copy; a re-encode (new lmt) is
  a new track. Later: `http:<url-hash>:<length>` (a progressive file), `hls:<playlist-hash>:<segment>`.
- Bytes live in **4 MiB block files** `~/Movies/Sofa/.store/<track>/<block>` (HFS+ has no sparse
  files: one file per track would write zeros up to every seek target); the present ranges are an
  `SFExtentSet` per track, in memory (reads never wait on the database).
- Persisted in the store's **own database** `.store/store.db` (own connection and queue: the user
  database never waits on media writes), schema version 1 (`PRAGMA user_version`):
  - `tracks (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, item TEXT NOT NULL, kind TEXT NOT NULL, total INTEGER NOT NULL DEFAULT 0, used REAL NOT NULL)` + index on `item`
  - `extents (track INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE, start INTEGER NOT NULL, end INTEGER NOT NULL, CHECK (end > start), PRIMARY KEY (track, start)) WITHOUT ROWID`
  - Later (phase 2): what playing a complete entry offline needs (formats, duration, subtitles, end
    screen) without the source.
- Retention lives with the item, in `downloads` (the user-facing record it already is): an item with
  a `downloads` row is pinned (`isPinned`); a pre-buffered episode gets an expiry (phase 3); an item
  without one is plain buffer.

### 2. Read-through at the proxies

- **YouTube**: `serveTrack:` serves each piece from the store when present, otherwise reads it from
  the engine and writes it to the store on the way to mpv. A session for a complete entry needs no
  SABR at all.
- **Mediatheks**: a generic loopback proxy (`SFMediaProxy`, same `SFLocalHTTP`) in front of the CDN:
  progressive MP4 by ranges, HLS by rewriting the media playlist to local segment URLs. mpv plays the
  local URL; every byte passes the store.

### 3. Filling and pinning ("Herunterladen", pre-buffering)

- A filler fetches a track's missing extents through the same path a player uses (YouTube: engine
  reads at human pace - the engine paces SABR already; HTTP: range GETs), one item at a time, after
  manual requests first, under the existing per-source budgets and bot-check pauses.
- Complete + `keep` = Heruntergeladen. No MP4 mux for new YouTube downloads: playback reads the
  tracks; an MP4 export stays possible as an action of its own if ever wanted.

### 4. Eviction

- Budget = free space on the volume minus the reserve (`SFDownloads storageReserve`), re-read on
  every write batch; over it, unpinned tracks go least-recently-used first, partial before complete,
  expired pre-buffers before everything. Pinned tracks are never touched; the storage guard stops
  fillers instead.

### 5. UI

- Tiles: a small mark for "geladen" (the existing download mark for "Heruntergeladen").
- Timeline: the stored ranges as a shade under the played bar (from the extents).
- "Herunterladen" on a buffered item: "noch 340 MB" while it fills.

### 6. Migration

- Existing MP4 downloads stay as they are (pinned files); the store starts empty.

## Phases

1. Store + YouTube read-through + eviction (resume from disk; nothing visible but speed).
2. YouTube "Herunterladen" = pin + fill; the YouTube ffmpeg mux goes.
3. Pre-buffering replaces subscription downloads (with expiry).
4. Mediatheks through SFMediaProxy (read-through, then fill/pin like 2-3).
5. UI: tile mark, timeline shade, "noch X MB".

Each phase: tests first where the logic is pure (extents, budget, eviction order - `tests/units`),
the proxies end to end in `test-playback` / `test-downloads` with local servers.
