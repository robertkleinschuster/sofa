# sofa-yt — YouTube SABR sidecar

A long-lived node process that looks like YouTube's own web player (one persistent Innertube session,
WEB-client player requests with a BotGuard/WebPO token, SABR streaming) and hands mpv plain local HTTP
files with Range support. It replaces yt-dlp for VOD playback on IPs where yt-dlp gets "Sign in to
confirm you're not a bot"; lives and post-live DVR recordings are served as a local HLS playlist from
the same session (see "Lives"). yt-dlp stays the fallback.

## Layout

| Path | What |
|---|---|
| `res/sofa-yt/main.ts` | entry point (CLI, wiring, stdin watchdog) |
| `res/sofa-yt/lib/app.ts` | HTTP API, session registry, idle expiry |
| `res/sofa-yt/lib/session.ts` | playback session: demands, SABR scheduling, pacing, eviction, Range serving |
| `res/sofa-yt/lib/vfile.ts` | sparse virtual file per track (segments placed by absolute byte offset) |
| `res/sofa-yt/lib/mediaindex.ts` | WebM Cues / MP4 sidx parser (byte offset -> media time) |
| `res/sofa-yt/lib/hls.ts` | lives / post-live DVR: manifest URL preparation (n, PO token), variant choice, playlist proxy session |
| `res/sofa-yt/lib/sabrpump.ts` | one googlevideo `SabrStream` run, segments with their byte position |
| `res/sofa-yt/lib/youtube.ts` | Innertube session, player requests, decipher, per-video cache, budget |
| `res/sofa-yt/lib/webpo.ts` | in-process BotGuard (bgutils-js + jsdom) WebPO minter |
| `res/sofa-yt/lib/formats.ts` | video/audio/subtitle choice (same rules as `res/ytresolver.py`) |
| `res/sofa-yt/lib/breaker.ts` | bot-check circuit breaker, file shared with ytresolver.py |
| `res/sofa-yt/lib/subs.ts` | captions -> WebVTT |
| `res/sofa-yt/lib/ytraw.ts` | types of the raw Innertube player response we read + its one narrowing boundary (`asPlayerResponse`) |
| `res/sofa-yt/lib/json.ts`, `errors.ts` | narrowing helpers for untrusted JSON / caught values |
| `res/sofa-yt/tsconfig.json` | type checking only (strict); not shipped |
| `res/sofa-yt/package.json`, `package-lock.json` | exact dependency pins (googlevideo 5.0.1, youtubei.js 18.3.0, bgutils-js 4.0.3, jsdom 25.0.1; dev only: typescript 6.0.3, @types/node 26.6.5, @types/jsdom 21.1.7) |
| `tools/fetch-sofa-yt` | `npm ci --omit=dev` (lockfile integrity, no install scripts) -> `build/vendor/sofa-yt/node_modules` (what ships) |
| `tools/test-sofa-yt` | `tsc` type check first (failing types = failing suite), then the tests (offline; `SOFA_YT_LIVE=1` adds the live smoke test) |
| `tests/sofa-yt/` | tests + fixtures (init segments, trimmed player responses, recorded SABR segment table, a recorded live response + HLS playlists) |

`make` installs the dependencies when the lockfile changed and copies sources + `node_modules` to
`Contents/Resources/sofa-yt` of both `Sofa.app` and `SofaDev.app`. `tools/make-release` strips source maps
/ type declarations, drops stale source files and runs `main.ts --check` with the bundled
`Contents/Runtime/bin/node`. `node_modules` is never committed.

## TypeScript

The sidecar is strict TypeScript that node runs **directly**: node 26 strips the type annotations when it
loads a `.ts` file (built-in type stripping, on by default since node 22.18 / 23.6 - no flag; node does
not do this inside `node_modules`, which our sources never are). No build step, no emitted JavaScript,
no extra runtime in the bundle: the shipped files are the reviewed sources, stack traces point at real
lines, and the bundled node stays the only runtime. Consequences:

- only erasable syntax (`erasableSyntaxOnly`): no `enum`, no parameter properties, no namespaces;
  type-only imports are written `import type` (`verbatimModuleSyntax`); relative imports name the `.ts`
  file (`allowImportingTsExtensions`).
