# Sofa's web API

One API for every client: Sofa im Browser (`pwa/`, docs/pwa.md) and the native apps (iOS:
Swift/SwiftUI/AVKit, Android: Kotlin/Compose/Media3 - not built yet). This page is the prose; the
contract is **`api/openapi.yaml`** (OpenAPI 3.1): every route, request, answer and error code. Answers
as Sofa really gives them: `api/examples/` (recorded by `tools/test-api`, scrubbed).

## How the contract is kept

- **Change order:** the spec first, then the server (`SFWebServer+API`, `SFWebStreams`, ...), then the
  clients. Additive changes keep the API version and add a `features` entry; a breaking change is a new
  version (`/api/v2/...`) while the old one is still served for a while (`api.min`).
- **`tools/test-api`** (part of `tools/test-all`) drives a dev instance (Example app, local media, a
  throwaway certificate on loopback) through every operation - the right calls and the wrong ones that
  have a documented answer - and validates every request and answer against the spec with its own
  strict validator (`tools/lib/api/`, strict TypeScript, no packages: a YAML subset reader and a JSON
  Schema 2020-12 validator that refuses keywords it doesn't implement). During the test objects are
  **closed**: a field the spec doesn't name fails it (clients themselves ignore unknown fields). It also
  fails when an operation is never called, when an error code is missing from the spec or from
  `SFWebErrors.m`, and it checks its own validator first (`selftest.ts`). It records the answers into
  `api/examples/<operation>.<status>.json` - deterministic: git shows a diff only when the API changed.
- Coverage: all 22 operations; 65 of the 87 documented statuses are produced (the rest are server
  faults such as 500/502/503 that a healthy dev instance doesn't give).

## Versions and features

Every route is under `/api/v1/`; the same routes answer under `/api/` (what the PWA uses, kept).
`GET /api/v1/hello` (no auth) answers `{name, version, paired, api: {version, min}, features: [...]}`:
- a client built for API version N works while `api.min <= N <= api.version`; otherwise it asks the
  user to update (the app, or Sofa);
- it asks for **features**, never for Sofa's version: `error-codes`, `client-identity`, `discover`,
  `formats`, `session-formats`, `paused-streams`, `persistent-images`, `tv`, `downloads`, `status`.
  Unknown features are ignored.

An unknown version (`/api/v7/...`) answers 404 `unsupported_version`.

## Errors

Every error answer is `{error, code}`: `error` German, for the viewer (show it as it is); `code` a stable
machine-readable reason (`SFWebErrors.h`, the spec's `ErrorCode`) - branch on it, never on the text.
Codes are never renamed or reused; new ones may appear within a version, so an unknown code is handled
by its HTTP status. Important ones for a client: `not_paired` (401: pair again), `wrong_code` /
`no_pairing_open` / `rate_limited` (pairing), `page_gone` (410: load the start page again),
`stream_gone` (410: play again), `tv_busy` (409: ask, then send with `replace`), `encoder_busy`,
`not_playable`, `drm`.

## Finding Sofa and pairing

Sofa serves port 7443 of its **tailnet addresses only**, TLS with the certificate of its full MagicDNS
name (Let's Encrypt via `tailscale cert`: trusted by every platform, no exception). A device needs
Tailscale. Two ways to the full name:

1. **The pairing link (QR code).** The TV's pairing screen (Einstellungen → Sofa im Browser) shows,
   beside the 6-digit code, a QR code of
   `https://robertkleinschuster.github.io/sofa/pair#host=<full name>:<port>&code=<code>`
   (`SFWebPairScreen`, encoded by `SFQRCode` - ISO 18004, byte mode, ECC M, generated in-process).
   The fragment never leaves the phone. Without an app the link opens the PWA (`pair.html` forwards the
   fragment; the PWA connects and sends the code at once). With a native app installed, the app claims
   the link (below) and pairs the same way.
2. **Typing the short name** ("imac"). A native app asks `GET http://<short>:7443/discover` (plain HTTP,
   tailnet only, no CORS headers, `no-store`) → `{name: "Sofa", host, port, api}`; the PWA uses the
   `/connect` redirect instead (a page can't fetch plain HTTP). Then `https://<host>:<port>`.

`POST /api/v1/pair {code, name, client: {kind: ios|android|web, app?, version?}}` → `{token, device}`.
`client` is optional (absent: the PWA). The TV's device list shows it ("iPhone von Anna (iOS-App 1.2)";
stored in `web_devices.client_kind/client_app/client_version`, schema step 22). The token is sent as
`Authorization: Bearer` on every call; a 401 `not_paired` means the TV removed the device.

## What the native apps will need

**Universal Link (iOS) / App Link (Android) for `/sofa/pair`.** Both are verified on the *host*, at
its root: `https://robertkleinschuster.github.io/.well-known/apple-app-site-association` and
`.../.well-known/assetlinks.json`. This repo's Pages site lives under `/sofa/` and can't serve the
host's root - that is the user-site repository **`robertkleinschuster/robertkleinschuster.github.io`**,
which doesn't exist yet (both URLs answer 404 today, checked 2026-11-26). When the apps are built:
- create that repo with Pages, a `.nojekyll` file (Jekyll drops dot-directories) and
  - `.well-known/apple-app-site-association` (no extension, JSON):
    `{"applinks": {"details": [{"appIDs": ["<TEAMID>.<bundle id>"], "components": [{"/": "/sofa/pair", "#": "*"}]}]}}`.
    Pages serves the extensionless file as `application/octet-stream`; Apple's CDN fetches it anyway -
    check it with Apple's validator / `swcutil` once the app exists. Any other path of that host keeps
    opening in the browser.
  - `.well-known/assetlinks.json`: `[{"relation": ["delegate_permission/common.handle_all_urls"],
    "target": {"namespace": "android_app", "package_name": "<package>", "sha256_cert_fingerprints": ["<signing cert>"]}}]`
    (served as `application/json`).
- Alternative: a custom domain for Pages (then the same two files at its root, and the link in
  `SFWebPairScreen`/`SOFA_WEB_APP_URL` changes) - the user's choice.
- **iOS app:** entitlement `com.apple.developer.associated-domains` = `applinks:robertkleinschuster.github.io`;
  handle `NSUserActivityTypeBrowsingWeb` (SwiftUI `onOpenURL`), read `host` and `code` from the
  fragment. Camera scanning in-app: VisionKit `DataScannerViewController` or AVFoundation's QR reader
  (`NSCameraUsageDescription`). Local network: the tailnet is not the local network - no
  `NSLocalNetworkUsageDescription` needed; ATS: HTTPS with a public certificate passes by default, and
  `/discover` is plain HTTP - add an `NSExceptionDomains` entry or, simpler, skip `/discover` on iOS
  (the QR link carries the full name). Background playback: `UIBackgroundModes` `audio` + an
  `AVAudioSession` of category `.playback`; Picture in Picture via `AVPictureInPictureController`.
- **Android app:** `<intent-filter android:autoVerify="true">` with `VIEW`, `BROWSABLE`/`DEFAULT`,
  `https`, host `robertkleinschuster.github.io`, `android:pathPrefix="/sofa/pair"`; read the fragment
  from the intent's URI. Plain HTTP for `/discover` needs a `network_security_config` with
  `cleartextTrafficPermitted` for the tailnet's domain (or skip it as on iOS). Background play: Media3
  `MediaSessionService` (foreground service type `mediaPlayback`).
- **HTTP clients:** the status long poll (`GET /status?since=`) answers within 25 s; use a read timeout
  of at least 40 s (OkHttp's default 10 s is too short; URLSession's 60 s is fine). Segment requests of a
  converted stream may wait up to 60 s.

## Playing: formats

`POST /api/v1/play {item, formats}` - `formats` lists the codecs the client decodes in fragmented MP4,
**in its order of preference**: `avc1 hvc1 vp09 av01 mp4a opus`. Without it: `avc1, mp4a`.
- iOS (AVPlayer, HLS): `[avc1, hvc1, mp4a]` - Apple's HLS stack wants H.264/HEVC + AAC.
- Android (ExoPlayer): what `MediaCodecList` decodes, best first - e.g. `[av01, vp09, avc1, opus, mp4a]`.
- Browsers (`pwa/src/formats.ts`): newest first, AV1 > VP9 > HEVC > H.264, Opus > AAC - those the
  device decodes in hardware (Media Capabilities `powerEfficient`); software-only ones only when none
  decodes in hardware. hls.js: what `MediaSource.isTypeSupported` says; the browser's own HLS player
  (Safari, iOS): Apple's HLS codecs only (AV1, HEVC, H.264 + AAC - VP9 and Opus are none), e.g.
  `[av01, hvc1, avc1, mp4a]` on an iPhone with an AV1 decoder (15 Pro and later), H.264 + AAC always.

Sofa uses the list twice. Stored items: tracks the client decodes are served as they are (copied into
HLS segments), the rest is converted to H.264/AAC (docs/pwa.md §8). A single file (a mediathek's MP4,
online or stored) for a client listing `av01`: its video is re-encoded into AV1 (720p at most, the audio
copied - `segmented: "libsvtav1+copy"`), and so is an HLS presentation on demand (ORF: one variant and
its audio rendition, the audio as AAC - `"libsvtav1+aac"`); else served as it is. Apps with a session format of their
own: **YouTube** opens the online session in the client's codecs (`SFApp resolveForBrowser:formats:done:`
→ the engine's `vcodecs`/`acodecs`): a VP9/AV1 + Opus client gets VP9/AV1 + Opus (copied into segments),
an H.264 client H.264 + AAC; the biggest picture first (up to 1080p - VP9 often has it where H.264
doesn't), the client's order among equal ones. It is the same engine page, identity and pacing as every
other session (NOTES.md "YouTube client goals"): only the format of the one session differs, no extra
session or client.

## Streams

The play answer's `url` is a capability URL (`/m/<stream>/...`, no header: players can't send one).
Report the player's state to `POST /stream/<stream>` (`playing/paused/buffering/ended/closed`, position,
duration): it is how the TV learns the progress, and `closed` ends the stream. Report `buffering` when
the player waits for media while it should play, and `playing` once it plays (on its `playing` event):
Sofa logs how long the viewer waited - the first picture after the play request, each stall after it.

A stream ends:
- when the client says `closed`;
- after **10 minutes** neither read nor reported (the client is gone: a closed tab, a killed app);
- **4 hours after a `paused` report** (background play, Picture in Picture, a phone put away for a
  meal or a call: a paused viewer is not gone). Why 4 h: it covers an evening's interruption, and a
  pause longer than that is a forgotten one - iOS suspends and later ends a backgrounded app without a
  word, so no client can be trusted to say `closed`. A waiting stream holds little: no conversion job
  runs (they stop after 45 s), its converted segments are dropped once it is unused past 10 minutes, and
  only its small record stays;
- when its app session ends (YouTube's engine closes a session unused for 10 minutes, as on the TV);
- when the device opens a fourth stream (its oldest ends).

**Client rule:** any 404/410 on a stream URL (or a media error after a pause) means *play the item
again* - `POST /play` with the same item, then seek to the position the player had. That is what the
PWA does, and the apps must do the same; there is no "resume a stream" call.

## Pictures

`img`-like fields are signed paths (`/img/<HMAC>?u=...&w=`), handed out only in authenticated answers.
The signing key is persistent (`<data>/web/image.key`, mode 0600, 256 random bits; an older Sofa's
setting is migrated once): picture URLs a client cached stay valid across Sofa restarts and updates.
A 403 `bad_signature` (a different Sofa, the data folder replaced) means: reload the page.
