# sofa-yt — YouTube SABR sidecar

A long-lived node process that looks like YouTube's own web player (one persistent Innertube session,
WEB-client player requests with a BotGuard/WebPO token, SABR streaming) and hands mpv plain local HTTP
files with Range support. It replaces yt-dlp for VOD playback on IPs where yt-dlp gets "Sign in to
confirm you're not a bot"; yt-dlp stays for lives and as fallback.

## Layout

| Path | What |
|---|---|
| `res/sofa-yt/main.mjs` | entry point (CLI, wiring, stdin watchdog) |
| `res/sofa-yt/lib/app.mjs` | HTTP API, session registry, idle expiry |
| `res/sofa-yt/lib/session.mjs` | playback session: demands, SABR scheduling, pacing, eviction, Range serving |
| `res/sofa-yt/lib/vfile.mjs` | sparse virtual file per track (segments placed by absolute byte offset) |
| `res/sofa-yt/lib/mediaindex.mjs` | WebM Cues / MP4 sidx parser (byte offset -> media time) |
| `res/sofa-yt/lib/sabrpump.mjs` | one googlevideo `SabrStream` run, segments with their byte position |
| `res/sofa-yt/lib/youtube.mjs` | Innertube session, player requests, decipher, per-video cache, budget |
| `res/sofa-yt/lib/webpo.mjs` | in-process BotGuard (bgutils-js + jsdom) WebPO minter |
| `res/sofa-yt/lib/formats.mjs` | video/audio/subtitle choice (same rules as `res/ytresolver.py`) |
| `res/sofa-yt/lib/breaker.mjs` | bot-check circuit breaker, file shared with ytresolver.py |
| `res/sofa-yt/lib/subs.mjs` | captions -> WebVTT |
| `res/sofa-yt/package.json`, `package-lock.json` | exact dependency pins (googlevideo 5.0.1, youtubei.js 18.3.0, bgutils-js 4.0.3, jsdom 25.0.1) |
| `tools/fetch-sofa-yt` | `npm ci` (lockfile integrity, no install scripts) -> `build/vendor/sofa-yt/node_modules` |
| `tools/test-sofa-yt` | tests (offline; `SOFA_YT_LIVE=1` adds the live smoke test) |
| `tests/sofa-yt/` | tests + fixtures (init segments, trimmed player responses, recorded SABR segment table) |

`make` installs the dependencies when the lockfile changed and copies sources + `node_modules` to
`Contents/Resources/sofa-yt` of both `Sofa.app` and `SofaDev.app`. `tools/make-release` strips source maps
/ type declarations and runs `main.mjs --check` with the bundled `Contents/Runtime/bin/node`.
`node_modules` is never committed.

## Running

```
node Contents/Resources/sofa-yt/main.mjs --port 0 --state <dir> --block-file <yt-dlp-cache>/youtube-block.json
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
  `main.mjs --check` (loads every dependency) takes ~1.5-4 s.

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

Failure (HTTP 200):
```json
{"id":"...","error":"Sign in to confirm you're not a bot","bot":true,"blocked_until":1793880000}
{"id":"...","error":"live","live":true,"blocked_until":0}
```
`error` texts: YouTube's playability reason (e.g. `Video unavailable`), `upcoming`/`live` (with
`live:true` - play those via yt-dlp), `... (paused, no request sent)` (bg while blocked),
`player-request budget exhausted ...`, `PO token unavailable: ...`, `YouTube session unavailable: ...`,
`no usable video/audio format`, `invalid video ID` (HTTP 400).

### `GET|HEAD /s/<sid>/video`, `/s/<sid>/audio` (main audio), `/s/<sid>/audio/<key>`
A file of exactly `contentLength` bytes, byte-identical to googlevideo's file. `200` without Range,
`206` + `Content-Range` with `bytes=a-b`, `a-`, `-n`; `416` beyond the end. Missing bytes are waited for
(25 s per gap, then the response ends early so the client reconnects). `404` unknown/expired session,
`503` + JSON when the session failed (3 SABR runs in a row failed before delivering anything).

### `GET /s/<sid>/subs/<key>.vtt`
WebVTT, fetched on demand from timedtext (`fmt=vtt`, PO token for `exp=xpe` URLs), cached per session;
`502` + JSON on failure. Keys: `m-<lang>` manual, `a-<lang>` automatic, `t-<lang>` translated.

### `GET /s/<sid>/status`, `GET /close?sid=<sid>`
Diagnostics (tracks, demands, pumps, fetched media); `/close` frees a session at once. Sessions also
expire after 10 min without reads (and no open response); at most 4 sessions exist (least recently
used without readers is closed).

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

googlevideo's public output is two byte streams without positions; `sabrpump.mjs` pairs each chunk with
the MediaHeader from `Track#recordCompletedSegment` (called synchronously after the enqueue in
googlevideo 5.0.1) and verifies length/position. Re-check that hook when bumping googlevideo.

**Memory.** Per track: init + index forever, media within 30 s behind every reader, the pacing window
ahead, hard caps 160 MB video / 24 MB audio. A 1080p VP9 session holds roughly 40 MB at the default
window. Plus ~170 MB for node + jsdom/BotGuard (measured RSS after warm-up).

**Breaker.** Same file and rules as ytresolver.py (5 min doubling to 1 h, reset by a success; only
background requests are held back). The file is re-read on every check.

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
- Lives/upcoming: `{"error":"live","live":true}` - keep yt-dlp for them.
