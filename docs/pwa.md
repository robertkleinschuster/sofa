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
- **Downloads**: a local file or a complete item in the media store plays from there - a mediathek
  download in the browser too. A downloaded YouTube video plays from the store on the TV; in the
  browser it plays online as an H.264 session, because the store keeps the TV's tracks (VP9/AV1 +
  Opus), which Apple's browsers don't decode.
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

### 6. The TV: "Auf dem Fernseher abspielen" (2026-11-26)

The sheet of every playable item (and a TV button in the browser's player: "Am Fernseher
weiterschauen") sends it to the TV (`POST /api/tv/play`). `SFWebTV` (Library) opens it in the TV's own
player through the shell's player host (`SFPlayerHost`, handed to `SFWebServer` at launch) - exactly as
when chosen with the remote: `SFPlayerScreen` resumes from the stored position (or from `at`, where the
browser handed a playback over, or from the start), keeps history and marks, autoplays as always. The
screen wakes as for the phone remote (`wakeAndFront`: a user activity wakes the display; playing ends a
rest).

- **Something else plays on the TV** (playing, paused or loading): not replaced unasked - the answer is
  409 naming it, and the PWA asks ("Am Fernseher läuft gerade „X“." - "Es wird dort beendet – die
  Stelle bleibt gespeichert." - "Stattdessen „Y“ abspielen"). The TV may be watched by someone else; the
  phone remote's direct replace is YouTube's protocol, not a model for a second device. A failed or
  finished player is replaced without asking. The same video already playing is not reopened: it
  plays on (at the handed-over position if there is one).
  A hand-over from the browser's player asks the same way; the browser's player has closed by
  then (its position is saved either way).
- **One player per video and person.** Before the TV opens it, the device's own browser streams of that
  item end (`SFWebStreams endItem:device:` - the app's session closes as on "closed"); the PWA closes
  its player first when it hands a playback over. So moving a YouTube video to the TV never leaves a
  second session of it running for the browser. (The TV and a browser watching *different* videos -
  or another person the same one - stay two sessions of the one engine page, §3.)
- **Feedback.** The PWA says "Am Fernseher geöffnet", then - from Sofa's status - "Läuft jetzt am
  Fernseher" once it plays, or "„X“ ließ sich am Fernseher nicht abspielen." when the TV's player failed
  (the TV shows its reason); network failures: "Der Fernseher ist gerade nicht erreichbar.".
- **"Am Fernseher"**: a bar at the bottom shows what the TV's player shows (picture, title, state,
  position / length running on between answers, a progress line) with pause/play and stop
  (`POST /api/tv/control`; stop leaves the player as MENU does - the position is kept; play wakes the
  screen). It shows whatever plays on the TV, sent from the browser or chosen with the remote.

Sofa's status (`SFWebStatus`, `GET /api/status?since=<gen>`) is one long poll for the TV and the
downloads: it answers at once when the browser's generation is not the current one (a new launch has
a new prefix), else when the TV's player or a download changes (`SFPlayerStateNotification`,
`SFDownloadsDidChangeNotification`, coalesced 0.25 s), at the latest after 25 s (3 s while a download
runs). The PWA polls only while visible (no request in the background), backs off up to 30 s while Sofa
is unreachable, and asks at once after its own actions.

### 7. Downloads from the browser (2026-11-26)

The sheet offers what the TV's options menu offers for the item's download state (`dl` in the item:
none / queued / running with progress / done with Behalten and "gone" / failed with its reason):
Herunterladen, Download abbrechen, Erneut herunterladen, Aus Downloads entfernen, Behalten, Download
löschen. They go through `POST /api/state` (`download: true|false`, `keep`) to `SFDownloads` - the same
queue, per-source spacing, YouTube pacing and storage guard as on the TV; a started download answers
with what the TV would toast (`download:told:`: "Wird heruntergeladen – noch 340 MB …"). Deleting a copy
that can't come back (kept, or no longer online) asks first, naming why, as the TV does. Tiles show the
TV's chip (`↓ 42 %`, `↓ wartet`, `↓ Offline`); Sofa's status lists the downloads on their way, their
tiles follow (only the chip is rewritten - no rebuilt tile, no picture fading in again), and one that
left the list gets its final state. Only items with a resolver ref can be downloaded from the browser
(the ref travels in the item's `d`; a resolver block cannot).

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
| `POST /api/state {item, watched?, later?, follow?, forget?, download?, keep?}` | marks (`forget`: out of Weiterschauen), the download (`true` starts or retries, `false` cancels or deletes; `keep`: Behalten); answers the item's new state (+ `message` for a started download) - with no change, just its state |
| `POST /api/tv/play {item, fromStart?, at?, replace?}` | `{tv, already?}`; 409 `{error, busy: {title}}` another video plays there; 403 DRM |
| `POST /api/tv/control {action: play\|pause\|stop}` | `{tv}`; 404 nothing on the TV |
| `GET /api/status?since=<gen>` | `{gen, tv: {item, state: playing\|paused\|buffering\|ended\|failed, position, duration, live} \| null, downloads: [item]}` - long poll (§6) |
| `GET /m/<stream>/…` (capability) | the stream's media (Range) |
| `GET /img/<sig>?u=&w=` (signed) | a picture through Sofa's image path (JPEG/PNG, sized) |

Items carry their stored dictionary (`d`) - the PWA echoes it back in `play`/`state`/`tv`, like the
store keeps it - plus display fields (`kind`, `title`, `sub`, `img`, `progress`, `watched`,
`later`, `following`, `chip`, `dl` (the download: `state`, `progress`, `kept`, `gone`, `failure`),
`page` handle, `theme`).

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
  ⋯ opens the sheet (`sheet.ts`: play / from the start, auf dem Fernseher, Später ansehen, the
  download (`choices.ts`), gesehen, aus Weiterschauen, zur Sendung, folgen; and its confirmations).
- `status.ts` the long poll of Sofa's status; `tv.ts` sending to the TV and the "Am Fernseher" bar;
  `downloads.ts` the download actions and the tiles of downloads on their way.
- `player.ts` native HLS on Apple's browsers, hls.js elsewhere, files in `<video>`; reports
  every 10 s and on pause, seek, end and close (a beacon on the capability path when the page goes
  away); a broken stream is opened again (twice), a format the browser can't decode says so.
- `theme.ts` tokens to CSS variables, fonts by PostScript name through `local()`; `logos.ts` the
  logos (copied from `res/logos` at build time) recoloured as `SFLogo.m` does.
- `sw.ts` the service worker caches the shell only - never Sofa's data or media.

Published by `.github/workflows/pwa.yml` (check, unit tests, build, Pages) on every push to master
that touches it. Tests: `pwa/test` (pure parts, `npm test`), `tools/test-pwa` (in test-all): the
built PWA in a headless Firefox (Marionette) against a dev instance - connect via the short name,
pairing with the dev code, pages, a playback with its reports, marks, the TV (send from the sheet,
the bar's pause and stop, asking before replacing, a playback handed over at its position), downloads
(started, the chip to "Offline", Behalten, a confirmed delete), phone and desktop widths;
`PWA_SHOTS=<dir>` saves screenshots (Firefox then renders into an invisible Xvfb). This Mac's
Firefox build decodes no H.264, so there the DASH pair is checked up to hls.js reading its master
playlist; the byte relay is test-web's, and a VP9 file plays end to end.

## Open questions (for the user)

- Downloaded YouTube videos play online in the browser (H.264), from the store only on the TV (§3).
  Serving the stored VP9/Opus tracks to browsers that decode them (Firefox, Chrome) would need an MSE
  path of its own; not built.