- type checking is a separate, mandatory step: `tools/test-sofa-yt` runs `tsc -p res/sofa-yt`
  (`strict`, `noUncheckedIndexedAccess`, unused locals/parameters) over the sources and the tests
  before any test. `typescript` and the `@types/*` packages are exact-pinned **devDependencies** in the
  same lockfile, installed with `npm ci --ignore-scripts` into `build/vendor/sofa-yt-dev` (reachable for
  tsc and editors through the git-ignored symlink `res/sofa-yt/node_modules`); the bundle gets
  `npm ci --omit=dev`, so no compiler ships.
- typescript 6.0.x is the newest usable compiler: 7.x is the native (Go) port whose darwin-x64 binary
  needs macOS 12 (`_clock_gettime`), 6.0 is plain JavaScript on the bundled node.
- untrusted JSON (player responses, state files, BotGuard answers) is parsed into `unknown` and narrowed
  (`json.ts`, `ytraw.ts asPlayerResponse`); the library types (youtubei.js, googlevideo, bgutils-js,
  @types/jsdom) are used as shipped. No `any` in our code.
- the tests are TypeScript too (`tests/sofa-yt/*.test.ts`, run by `node --test`); they load the modules
  from the assembled run dir (shipped `node_modules`) and take the types from the sources
  (`helpers.ts mod()`).

## Running

```
node Contents/Resources/sofa-yt/main.ts --port 0 --state <dir> --block-file <yt-dlp-cache>/youtube-block.json
```

| Option | Default | |
|---|---|---|
| `--port N` | 0 | 0 = ephemeral; the port is reported in the ready line |
| `--state DIR` | required | persistent: `ytjs-cache/` (visitorData, user agent, player.js), `players/<id>.json` (deciphered player responses until expiry), `player-requests.json` (budget) |
| `--block-file PATH` | `<state>/youtube-block.json` | bot-check breaker, same file + format as ytresolver.py: `{"until": epoch, "backoff": secs}` |
| `--ahead-low S` / `--ahead-high S` | 30 / 90 | pacing window in seconds of media ahead of the reader |
| `--max-player-requests N`, `--budget-window S`, `--budget-file P` | 60 / 3600 / state | hard cap on player requests (safety net against loops; persisted) |
| `--no-warm` (or env `SOFA_NO_WARMUP`) | | skip the startup warm-up (Innertube session + BotGuard; no player request either way) |
| `--debug` (or env `SOFA_YT_DEBUG=1`) | | log every request, segment, SABR run |
| `--check` | | load all dependencies and exit 0 (bundle self-test, no network) |

- stdout: exactly one line `{"ready":true,"port":N}` once listening on 127.0.0.1. Nothing else ever goes to
  stdout (library `console.log` is redirected).
- stderr: log lines prefixed `sofa-yt:`.
- The process exits when its stdin reaches EOF: the parent must keep a pipe open (no orphans). It also
  exits on SIGTERM/SIGINT, and with code 70 on an uncaught exception (restart it).
- Startup: ready line after ~0.2 s; the warm-up (Innertube session ~1 s, BotGuard ~1 s, no player
  request) runs after it. `/open` waits for it when needed. RSS after warm-up ~170 MB (jsdom/BotGuard).
  `main.ts --check` (loads every dependency) takes ~1.5-4 s.

## HTTP API (127.0.0.1 only)

Every response carries `Connection: close`: on OS X 10.9 node's server misses requests that arrive
on an idle kept-alive socket until its keep-alive timeout closes it (measured 2.5-27 s stalls). Clients
must not rely on keep-alive (libcurl/NSURLSession handle `Connection: close` transparently).

### `GET /health`
```json
{"ok":true,"session":"ready|pending|error","poToken":"ready|pending|error","sessions":1,
 "blocked_until":0,"rssMB":180,"bufferedMB":12.3,"fetched":{"videoSec":154,"MB":21.3,"sabrRuns":4}}
```
`fetched` = media pulled from YouTube by this process (video seconds, MB of video+audio, SABR runs).

### `GET /open?v=<id>&bg=0|1&maxHeight=1080&lang=de&start=<sec>&prefetch=0|1`
- `bg=1`: background (preload/download): no player request while the breaker is open; `prefetch`
  defaults to 0.
- `lang`: the user's language for the automatic subtitle translation (default `de`). Audio choice
  ignores it: the original track always wins.
- `start`: resume position; with `prefetch=1` (default for `bg=0`) SABR starts pulling there right away.

