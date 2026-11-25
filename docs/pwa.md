# Sofa im Browser (PWA)

Status: design 2026-11-25, implemented with it. A second, independent UI for Sofa: a progressive web
app served by GitHub Pages that talks to the Sofa running on the TV over the tailnet. It shares
Sofa's whole backend - the database (progress, watched, Später ansehen, follows, Neue Folgen), the
apps' resolvers and pages, the YouTube engine and the media store - and plays in the browser while
the TV plays something else.

```
phone / desktop browser                         the iMac (Sofa.app)
┌───────────────────────────┐   tailnet, TLS   ┌──────────────────────────────────────────────┐
│ PWA (GitHub Pages, static)│ ───────────────► │ SFWebServer  :7443 (TLS, tailnet addresses)  │
│  pages, tiles, player     │  JSON + media    │  ├─ auth: paired device tokens (SFWebDevices)│
│  hls.js / native HLS      │                  │  ├─ pages: SFHome / SFApp loaders (SFWebItems)│
└───────────────────────────┘                  │  ├─ state: SFStore, SFWatchLater, SFFollows   │
                                               │  └─ streams (SFWebStreams): relay of the      │
                                               │     loopback media routes                     │
                                               │        ├─ SFMediaProxy (mediatheks, store)    │
                                               │        └─ SFYTEngine /s/<sid>/… (Firefox)     │
                                               └──────────────────────────────────────────────┘
```

## Decisions

### 1. HTTPS page -> tailnet host

A GitHub Pages site is https; a request to `http://imac:port` is mixed content and blocked, and
an https request needs a certificate the browser trusts for the name it asked for.

Options weighed:
- **Sofa serves TLS itself with the tailnet's certificate (chosen).** Tailscale issues a Let's
  Encrypt certificate for the machine's MagicDNS name (`tailscale cert`, works as the logged-in
  user, no root). Sofa (OpenSSL, already bundled for libcurl) terminates TLS on its own port,
  listens on every address but accepts only connections addressed to the machine's tailnet
  addresses (100.64.0.0/10, fd7a:115c:a1e0::/48) - never the LAN. No change to tailscaled's
  configuration, nothing that could touch the tunnel; renewal is Sofa's (below).
- `tailscale serve` (Tailscale terminates TLS and proxies to a loopback port): also clean, renews by
  itself, but it changes tailscaled's persistent serve configuration on the only way into this
  machine and makes Sofa's feature depend on it. Rejected for that reason.
- Self-signed certificate / a local CA: every device would have to trust it; not acceptable UX.
- Plain HTTP with the PWA served from the iMac itself: no GitHub Pages, no installable https PWA.

Certificate lifecycle (`SFTailnet`): at launch and daily, Sofa reads `tailscale status --json`
(the first `CertDomains` entry is the name the certificate is for) and runs `tailscale cert` into
`<data dir>/web/` when the certificate is missing or expires within 30 days; tailscaled returns its
cached certificate otherwise. The server reloads a new certificate without restarting. Only the
read-only `status` and `cert` are ever called - never `up`, `down`, `logout` or anything that
restarts the daemon.

