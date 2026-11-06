# YouTube engine in Firefox — target design (2026-11-06)

Replaces the Node sidecar (`docs/sofa-yt.md`). Goals and the decision: NOTES.md "YouTube client
goals" and "Architecture rule" (built as if from scratch). In short: every request to YouTube comes
from one real browser; Sofa needs two runtimes, itself and Firefox. Node is only used at build time.

## Processes

```
Sofa.app (ObjC)                                    Firefox 153 ESR (headless, own profile)
├─ UI, library, downloads, follows                 └─ one hidden tab on https://www.youtube.com/
├─ SFYTEngine: starts/stops Firefox,                  └─ engine.js (bundled TypeScript):
│   WebDriver BiDi client (libcurl WebSocket)  ◄──►     youtubei.js (web build), googlevideo SABR,
├─ loopback HTTP server (Range) for mpv/ffmpeg ──┐      BotGuard/WebPO in the real DOM,
├─ libmpv, ffmpeg                                │      sessions, pacing, segment files
└─ breaker file (bot-check pause)                └── bytes pulled from the page per request
```

- **Firefox is the identity.** It sends its own user agent, TLS (NSS), HTTP/2/3 and cookies, and
  its profile keeps them (`~/Library/Application Support/Sofa/firefox-profile`). No header,
  cookie or TLS emulation is left: `identity.ts`, `transport.ts` and jsdom go away.
- **The page is a real youtube.com document.** Same-origin requests, like YouTube's own player.
  The engine is injected with BiDi `script.addPreloadScript` (no extension, no file access).
- **Sofa owns the local plumbing.** mpv and ffmpeg read `http://127.0.0.1:<port>/s/<sid>/<track>`
  from Sofa's loopback server (as today's ORF proxy), which pulls the bytes from the page.

## Engine API (page side, `globalThis.sofaEngine`, called with BiDi `script.callFunction`)

Injection: `script.addPreloadScript` on the engine tab with the bundle as the function body and a
BiDi channel argument; the function hands the channel to `connect()`. Every call answers a `Reply`:
`{ok: true, value}` or `{ok: false, status, body}` - the status and JSON body the node sidecar
answers over HTTP, so Sofa's handling stays the same.

| Call | Node sidecar (HTTP) | Value |
|---|---|---|
| `start({base, block, maxPlayerRequests?, budgetWindowS?, aheadLowS?, aheadHighS?, debug?})` | process start | `{userAgent}`; 412 off youtube.com |
| `open({v, bg, maxHeight, lang, start, prefetch, vcodec, acodec})` | `GET /open` | `VodAnswer`/`LiveAnswer`/`OpenFailure`, URLs under `base` |
| `read(sid, track, offset, maxBytes)` | Range GET on a track | `{total, mimeType, data: base64}` (at most 8 MB); waits for SABR like a reader |
| `playlist(sid)` | `GET /s/<sid>/live.m3u8` | HLS media playlist |
| `subtitles(sid, key)` | `GET /s/<sid>/subs/<key>.vtt` | WebVTT text |
| `status(sid)` | `GET /s/<sid>/status` | diagnostics |
| `close(sid)` | `GET /close` | closed or not |
| `innertube(endpoint, body, {bg})` | `POST /yt/<endpoint>` | raw InnerTube JSON |
| `suggest(q)` | `GET /suggest` | suggestions |
| `block(state)` | (breaker file) | Sofa's breaker file changed |
| `health()` | `GET /health` | libraries, user agent, origin, on youtube.com, engine counters |

Events over the channel (one JSON string each): `ready {userAgent, url}` once per document the
preload runs in (Sofa matches the URL; a transient initial document reports `url: ""`), `log {line}`,
`block {state}` when a bot check opens the breaker or a success closes it - Sofa writes the file.

The bot-check pause stays Sofa's file (`SFYTBreaker`): the engine's breaker keeps its state in memory,
seeded by `start({block})` and `block()`, and reports every change.

## Module mapping (res/sofa-yt)

| Module | Role |
|---|---|
| `lib/engine.ts` | the core: session registry, open/read/close, subtitles, InnerTube, suggestions, health; `EngineError` |
| `lib/pump.ts` | SABR pump factory (pre-minted video-bound token per video, renewal on rejection, reload path) |
| `lib/session.ts`, `vfile.ts`, `mediaindex.ts`, `formats.ts`, `sabrpump.ts`, `hls.ts`, `subs.ts`, `ytraw.ts`, `json.ts`, `errors.ts`, `bytes.ts`, `timers.ts`, `log.ts` | runtime-neutral, shared |
| `lib/youtube.ts`, `webpo.ts`, `botguard.ts`, `breaker.ts`, `store.ts` | runtime-neutral; the environment comes in as `SessionFactory`, `AttestEnv`, `BlockStore`, `StateStore` |
| `web/engine.ts`, `web/page.ts`, `web/pagesession.ts`, `web/pagebotguard.ts` | browser: API object, page ytcfg, youtubei.js web build with the page's context, BotGuard in the document; state in the profile's localStorage (`WebStorageStore`) |
| `lib/app.ts`, `main.ts`, `lib/identity.ts`, `lib/transport.ts`, `lib/nodesession.ts`, `lib/nodebotguard.ts`, `lib/filestore.ts` | node sidecar only; removed in step 5 |

## Build and dependencies

- `res/sofa-yt/web/engine.ts` is the bundle entry; `esbuild-wasm` (exact pin, devDependency, runs
  on 10.9 - the native esbuild needs macOS 10.15) writes `build/sofa-yt-web/engine.js`.
- Port: `firefox-x11` in `depends_lib`; `nodejs26` moves to `depends_build`.
- Tests: the module unit tests keep running under Node against the same modules; a Firefox test
  injects the bundle as Sofa does (preload script + channel) into a local page (offline).

## Open points for step 4 (first contact with youtube.com, measured then - not guessed now)

- CSP / Trusted Types of youtube.com: the engine's `new Function` (player n/sig) and the interpreter
  `<script>` must pass in the page realm; if not, a BiDi sandbox realm or a Trusted Types policy.
- Live HLS: today mpv fetches segments from googlevideo itself - a second client. Segments go
  through the engine (`read`-like) so every request is the browser's.
- CORS of the googlevideo / suggest / manifest requests from the page (YouTube's own player and
  search box make the same ones).

## Feasibility (measured 2026-11-06, no YouTube request)

- Headless Firefox 153 with BiDi on 10.9: page load + script 0.4 s; UA "Macintosh; Intel Mac OS X
  10.15; rv:153.0".
- Page -> client over BiDi: 64 MB in 1.7 s (37 MB/s; 1080p needs ~1 MB/s).
- Bundle (youtubei.js web + googlevideo + bgutils): 790 KB minified, built in 5 s; loads in
  Firefox with Innertube, SabrStream, BotGuardClient and WebPoMinter available.

## Migration steps

1. Engine bundle + Firefox smoke test in the repo (this document, `web/engine.ts`). Done.
2. Node-only seams out of the moved modules; engine core (`lib/engine.ts`) and the `sofaEngine` API
   over it, tested in node (core) and headless Firefox (injection, channel, API). Done.
3. Sofa: `SFYTEngine` (Firefox lifecycle, BiDi over libcurl) + loopback server; replaces `SFYTSabr`.
4. First real request through Firefox; playback, downloads, follows, lives switch over.
5. Remove the Node sidecar, jsdom, the runtime Node in the bundle; port dependencies updated.