Success (keys of ytresolver's `dash` dict + metadata; all URLs local):
```json
{"id":"OzCYsIrrRyw","sid":"04ed25455bf7fa40","title":"...","duration":2134,"live":false,
 "expires":1793879547,"formats":30,
 "video":"http://127.0.0.1:N/s/<sid>/video","audio":"http://127.0.0.1:N/s/<sid>/audio/251",
 "height":1080,"fps":25,"vcodec":"vp9","acodec":"opus","alang":"de","vitag":248,"aitag":251,
 "audios":[{"lang":"en","url":".../s/<sid>/audio/251-en.4","original":true,"dubbed":false,"described":false,
            "name":"English original","itag":251,"acodec":"opus"}],
 "subs":[{"lang":"de","url":".../s/<sid>/subs/a-de.vtt","kind":"auto","name":"German (auto-generated)"}],
 "cached":false,"secs":2.07,"blocked_until":0}
```
- `vcodec`: `vp9` / `av01` / `avc1`; `acodec`: `opus` / `mp4a`; `alang` may be `null` (single-language
  videos often carry no language tag).
- `audios`: only with >= 2 languages, best format per language, original first; `audio` == the URL of the
  first entry then. `subs`: manual tracks, the automatic track of the spoken language (`auto`), and the
  automatic translation into `lang` (`translated`) only when no real track in `lang` exists and the
  video is not spoken in it.
- `cached`: the player response came from the cache (no player request). `reused`: an existing healthy
  session of the same video/choice was returned (its buffer is kept).

Live / post-live DVR success (no `video`/`audio`: one muxed HLS stream):
```json
{"id":"LuKwFajn37U","sid":"d38f66f1757b3b63","title":"DW News livestream | ...","duration":0,
 "live":true,"postLiveDvr":false,"expires":1793888018,
 "hls":"http://127.0.0.1:N/s/<sid>/live.m3u8","height":1080,"fps":60,"vcodec":"avc1","acodec":"mp4a",
 "vitag":301,"audios":[],"subs":[],"endscreen":[],"cached":false,"secs":0.82,"blocked_until":0}
```
Post-live DVR (an ended broadcast YouTube still serves from its live chunks): `live:false`,
`postLiveDvr:true`, `duration` = the recording's length, seekable like a VOD. `bg=1` opens of either
answer `{"error":"live"|"post-live","live":true}` (downloads stay with yt-dlp).

Failure (HTTP 200):
```json
{"id":"...","error":"Sign in to confirm you're not a bot","bot":true,"blocked_until":1793880000}
{"id":"...","error":"upcoming","live":true,"upcoming":true,"startTime":1793900000,"bot":false,"blocked_until":0}
```
`error` texts: YouTube's playability reason (e.g. `Video unavailable`), `upcoming` (scheduled live or
premiere; `startTime` epoch seconds or `null`; the answer is reused for 60 s without a request),
`offline` (`LIVE_STREAM_OFFLINE` without a schedule), other errors with `live:true` (no HLS manifest,
`HLS manifest unavailable: ...`, decipher failed: fall back to yt-dlp), `... (paused, no request sent)` (bg while blocked),
`player-request budget exhausted ...`, `PO token unavailable: ...`, `YouTube session unavailable: ...`,
`no usable video/audio format`, `invalid video ID` (HTTP 400).

### `GET|HEAD /s/<sid>/video`, `/s/<sid>/audio` (main audio), `/s/<sid>/audio/<key>`
A file of exactly `contentLength` bytes, byte-identical to googlevideo's file. `200` without Range,
`206` + `Content-Range` with `bytes=a-b`, `a-`, `-n`; `416` beyond the end. Missing bytes are waited for
(25 s per gap, then the response ends early so the client reconnects). `404` unknown/expired session,
`503` + JSON when the session failed (3 SABR runs in a row failed before delivering anything).

### `GET|HEAD /s/<sid>/live.m3u8` (live sessions)
The chosen variant's media playlist, fetched fresh from googlevideo on every request (1 s micro cache),
all URIs absolute (mpv loads the TS segments directly from googlevideo). `502` + JSON when one fetch
failed (mpv retries), `503` once 3 fetches in a row failed (session failed). `/s/<sid>/status` of a live
session: `{"kind":"hls","live":true,"ended":false,"failures":0,"renewals":0,"variant":{...},...}` -
`ended` = upstream sent `#EXT-X-ENDLIST` (the broadcast is over).

