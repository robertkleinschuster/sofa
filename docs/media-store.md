# Media store: buffer and download are one thing

Status: agreed with the user 2026-11-08; phases 1-5 built - every download is the store's (YouTube, the
mediatheks' progressive files, ORF's HLS); tiles, "noch X MB" and the exact timeline shade show it.

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

## Where the bytes flow (before the store; now see the phases)

- YouTube: mpv reads `http://127.0.0.1:<port>/s/<sid>/video|audio` from
  Sofa's loopback server (`SFYTEngine+Media.m`), which asks the engine page for 1 MiB pieces; the page
  holds the SABR segments in memory (`res/sofa-yt/lib/session.ts`, capped and evicted).
- Mediatheks: mpv reads the CDN's HLS / MP4 through SFMediaProxy (4a/4b); downloads fill the store.

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
- Retention lives with the item, in `downloads` (the user-facing record it already is), its kind
  explicit in `downloads.store` (1: the content is the store's tracks, 0: a file). A store download
  and anything a pending download will read are pinned - a snapshot set SFDownloads swaps on every
  record write (the store asks from its own queue). A file download (sources not in the store yet)
  drops the store copy it was read through once its file is installed. A pre-buffered episode gets
  an expiry (phase 3); an item without a record is plain buffer.
- Integrity: on open the store checks its index against the block files (asynchronously); at launch
  store downloads that are no longer complete are queued again and fill only what is missing.

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

Decided with the user 2026-11-08: download and buffer are merged, not bridged - no MP4 for what the
store can hold; existing downloads may be deleted (no migration of old files).

1. Done: store + YouTube read-through + eviction (resume from disk; nothing visible but speed).
2. Done - YouTube merged (SFYTEngine+Store.m, SFYTEngine+Fill.m, SFApp fillItem:, test-downloads 8):
   a. Manifests in the store (schema v2): per item what playing it needs without its source - the
      tracks (video, main audio), subtitles (stored as small tracks), duration, end screen,
      published. Written when a session opens.
   b. Store sessions: an item whose manifest tracks are complete plays from a session Sofa serves
      itself (same answer shape as the engine's, local URLs) - no engine, also offline.
   c. Filler: a download is pin + fill - the missing ranges are read through the same read path
      (engine session, paced like a player), no ffmpeg, no MP4, no verifier/repair.
   d. `downloads` = intent only (state, subscription, keep, online check); size from the store; the
      path/bytes/repair columns and YouTube's ffmpeg path go; existing YouTube downloads deleted.
3. Done for sources that fill the store - pre-buffering replaces subscription downloads: a subscription
   episode filled into the store gets `downloads.expires` (schema step 15) = complete + 14 days, and
   goes 3 days after it was watched at the latest (SFDownloads expirePrebuffers: at start and every
   3 h). Expired = dismissed (not fetched again), its bytes plain buffer (evicted when room is needed).
   "Behalten" keeps it; "Herunterladen" on it makes it a download (no expiry, nothing loaded again).
4. Mediatheks through SFMediaProxy:
   a. Done - progressive files (ZDF, ARD, CCC): src/Library/SFMediaProxy - the player reads a local
      URL, stored ranges come from disk, each gap from the source in one streamed range request
      (SFCurlStream: curl for every host, backpressure from the reader); track key
      "file:<item>:<host+path hash>:<length>", manifest kind "file" (+ subtitles as tracks). A complete
      item plays from the store without its source (SFDownloads localCopyOf:); the download worker fills
      generically (no ffmpeg) when an app has no fillItem: but resolves to a progressive file.
      Loopback sources stay unproxied (local already; tests opt in with SOFA_PROXY_LOOPBACK).
   b. Done - HLS (ORF): SFMediaProxy+HLS.m rewrites the playlists (resources as tracks
      "hls:<item>:<hash>", keys included; VOD only stored); a download takes the best variant <= 1080p
      plus the default audio rendition, manifest kind "hls". SFStreamProxy went.
   c. Done - one kind of download (schema step 16): the file downloads' files and thumbnails deleted
      (a subscription episode stays dismissed, a manual one leaves), `downloads.path`/`store` dropped;
      ffmpeg (no longer bundled), the verifier, repairs, orphan reaping and the ytdl-sub migration went.
      A source that neither fills (fillItem:) nor resolves to a file/HLS the proxy serves cannot be
      downloaded.
5. UI:
   a. Done - tile mark: "geladen" for bytes on disk without a download the user keeps (buffer, a
      pre-buffered episode); the download marks as before (SFTileStatus; the store's per-item byte sums
      are readable from any thread without its queue).
   b. Done - "Herunterladen" on a partly loaded video says what is missing ("noch 340 MB", exact from
      the manifest's track lengths; SFMediaStore missingBytesOf:, SFDownloads download:told:).
   c. Timeline shade of the stored ranges - exact only, never a proportional guess (user 2026-11-08:
      "exakt, ORF zuerst"). Done for HLS (ORF): SFMediaProxy records each VOD media playlist's segments
      with their #EXTINF times and what each needs (segment, key, init section); the playlists the
      player reads resources of are the active ones (not every variant lavf parsed), a time is stored
      when every active playlist's segment is complete (video and audio rendition). The player asks
      every 3 s while the bar shows, off the main thread (SFPlayerScreen+Stored.m). Done for YouTube:
      the engine hands over its tracks' segment indexes (engine call `index`: WebM Cues / MP4 sidx,
      byte offset -> ms, once their init segments arrived); Sofa keeps them in the manifest ("index",
      by track identity - stored sessions have them offline) and counts a span when its bytes are all
      on disk, video and audio both (SFYTTimeline, SFYTEngine+Timeline.m; app hook storedRangesOf:).
      Done for the mediatheks' progressive MP4 files: SFMP4Index reads the moov's sample tables from
      the store (stco/co64, stsc, stsz, stts, an edit list's start) - every audio/video chunk's byte and
      time span; parsed once per session when the moov is on disk (faststart or at the end).
