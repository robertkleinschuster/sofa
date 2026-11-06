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

## First contact with youtube.com (measured 2026-11-06, `SOFA_YT_LIVE=1 SOFA_YT_FILES=live-engine.test.ts`)

Works in the page: the engine injects and starts, youtubei.js' session takes the page's context
(`browser=Firefox/153.0`), BotGuard attests in the real document (~1 s), the player request
answers, SABR streams from the page (62 s of 1080p VP9 + Opus). No consent page in this profile.

Measured walls and their fixes:

- Trusted Types: youtube.com enforces `require-trusted-types-for 'script'`; `script.src = string`
  and `new Function(string)` are blocked and raise a `securitypolicyviolation` the page can report.
  A policy of the engine's own is allowed: `web/trusted.ts` (interpreter URL limited to
  www.google.com, player code); the engine logs every violation (`csp:` lines), the live test
  requires none.
- `fetch` must not be called with another `this` in the browser: SabrStream gets a wrapper.
- Headless screen 1366x768 by default: `MOZ_HEADLESS_WIDTH/HEIGHT` = the TV's 1920x1080.

Open - **stream protection rejects the engine's PO token** (`sps=3` after ~60 s, also after a fresh
attestation), as it does the jsdom sidecar's. What BotGuard sees of this browser differs from a
user's Firefox in two measured points:

- `navigator.webdriver === true` while the remote agent (BiDi) runs - Firefox hardwires it
  (`Navigator::Webdriver()`), no pref changes it (`dom.webdriver.enabled` measured: no effect).
- No WebGL in headless mode (`getContext('webgl')` is null).

Not yet known which of these (or something else, e.g. the visitor of the player request vs. the
page's cookie) causes the rejection. Next: find out which signal it is, then fix it natively (for
`webdriver` a documented patch in the firefox-x11 port; for WebGL a display instead of headless).

## Still open

- Live HLS: today mpv fetches segments from googlevideo itself - a second client. Segments go
  through the engine (`read`-like) so every request is the browser's.