### `GET /s/<sid>/subs/<key>.vtt`
WebVTT, fetched on demand from timedtext (`fmt=vtt`, PO token for `exp=xpe` URLs), cached per session;
`502` + JSON on failure. Keys: `m-<lang>` manual, `a-<lang>` automatic, `t-<lang>` translated.

### `GET /s/<sid>/status`, `GET /close?sid=<sid>`
Diagnostics (tracks, demands, pumps, fetched media); `/close` frees a session at once. Sessions also
expire after 10 min without reads (and no open response); at most 4 sessions exist (least recently
used without readers is closed).

### `GET /pot?binding=<content binding>`
PO token for the yt-dlp fallback: `{"poToken": "..."}` minted by this process's BotGuard (the same
minter as the sidecar's own player requests), so both YouTube paths are one web identity. Called by
Sofa's yt-dlp provider plugin (`res/yt-dlp-plugins/.../getpot_sofa.py`, provider "Sofa"), which gets
the sidecar's address per request (`SOFA_POT_URL`). 400 without a binding, 503 when the minter is
unavailable (yt-dlp then goes on without a token). No YouTube request unless the minter has to be
(re)created (integrity token, ~every 12 h).

## How it works

**One web identity.** `Innertube.create` with a disk cache keeps visitorData, the user agent (set to
bgutils' browser UA so BotGuard and Innertube look like the same browser) and player.js across restarts.
Player requests are WEB client with `signatureTimestamp` of the pinned player and a video-bound PO token
(`serviceIntegrityDimensions.poToken`). The SABR URL's n-parameter is deciphered **with the same player
object right after the request** (YouTube A/B-serves several player.js versions; a mismatch = SABR 403);
only the deciphered URL is cached (`players/<id>.json`) and reused until 15 min before `expire`, so
reopening, seeking and restarting SABR never cost a player request. If SABR asks for a reload or the URL
expired mid-playback, googlevideo calls back and one player request with `reloadPlaybackContext` is made.

**Virtual files.** Every SABR segment carries its byte offset (`MediaHeader.segmentByteRangeStart`) and
length; the init segment covers `[0, indexRange.end]` (header + Cues/sidx). Verified on live data: SABR
segments are exactly the Cues spans (`tests/sofa-yt/fixtures/OzCYsIrrRyw-sabr-segments.json`). Each track
is a sparse file of `contentLength` bytes; offset -> time comes from the stored segment or the parsed
index (proportional estimate only before the init segment arrived).

**SABR runs ("pumps").** googlevideo's `SabrStream` pulls from one `playerTimeMs`. A run is started for
a demand that is neither buffered nor covered by a running run (seek = new run at the cue time of the
requested offset), or when less than `--ahead-low` is buffered ahead of a reader; it is stopped once a
reader has `--ahead-high` (or 96 MB) ahead (pacing), or 1 s after nobody needs it. SABR has no
video-only mode: video runs carry the audio track read most recently. Another language (a different
`/audio/<key>` URL, e.g. mpv `audio-add`) gets audio-only runs, so switching works mid-playback; the next
video run then carries that language and the audio-only run becomes redundant. Pre-minted PO tokens are
passed in (a seek start without one gets SPS 3 + a ~3 s backoff); `maxRetries` is 2. Max 3 concurrent
runs and 12 starts per minute per session; 3 consecutive failed runs fail the session (no retry loops).

googlevideo's public output is two byte streams without positions; `sabrpump.ts` pairs each chunk with
the MediaHeader from `Track#recordCompletedSegment` (called synchronously after the enqueue in
googlevideo 5.0.1) and verifies length/position. Re-check that hook when bumping googlevideo.

**Memory.** Per track: init + index forever, media within 30 s behind every reader, the pacing window
ahead, hard caps 160 MB video / 24 MB audio. A 1080p VP9 session holds roughly 40 MB at the default
window. Plus ~170 MB for node + jsdom/BotGuard (measured RSS after warm-up).

**Breaker.** Same file and rules as ytresolver.py (5 min doubling to 1 h, reset by a success; only
background requests are held back). The file is re-read on every check.

## Lives

### Research (2026-11-05; googlevideo 5.0.1, youtubei.js 18.3.0, yt-dlp master, FreeTube, invidious-companion)

Recorded with one WEB player request for DW News' 24/7 live `LuKwFajn37U` (found via one search request
with the `live` filter, no player request), same identity/payload as `/open`
(`tests/sofa-yt/fixtures/player-LuKwFajn37U-live.json`, trimmed and sanitized):