Requirements on the tailnet (the user's admin console, not done by Sofa): MagicDNS and "HTTPS
certificates" enabled (both are on for this tailnet), and the ACL must let the user's devices reach
`tag:` of the iMac on TCP 7443 (the current policy grants members access to every port). Note: an
issued certificate puts the machine's MagicDNS name into the public Certificate Transparency logs.

**The short name.** The user types "imac". The certificate is for the full MagicDNS name, so the
PWA must learn it. A `fetch` to `http://imac` is mixed content, but a top-level navigation to it is
allowed. The PWA navigates to `http://imac:7443/connect?return=<its own URL>`; the same port
answers plain HTTP (the first byte decides: 0x16 = a TLS handshake) with exactly one thing: a 303
redirect back to the PWA with `#host=<full name>:7443` - only to the PWA's origin (an allow list),
nothing else is served without TLS. The PWA stores the full name and uses https from then on.
Typing the full name works too (no detour). The MagicDNS search domain is what lets the browser
resolve "imac" at all - Tailscale sets it on every client.

**Private Network Access / Local Network Access.** Chrome sends a preflight with
`Access-Control-Request-Private-Network: true` before a public site reaches a private address; the
server answers every preflight with `Access-Control-Allow-Private-Network: true` and CORS for the
allowed PWA origins (`Access-Control-Allow-Origin` exact, `Vary: Origin`, methods, the
`Authorization` and `Content-Type` headers). Newer Chrome versions ask the user once for "access to
devices on the local network" instead; the PWA explains that prompt on its connect page.

### 2. Auth: pairing with a code on the TV

No request reaches Sofa's data without a device token. Pairing is started on the TV, like the
phone pairing: Einstellungen → "Sofa im Browser" shows a 6-digit code (valid while the screen is
open, renewed every 5 minutes and after three wrong entries). The PWA sends
`POST /api/pair {code, name}`; a right code returns a 256-bit random token, stored by the device in
`localStorage` and in Sofa only as its SHA-256 (`web_devices`, schema step 21). Every API call sends
`Authorization: Bearer <token>`; the TV screen lists the devices and removes them ("Gerät trennen").
Wrong codes are limited per code and globally (10 per minute).

Media requests cannot carry headers (native HLS on iOS, `<video src>`): a playback gets a
**capability URL** `/m/<stream id>/…` (128-bit random id) from an authenticated call; it is bound to
the device, lives while the stream is used (10 minutes idle) and serves only that stream's local
routes. Pictures are served as `/img/<signature>?u=…` - an HMAC of the source by a per-launch
secret, handed out only inside authenticated answers, so the image route is no open proxy.

### 3. Playback in the browser, through Sofa

Every stream goes through Sofa's existing local routes; the browser never contacts a source:

- **YouTube** (`SFApp resolveForBrowser:`): the engine opens a session like the TV's, from the same
  Firefox page, identity, BotGuard and pacing - only the format differs: H.264 + AAC (`vcodec avc1`,
  `acodec mp4a`, up to 1080p) instead of VP9/AV1 + Opus, because every browser (iOS Safari
  included) decodes those in fragmented MP4. Two playbacks at once are two sessions of one page
  (the engine keeps up to four), like two tabs of one browser - one client, no second identity. The
  PWA reports its player state (`playing/paused/ended/closed`, position); Sofa forwards it to the
  engine's view reporting (`SFApp playback:reports:`), so the view is reported as youtube.com's
  player would. The tracks are byte-identical DASH files (docs/youtube-engine.md); Sofa reads their
  init (ftyp, moov, sidx - only the header ranges, which the engine has after the first SABR
  answer) and writes an HLS playlist with byte ranges (`SFWebHLS`): video and audio as separate
  renditions, codecs from the `avcC`/`esds` boxes. Every byte the browser reads is a Range request
  relayed to `/s/<sid>/video|audio`, so the media store keeps it and serves what it has.
- **Mediatheks** (ZDF, ARD, CCC files; ORF and lives HLS): the resolver's URL through
  `SFMediaProxy` (the media store), exactly as the TV player opens it. Files are served as files;
  HLS playlists are relayed with their loopback URIs rewritten to the stream's capability path.
- **Downloads**: a local file or a complete item in the media store plays from there.
- The browser plays HLS natively where it can (Safari, iOS) and with hls.js (MSE) elsewhere;
  progressive MP4 in a plain `<video>`.

Not offered in the browser: DRM items (as on the TV), and YouTube lives are untested from the
browser (they would run as a second live session of the same page).

The TV is not affected: its player, its engine sessions and their view reports are separate; the
engine's document refresh already waits for sessions in use.

### 4. Shared state

The PWA reads and writes the same store through the same modules as the TV: `SFStore
savePosition:` (same watched rule), `setWatched:`, `SFWatchLater`, `SFFollows`. Position reports
come every 10 s while playing and on pause/seek/close. The TV's pages reload on
`SFLibraryDidChangeNotification`; the server posts it when something the TV lists changed (watch
later, follows, watched, a new entry in Weiterschauen, a stream's last position) - not on every
periodic position report, so the TV's Home does not rebuild every 10 s.

### 5. Look

The PWA takes Sofa's design tokens from the server (`/api/info`: every registered theme's colors,
fonts as PostScript names, corner radius, header mark) and maps them to CSS custom properties per
page - home, YouTube, ZDF, ARD, ORF, CCC look as on the TV. Fonts: the same faces where the device
has them (`local()` by PostScript name: Avenir Next, Helvetica Neue, Gill Sans on Apple devices),
the system font elsewhere - Apple's fonts can't be bundled. Logos come from `res/logos` at build
time. Tiles, rails, hero, progress bars, the "Weiterschauen" rail and the dot-joined subtitles follow
the TV's components; layout is responsive (phone: one column of rails with swipe, desktop: wider
rails and a hero).

