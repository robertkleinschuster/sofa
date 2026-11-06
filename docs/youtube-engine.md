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

| Call | Today (sidecar HTTP) | Returns |
|---|---|---|
| `open(videoId, {bg, maxHeight, lang, start, vcodec, acodec})` | `GET /open` | same JSON as `VodAnswer`/`LiveAnswer`/`OpenFailure`, URLs left to Sofa |
| `read(sid, track, offset, maxBytes)` | Range GET on a track | `{total, data: base64}`; waits for SABR like a reader does today |
| `close(sid)` | `GET /close` | - |
| `innertube(endpoint, body, {bg})` | `POST /yt/<endpoint>` | raw InnerTube JSON |
| `suggest(q)` | `GET /suggest` | suggestions |
| `subtitles(sid, lang)` | `GET /s/<sid>/subs/...` | WebVTT text |
| `health()` | `GET /health` | session/PO token state, counters |

The bot-check pause stays Sofa's (`SFYTBreaker`, shared file): Sofa passes `blockedUntil` with each
background call; the engine reports a bot check in its answer (`bot: true`) and Sofa writes the file.

## Module mapping (res/sofa-yt/lib)

| Module | Fate |
|---|---|
| `session.ts`, `vfile.ts`, `mediaindex.ts`, `formats.ts`, `sabrpump.ts`, `hls.ts`, `subs.ts`, `ytraw.ts`, `json.ts`, `errors.ts` | move to the engine unchanged in logic; Node-only bits (`http.ServerResponse`, `fs`) behind small interfaces |
| `youtube.ts` | engine; state (player cache, budget, visitor) in the page's IndexedDB instead of files |
| `webpo.ts` | engine; BotGuard in the real document instead of jsdom |
| `breaker.ts` | logic to Sofa (it already reads the file); the engine only reports |
| `app.ts` | replaced: API object above + Sofa's loopback server |
| `identity.ts`, `transport.ts`, `main.ts` | removed |

## Build and dependencies

- `res/sofa-yt/web/engine.ts` is the bundle entry; `esbuild-wasm` (exact pin, devDependency, runs
  on 10.9 - the native esbuild needs macOS 10.15) writes `build/sofa-yt-web/engine.js`.
- Port: `firefox-x11` in `depends_lib`; `nodejs26` moves to `depends_build`.
- Tests: the module unit tests keep running under Node against the same modules; a Firefox smoke
  test loads the bundle in headless Firefox (offline, local page).

## Feasibility (measured 2026-11-06, no YouTube request)

- Headless Firefox 153 with BiDi on 10.9: page load + script 0.4 s; UA "Macintosh; Intel Mac OS X
  10.15; rv:153.0".
- Page -> client over BiDi: 64 MB in 1.7 s (37 MB/s; 1080p needs ~1 MB/s).
- Bundle (youtubei.js web + googlevideo + bgutils): 790 KB minified, built in 5 s; loads in
  Firefox with Innertube, SabrStream, BotGuardClient and WebPoMinter available.

## Migration steps

1. Engine bundle + Firefox smoke test in the repo (this document, `web/engine.ts`).
2. Node-only seams out of the moved modules; `sofaEngine` API over them.
3. Sofa: `SFYTEngine` (Firefox lifecycle, BiDi over libcurl) + loopback server; replaces `SFYTSabr`.
4. First real request through Firefox; playback, downloads, follows, lives switch over.
5. Remove the Node sidecar, jsdom, the runtime Node in the bundle; port dependencies updated.