- `playabilityStatus.status` `OK`, `liveStreamability.liveStreamabilityRenderer` (`broadcastId`,
  `pollDelayMs`); `videoDetails.isLive`, `isLiveDvrEnabled`, `lengthSeconds` `0`; `heartbeatParams`.
- `streamingData`: `hlsManifestUrl`, `serverAbrStreamingUrl` (`source=yt_live_broadcast`),
  `adaptiveFormats` (299/303 1080p60 ... 140 audio) **without** `contentLength`, `indexRange`,
  `initRange` (only `targetDurationSec` 5), `expiresInSeconds` 21540. **No `dashManifestUrl`** for WEB.
- The HLS URL is path-style (`.../hls_variant/expire/<t>/.../n/<challenge>/.../playlist_type/DVR/.../file/index.m3u8`).
  `n` is **in the path** and not in `sparams`. Measured: master and variant playlists load either way,
  but every segment answers **403** unless `n` was transformed with the player whose
  `signatureTimestamp` went into the request (`player.decipher` on a dummy `?n=` URL, like the SABR
  URL). The transformed `n` and an appended `/pot/<PO token>` propagate into every variant and segment
  URL; segments load with and without the token.
- Master: 6 muxed TS variants (itags 91-94 144p-480p, 300 720p60, 301 1080p60; H.264 + AAC, no separate
  audio group). Variant playlist: 6 x 5 s (`playlist_duration/30`), `EXT-X-PROGRAM-DATE-TIME`,
  `MEDIA-SEQUENCE`, `DISCONTINUITY-SEQUENCE`.
- yt-dlp (`extractor/youtube/_video.py`) does exactly this for web clients: `get_manifest_n_challenge`
  (`/n/([^/]+)/` in the path) -> solved n replaced in the path, only uses the manifest if solved; PO token
  appended as `/pot/<token>` before `/file/index.m3u8` (GVS PO token policy for HLS: recommended, not
  required); `isPostLiveDvr` -> `post_live`; `LIVE_STREAM_OFFLINE` + `isUpcoming` -> upcoming.
- FreeTube (`helpers/api/local.js`): deciphers `hls_manifest_url` / `dash_manifest_url` with the player
  (path segments converted to query and back) and appends `/pot/`; refetches `streamingData` with MWEB
  when a live/post-live response lacks `hlsManifestUrl`; keeps the start time for `LIVE_STREAM_OFFLINE`
  (upcoming). invidious-companion only proxies `videoplayback` (no manifest handling).
- googlevideo 5.0.1 `SabrStream` **does** support live SABR: `isBroadcast` from `source=yt_live_broadcast`,
  start at the live edge (`LIVE_EDGE_SENTINEL_MS`) unless `isPostLiveDvr`, `LIVE_METADATA` parts
  (`liveMetadataUpdate`, broadcast id check), heartbeat callback (`HEARTBEAT_CHECK_TYPE_LIVE_STREAM_STATUS`),
  stall = end of stream, no initialization formats (segments are self-initializing; duplicate inits
  stripped). Its output is a growing byte stream per track with **no byte offsets and no length**.
- youtubei.js refuses to generate DASH manifests for lives (`MediaInfo.toDash`); post-live DVR formats
  lack index/init ranges (`StreamingInfo.getFormatGroupings`).

### Decision: the web player response's HLS manifest, proxied

Live SABR would need a second serving model (no `contentLength`/Cues -> no virtual files; mpv would get
two endless, unseekable streams to sync, or we would generate an HLS/DASH playlist from SABR segments
ourselves, plus heartbeats and sequence/DVR-window bookkeeping) - a reimplementation of what YouTube's HLS
manifest already is. The HLS manifest comes from the same WEB player request (one request, same
identity, PO-token-bound like the web player's media requests), is one muxed stream mpv (and
AVFoundation) plays natively, and the DVR window/sequence numbers are YouTube's. The real desktop web
player uses SABR for lives; Safari's web player uses this HLS manifest - so the requests still look like
a YouTube web player. Live SABR stays an option if YouTube ever drops HLS for WEB.

### How it works