## API (all JSON, `Authorization: Bearer <token>` unless noted)

| Route | |
|---|---|
| `GET /connect?return=<url>` (plain HTTP) | 303 to the PWA with `#host=<name>:<port>` |
| `GET /api/hello` (no auth) | `{name: "Sofa", version, paired: bool}` - reachability and token check |
| `POST /api/pair {code, name}` (no auth) | `{token, device}`; 403 wrong code, 429 too many tries |
| `DELETE /api/pair` | this device unpairs itself |
| `GET /api/info` | the apps (name, search), design tokens of every theme, this device's name |
| `GET /api/home` | Home's sections as a page |
| `GET /api/app/<id>` | an app's start page (framed as on the TV) |
| `GET /api/page/<handle>` | a folder's page (handles name page loaders of earlier answers) |
| `GET /api/more/<handle>` | the next portion of a shelf with `more` |
| `GET /api/show?ref=&title=` | a show/channel page by ref |
| `GET /api/search?app=&q=` | an app's search page (without `q`: the household's recent searches) |
| `GET /api/suggest?app=&q=` | the app's search suggestions |
| `POST /api/play {item}` | `{stream, kind: hls\|file, url, start, duration}` |
| `POST /api/stream/<id> {state, position, duration}` | player state; `closed` ends it |
| `POST /api/state {item, watched?, later?, follow?, forget?}` | marks (`forget`: out of Weiterschauen); answers the item's new state - with no mark, just its state |
| `GET /m/<stream>/…` (capability) | the stream's media (Range) |
| `GET /img/<sig>?u=&w=` (signed) | a picture through Sofa's image path (JPEG/PNG, sized) |

Items carry their stored dictionary (`d`) - the PWA echoes it back in `play`/`state`, like the
store keeps it - plus display fields (`kind`, `title`, `sub`, `img`, `progress`, `watched`,
`later`, `following`, `page` handle, `theme`).

## The PWA (`pwa/`)

Strict TypeScript without a framework (`pwa/src`), bundled by esbuild (the wasm build: the same on
CI and on this Mac) into `pwa/dist`; hls.js is its own chunk, loaded when a video plays.

- `connection.ts` host name, connect redirect, token (localStorage); `api.ts` the calls above;
  `router.ts` hash routes (GitHub Pages serves one page); `main.ts` the controller: routes,
  header (the page's wordmark or logo and header mark, the apps, search, settings), a view per
  history entry kept so Back returns to it as it was left.
- `pages.ts` shelves (rails scroll sideways with arrows for a mouse, grids wrap; `more` appends at
  the end), `tiles.ts` the TV's tiles (SFTile.m: badge, duration, chip, progress, watched, avatar);
  a mark or a playback updates every tile of the item in place. A tap plays (as OK on the remote),
  ⋯ opens the sheet (`sheet.ts`: play / from the start, Später ansehen, gesehen, aus Weiterschauen,
  zur Sendung, folgen).
- `player.ts` native HLS on Apple's browsers, hls.js elsewhere, files in `<video>`; reports
  every 10 s and on pause, seek, end and close (a beacon on the capability path when the page goes
  away); a broken stream is opened again (twice), a format the browser can't decode says so.
- `theme.ts` tokens to CSS variables, fonts by PostScript name through `local()`; `logos.ts` the
  logos (copied from `res/logos` at build time) recoloured as `SFLogo.m` does.
- `sw.ts` the service worker caches the shell only - never Sofa's data or media.

Published by `.github/workflows/pwa.yml` (check, unit tests, build, Pages) on every push to master
that touches it. Tests: `pwa/test` (pure parts, `npm test`), `tools/test-pwa` (in test-all): the
built PWA in a headless Firefox (Marionette) against a dev instance - connect via the short name,
pairing with the dev code, pages, a playback with its reports, marks, phone and desktop widths;
`PWA_SHOTS=<dir>` saves screenshots (Firefox then renders into an invisible Xvfb). This Mac's
Firefox build decodes no H.264, so there the DASH pair is checked up to hls.js reading its master
playlist; the byte relay is test-web's, and a VP9 file plays end to end.

## Open questions (for the user)

- Should "Auf dem Fernseher abspielen" (send the item to the TV) be added? Not built: the request
  was an independent second UI.
- Downloads are visible (played from the store) but not started from the browser yet.