- `youtube.ts` classifies the response (`classifyPlayer`): `live` (`isLive`) and `postlive`
  (`isPostLiveDvr`) -> `liveInfo()`: `hlsManifestUrl` with the path `n` solved by the pinned player and
  `/pot/<token>` (the request's video-bound token) appended (`hls.ts prepareManifestUrl`); cached like VOD
  responses (`players/<id>.json`, until 15 min before the path `expire`). No HLS manifest / unsolved n ->
  `live:true` error (yt-dlp fallback). `upcoming` (`isUpcoming`, or `LIVE_STREAM_OFFLINE` with a
  `scheduledStartTime` in the offline slate; premieres: `liveBroadcastDetails.startTimestamp`) and
  `offline` throw before anything is cached; the answer is reused for 60 s (no request storm from
  repeated clicks), the breaker counts it as a success (it was no bot check).
- `/open` (`app.ts openLive`) creates a `LiveSession`, loads the master playlist right away (an unusable
  URL fails `/open`, not mpv; a cached URL that fails is forgotten) and picks the best variant within
  `maxHeight` (height, fps, bandwidth).
- `/s/<sid>/live.m3u8` serves that variant's media playlist, fetched with the session's web headers
  on every mpv reload. Self-healing: 10 min before `expire`, or once on 403/404/410, the manifest URL is
  renewed through `YouTube#refresh` - the same guards as SABR reloads (shared in-flight request, a
  response younger than 5 min is reused, max 2 per 10 min, nothing for background sessions while the
  breaker is open, budget) - and the same itag is chosen again. 5xx/network errors never cost a player
  request. 3 failed fetches in a row fail the session (`503`).
- Sessions share the registry, idle expiry (mpv reloads the playlist every target duration, so a playing
  live never idles) and the 4-session limit with VOD sessions.

### Verified (2026-11-05)
Sidecar `/open` of `LuKwFajn37U`: 1 player request, 0.8 s, 1080p60 itag 301; `mpv --vo=null --ao=null
--length=20 http://127.0.0.1:N/s/<sid>/live.m3u8` played 20 s of H.264 1080p60 + AAC, 4 playlist reloads,
0 failures. Not verifiable on a given day without a matching stream: post-live DVR and upcoming answers
(covered by synthetic fixtures in `unit-live.test.ts` built from the recorded live response).

## Integration notes for Sofa (ObjC)

- Spawn with the bundled node, stdin = a pipe Sofa keeps open, read the first stdout line (timeout ~10 s);
  restart on exit with backoff. Pass `--state` in Sofa's cache dir and `--block-file` = ytresolver's
  `youtube-block.json`.
- `/open` cost: cached ~10 ms; uncached ~2-4 s (player request ~0.2 s + PO mint + decipher; the first
  call after start also waits for the warm-up). First video frame ~2.3 s after mpv started (live test).
- mpv: `video` as the file, `--audio-file=<audio>`; other languages via `audio-add <url>`;
  subtitles via `sub-add <url>`. The bundled mpv has no ytdl hook - nothing to disable. mpv reads ahead
  into its own cache; keep `demuxer-max-bytes` / `cache-secs` moderate, every byte mpv buffers is a byte
  pulled from YouTube. When resuming at `start`, mpv first probes the first cluster (lavf
  `probesize`/`analyzeduration`), which costs a short SABR run at 0; lowering
  `demuxer-lavf-analyzeduration` reduces that.
- Failure modes: `/open` error JSON (fall back to yt-dlp unless `bot` and the user did not ask); media
  URLs ending early (mpv reconnects) or `503` (session failed: reopen once, then fall back); `404` =
  session expired (reopen: the cached player response makes this cheap). URLs die with the process.
- Lives (`ytlive:` resolver) and videos that turn out to be live (`yt:` resolver) go to the sidecar first:
  an `hls` answer is opened as is (`SFSetMPVSource` flags `sabr`, `hls`, `live`, `sid`; no `video`/`audio`
  pair); bot check -> message, no yt-dlp request; `upcoming` -> "Dieser Livestream beginnt ..." (with the
  start time), `offline` -> message, both without yt-dlp; any other error -> yt-dlp (`live:YES`).
- mpv reaching the end of a live playlist: SFPlayerScreen asks `/s/<sid>/status`; `ended` -> normal end,
  otherwise the SABR failure path (reopen once via the sidecar, then yt-dlp). The stall watchdog and the
  sidecar-exit notification apply to lives like to VODs.
