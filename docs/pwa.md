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
open, renewed every 5 minutes and after three wrong entries) and, beside it, a QR code of the pairing
link `…/sofa/pair#host=<full name>:<port>&code=<code>` (docs/api.md "Finding Sofa and pairing"): scanned
with a phone it opens the PWA (or a native app), which connects and pairs by itself. The PWA sends
`POST /api/pair {code, name, client}`; a right code returns a 256-bit random token, stored by the device in
`localStorage` and in Sofa only as its SHA-256 (`web_devices`, schema step 21). Every API call sends
`Authorization: Bearer <token>`; the TV screen lists the devices and removes them ("Gerät trennen").
Wrong codes are limited per code and globally (10 per minute).

Media requests cannot carry headers (native HLS on iOS, `<video src>`): a playback gets a
**capability URL** `/m/<stream id>/…` (128-bit random id) from an authenticated call; it is bound to
the device, lives while the stream is used (10 minutes idle) and serves only that stream's local
routes (a `paused` one lives 4 hours: docs/api.md "Streams"). Pictures are served as
`/img/<signature>?u=…` - an HMAC of the source by a persistent secret (`<data>/web/image.key`, 0600),
handed out only inside authenticated answers, so the image route is no open proxy.

### 3. Playback in the browser, through Sofa

Every stream goes through Sofa's existing local routes; the browser never contacts a source:

- **YouTube** (`SFApp resolveForBrowser:formats:done:`): the engine opens a session like the TV's, from
  the same Firefox page, identity, BotGuard and pacing - only the format is the client's: the codecs of
  its `formats` it prefers (docs/api.md "Formats"; up to 1080p) - the newest the device decodes in
  hardware: AV1 + AAC on an iPhone with an AV1 decoder (15 Pro and later), H.264 + AAC on older ones
  and any client that names nothing, AV1/VP9 + Opus where the client puts them first (Android, Firefox).
  A DASH pair of fragmented MP4 in the client's codecs (H.264 or AV1 + AAC) is served as byte ranges
  (below), a WebM one (VP9, Opus) goes through the segmenter, copied (§8). Two playbacks at once are two sessions of one page
  (the engine keeps up to four), like two tabs of one browser - one client, no second identity. The
  PWA reports its player state (`playing/paused/ended/closed`, position); Sofa forwards it to the
  engine's view reporting (`SFApp playback:reports:`), so the view is reported as youtube.com's
  player would. The tracks are byte-identical DASH files (docs/youtube-engine.md); Sofa reads their
  init (ftyp, moov, sidx - only the header ranges, which the engine has after the first SABR
  answer) and writes an HLS playlist with byte ranges (`SFWebHLS`): video and audio as separate
  renditions, codecs from the `avcC`/`av1C`/`esds` boxes. Every byte the browser reads is a Range request
  relayed to `/s/<sid>/video|audio`, so the media store keeps it and serves what it has.
- **Mediatheks** (ZDF, ARD, CCC files; ORF and lives HLS): the resolver's URL through
  `SFMediaProxy` (the media store), exactly as the TV player opens it. Files are served as files;
  HLS playlists are relayed with their loopback URIs rewritten to the stream's capability path.
- **Downloads**: a local file or a complete item in the media store plays from there - a mediathek
  download and a downloaded YouTube video too (§8: what the browser can't decode as it is - the TV's
  VP9/AV1 + Opus tracks in Safari - is converted while it streams; online as an H.264 session only
  when that can't be done).
- The browser plays HLS natively where it can (Safari, iOS) and with hls.js (MSE) elsewhere;
  progressive MP4 in a plain `<video>`.

Not offered in the browser: DRM items (as on the TV), and YouTube lives are untested from the
browser (they would run as a second live session of the same page).

The TV is not affected: its player, its engine sessions and their view reports are separate; the
engine's document refresh already waits for sessions in use.

Beyond the page (`src/background.ts`, 2026-11-26/27): a "Bild in Bild" button in the player's bar where
the browser has picture in picture (the standard API, or WebKit's presentation mode), and
`autopictureinpicture` so the browser may enter it by itself when the app goes to the background.
iOS offers no picture in picture in a Home Screen web app (WebKit bug 303885, open): the button stays
hidden there by the browser's own answer and comes back by itself once Apple fixes it. The audio
session is "playback" (WebKit's Audio Session API), and a pause the system makes on the way to the
background is undone once - the person's own pauses come through the Media Session actions (lock
screen, Control Center, headphones) or happen while the page shows.

**The carrier.** iOS pauses every `<video>` with a picture when the app leaves or the screen locks
(WebKit `MediaSessionManageriOS`: the Video and VideoAudio session types are background-restricted;
an `<audio>` element is an Audio session whatever its stream holds, and is not). So the sound is
carried on by an `<audio>` element of the same stream: it holds the video's URL with metadata loaded
from the start, is unlocked by the person's first tap (WebKit lets an element play without a gesture
once it saw one), and when the system pauses the video on the way out it starts at the video's
position - a hand-over right after audible playback stopped, which WebKit lets a hidden page start.
Back in front the video takes over at the carrier's position. The player's reports follow whichever
element plays (`Background.clock`); so do the lock screen's position and actions. A live stream
carries on from its edge; a MediaSource stream (hls.js, `blob:`) has no URL to carry, there the video
itself is asked to play on. A second reader of the stream is no burden: the capability path is plain
GETs, and the paused video reads nothing meanwhile. `test/background.test.ts` plays it through with
stand-ins for the page and both elements; what iOS really does is verified on the device.

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
rails and arrows at a rail's sides for a mouse).

States and polish (2026-11-26): a page loads as its **skeleton** - the real tiles' boxes in the page's
own colours (the app's theme is applied before the answer), so nothing jumps or changes colour when it
arrives (test-pwa 9 compares the boxes). App and wide tiles carry their text in the picture, as the
TV's (no line below). Icons are inline SVG. Every button is at least 44 px; hover and keyboard focus
show the TV's focus (ring + slight growth); `prefers-reduced-motion` stills every animation. Sofa not
answering: content on screen stays, a bar says "Keine Verbindung zu „imac“" (gone by itself, or
"Erneut versuchen"); at start the "nicht erreichbar" screen probes quietly and goes on by itself; a
playback that fails offers "Erneut versuchen" / "Schließen" (no retry for a format the browser can't
decode). A device removed on the TV is told why it pairs again. A toast never covers an open sheet (it
moves to the top). A reload during a playback lands on the page it was opened from.

Installed on iOS (2026-11-26): iOS 26+ lays its own scroll-edge blur over the top of a Home Screen web
app, and no meta tag or CSS property turns it off. WebKit leaves it out only where a sticky or fixed
box with an **opaque** background and **no backdrop-filter** covers the top edge
(`LocalFrameView::fixedContainerEdges`), so the header is solid `--bg-top`. The solid header alone did
not do it on an iPhone, so the installed app on iOS also gets `#top-edge`: a fixed strip in the
header's colour over exactly the header's top padding (status bar + 6 px, at least 12 px), invisible
and on every screen (test-pwa 9 checks both colours).
No `apple-mobile-web-app-status-bar-style` either: `black-translucent` is deprecated (WebKit bug 317153 -
a Home Screen web app draws nothing under the status bar); with it, iOS 27 laid the page under the clock
with a top inset of 0 (header cut off). iOS reads the tag when the app is added: remove and add again.
The apple-touch-icon is **full-bleed** (`res/icon/sofa-icon-fullbleed.svg`): iOS rounds it itself, and
the rounded tile with its margin came out small. The manifest keeps the rounded tile for "any" and adds a
maskable one; `pwa/tools/icons.sh` renders all PNGs. iOS reads the icon when the app is added, so a new
icon needs the app removed and added again.

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

### 8. Converting on the fly: the segmenter (2026-11-26)

User: "das Format on the fly transkodieren" - a stored item always plays from the store, in any browser.

**Negotiation.** Every play sends the codecs the browser decodes in fragmented MP4 (`formats`:
`avc1 hvc1 vp09 av01 mp4a opus`, `pwa/src/formats.ts`): through hls.js the page's own
`MediaSource.isTypeSupported` (Firefox/Chrome: VP9, AV1, Opus, AAC, H.264 where they have it); the
browser's own HLS player (Safari, iOS) is told H.264 + AAC only - what every Apple player decodes in HLS.
An older PWA sends nothing: H.264 + AAC. Sofa then decides per track:
- a DASH pair of fMP4 tracks of codecs the browser decodes (YouTube's browser session): byte ranges as in §3;
- a single MP4 file of such codecs (a mediathek's, online or downloaded): served as the file - except
  for a browser decoding AV1 (iPhone 15 Pro and later, recent Macs and PCs): its video is **re-encoded
  into AV1** by the segmenter (the audio copied), for fewer bytes over the viewer's line; as the file
  when that can't be (no AV1 encoder, another device's playback encodes);
- an HLS presentation on demand (ORF's, online or downloaded) for a browser decoding AV1: the best
  variant up to 720 lines (the media proxy's root asked with `?height=720`; a downloaded item has its
  one variant) and its default audio rendition through the segmenter -
  video into AV1, audio into AAC (an ADTS track isn't copyable into MP4); else the playlist as it is;
- anything else that is stored (a downloaded YouTube video's VP9/AV1 + Opus, two separate tracks, a
  local MKV): through the **segmenter** - each track **copied** where the browser decodes its codec, else
  **encoded** (video H.264, audio AAC-LC stereo 48 kHz). Not stored (besides a file for AV1): as
  before (§3). Lives stay as they are (the segmenter makes VOD playlists only).

**Timelines.** A file's timestamps are its timeline (MP4 edit lists, Opus pre-skip included). A broadcast
container's (HLS, MPEG-TS) don't start at 0 by design (ORF: 0.02 s, ffmpeg's muxer 1.4 s, a channel's
clock): there the timeline starts at the video's first timestamp (`SFAVProbe originUs`), and a separate
audio rendition - on the same clock (RFC 8216) - is placed by the same origin, so A/V stay as the source
has them. FFmpeg's HLS demuxer drops a non-video stream's packets before a seek target measured on that
playlist's own baseline (an audio rendition started 257 ms late): audio is sought 10 s earlier and cut
to the exact start by the track. A full-range source (`yuvj420p`, Tagesschau) is converted into TV range
through swscale's frame API (`sws_setColorspaceDetails` left it full-range; the deprecated format also
logged a warning per frame).

**Start time.** Every job logs how long its start took (`transcode: job from segment N: video open .. ms,
audio .. ms, first segment .. ms later`). The probe's open inputs serve the first job, a job's inputs the
next one (a seek) - `SFAVInputPool`, only inputs none of whose reads or seeks failed or were cut off:
opening ORF's two tracks again took ~1 s, now ~45 ms. After a seek the video's packets up to the last
keyframe at or before the start are read, not decoded (HLS lands on a segment's start: ORF 9.6 s
segments, a keyframe every 4.8 s - 2.2 s of decoding before, 0.3 s after). Measured 2026-11-27, first
segment after the init: BR MP4 2.2 s (seek 2.6 s), ORF ~1.8-2.5 s (seek 4.2-5.5 s: the source's 5 MB
segment before the target comes over the line first, ~1.8 s). ORF's 1080p variant made the re-encode
into 720p 2.06x real time and its segments 7.5 MB - the 720p variant (2.65x, 5 MB) is taken instead. What remains is encoding: SVT-AV1 needs 0.2 s to
start and 1.4 s for 4 s of 720p50; shorter segments would cost data (2 s: +13 %, 1 s: +40 %).
- When the segmenter can't (no encoder for the browser's formats, another device's playback encodes):
  the app's browser format (YouTube: the online H.264 session), else the message
  "Dieses Video lässt sich im Browser nicht abspielen." / "Gerade wird schon ein anderes Video für einen
  Browser umgewandelt – bitte später noch einmal versuchen.".

**Where it lives.** In Sofa's process, on the FFmpeg libraries libmpv already uses (bundled in
`Contents/Frameworks`; FFmpeg 9.0.2 of MacPorts is built with VideoToolbox, AudioToolbox and x264 -
no port change was needed; Sofa now links them itself, Makefile; SVT-AV1 comes with it). Library modules:
`SFAVInput` (one track through libavformat: a file or a local route, every blocking read bounded by
a deadline and cancellable; `SFAVProbe`: codecs, size, rate, duration, the container's keyframe
index), `SFSegmentTrack` (`SFSegmentCopy`, `SFSegmentVideo`, `SFSegmentAudio`), `SFSegmentJob` (one
run from a segment on: fragmented MP4 into memory - the init once, one fragment per segment),
`SFWebTranscode` (+Plan: what is copied/encoded, the caps, the segments; the session: playlist,
on-demand jobs, pacing, cache, one encoder at a time), `SFWebStreams+Transcode`. Routes of a
segmented stream: `/m/<stream>/index.m3u8` (VOD media playlist, `EXT-X-MAP` + `EXT-X-START` at the
resume position), `init.mp4`, `s/<n>.m4s`.

**HLS fMP4, muxed.** One media playlist, video and audio in the same fragments (hls.js and Safari both
play it); timestamps are the source's + 10 s (MP4 fragments carry no negative decode times; the first
packets of a source may have them - B-frames, Opus pre-skip); every fragment's `tfdt` is its first
packet's (`frag_discont`, no edit list, the muxer told not to shift), so segments of different jobs
line up exactly and the init is byte-identical across jobs (a job whose init differs fails the
session - the PWA opens the stream again).

**Seeking.** Nothing is made ahead of need. Encoded video has segments of a fixed number of frames
(4 s: 120 at 30 fps; 4.004 s at 29.97), copied video's start at the keyframes the container names
(WebM cues - read at a first seek when they sit at the end -, an MP4's sync samples, a fragmented
MP4's `sidx`), at least 4 s apart. A request for a segment that is cached is answered from memory;
one at or just past the running job's front (2 segments) waits for it; anything else starts a new job
there (the old one stops): it seeks the source to the keyframe before, decodes and drops what comes
before the segment's start, encodes from exactly there. A job makes at most 4 segments beyond the
furthest one asked for, then waits; nobody asking for 45 s stops it (a later request starts one
again); closing the stream stops it and drops its segments. Segments are kept in memory (48 MB per
stream, the ones furthest from the player first). Jobs run on a thread of their own at low priority.
A request waits at most 60 s.

**Encoders, measured on this Mac (i5-2500S, HD 3000 Quick Sync; 2026-11-26).** Order: the GPU's
VideoToolbox (`h264_videotoolbox`, `allow_sw 0` - Apple's software path is no better than x264), then
x264, then the fallback above. Each is tried once at launch of the first conversion (a small frame
through it); one that breaks in a job is struck off until Sofa restarts and the stream is planned
again with the next.
- VideoToolbox on 10.9: refuses frames with colour tags (-12917) - sent untagged (H.264's default for
  HD is BT.709); ignores forced keyframes - but keeps its key interval exactly, so the frames are made
  constant-rate (nearest decoded frame per slot) and every segment has exactly `gop` frames; budgets
  its bit rate from timestamp 0 (a job at 40 min made a 4x first segment) - its clock starts at 0 per
  job; refuses sessions below 640 px on the longer side (-8973: x264 takes those); takes only one
  session at a time (a second is refused with -8973 while the first runs) - a seek's new job waits
  for the cancelled job's session to close (a process-wide slot, at most 15 s, plus a few re-tries of
  the open); its rate control is an average over the whole run and ignores `maxrate` here: after a
  static start it spends the saved bits (a real stored track, 6.2 Mbit/s target: segments of ~1 Mbit/s,
  then 13, 27, 20 and 12 Mbit/s when the picture got busy, 5.5 Mbit/s over the first minute).
- Speed (VP9 1080p60 source, 3.2 Mbit/s, + Opus -> AAC, real stored YouTube tracks): VideoToolbox
  1080p30 1.95x real time with 1.2 cores busy (at playback pace ~0.6 of one core, ~15 % of the CPU),
  first segment 2.7 s after a seek; x264 (veryfast, zerolatency: no lookahead/B-frames; the default
  lookahead managed only 1.6x) 1.9x with 3.15 cores busy (~1.65 cores at playback pace). VideoToolbox
  1080p60 only 1.17x - too tight. Quality at ~5.5 Mbit/s 1080p30: VMAF 94.9 VideoToolbox, 89.3 x264
  veryfast/zerolatency. Decoding the VP9 itself: ~15x real time.
- Caps (from the real-time margin, not power): at most 1080 lines, at most the pixel rate of 1080p30 -
  a faster source keeps its size and loses every second frame (1080p60 -> 1080p30, 720p60 stays);
  ~0.1 bit per pixel (1080p30 6 Mbit/s, 720p30 2.8 Mbit/s, 1.5-8 Mbit/s); x264 constant quality (CRF 21)
  under the same ceiling. 10-bit (VP9.2 HDR) is converted to 8 bit without tone mapping.
- One encoding session at a time: a second device's play while one encodes (asked within 45 s) gets
  the app's browser format; the same device's new play takes the encoder over. Copying has no limit.
- AV1 (`libsvtav1`, the only AV1 encoder; measured 2026-11-27 on 20 s of Das Erste's 720p50 H.264
  broadcast, 3.7 Mbit/s): preset 10 without lookahead 2.65x real time with every core busy, ~1.1 Mbit/s
  at VMAF 92.6 (preset 12: 3.0x, VMAF 92.0); 1080p50 only 1.48x (preset 12) - too tight next to the
  TV's playback, so at most **720 lines**. Constant quality (CRF 35) under a ceiling of ~0.05 bit per
  pixel (720p50 2.3 Mbit/s), closed GOPs. FFmpeg's SVT-AV1 wrapper forces no keyframes (only with gop
  1), but SVT keeps its intra period exactly from a job's first frame - each job starts at a segment
  boundary, so every segment opens with a keyframe (as with VideoToolbox). A real BR mediathek file
  (720p50, 3.2 Mbit/s video + 250 kbit/s AAC): 1.26 Mbit/s video at VMAF 90.6, the stream 56 % smaller,
  a 4 s segment in ~1.9 s through the media proxy. ORF (720p50 HLS, 4.2 Mbit/s video variant + 192 kbit/s
  AAC rendition): ~2x real time, a seek 20 minutes in delivered its first segment after 5.5-7.5 s (the
  proxy fetches the source's 9.6 s segments first). HEVC is no option here: the HD 3000 has no HEVC
  encoder, x265 ultrafast managed 1080p50 at 0.71x. Memory: ~285 MB while it encodes.

Not done: audio beyond stereo is downmixed; subtitles of stored items are not offered in the browser.

## API

The contract is `api/openapi.yaml` (checked by `tools/test-api` against a dev instance, examples in
`api/examples/`); the prose for every client - versions, features, error codes, discovery, pairing by
QR code, formats, stream lifetimes, what the native apps need - is docs/api.md. The PWA uses the
unversioned paths (`/api/...` = `/api/v1/...`).

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
- `formats.ts` the codecs this browser decodes (sent with every play, §8).
- `player.ts` native HLS on Apple's browsers, hls.js elsewhere, files in `<video>`; reports
  every 10 s and on pause, seek, end and close (a beacon on the capability path when the page goes
  away); a broken stream is opened again (twice), a format the browser can't decode says so.
- `header.ts` the header (built once, updated per view - its buttons never move); `skeleton.ts` the
  loading shapes; `toast.ts` the toast; `netbar.ts` the "Keine Verbindung" bar.
- `static/style.css` (tokens, header, screens), `tiles.css` (pages, tiles, skeletons), `overlays.css`
  (sheet, player, the TV's bar, toast, connection bar).
- `theme.ts` tokens to CSS variables, fonts by PostScript name through `local()`; `logos.ts` the
  logos (copied from `res/logos` at build time) recoloured as `SFLogo.m` does.
- `sw.ts` the service worker caches the shell only - never Sofa's data or media.
- `static/pair.html` the target of the TV's pairing link (`/sofa/pair`): hands its fragment to the PWA;
  the path a native app claims as Universal Link / App Link (docs/api.md).

Published by `.github/workflows/pwa.yml` (check, unit tests, build, Pages) on every push to master
that touches it. Tests: `pwa/test` (pure parts, `npm test`), `tools/test-pwa` (in test-all): the
built PWA in a headless Firefox (Marionette) against a dev instance - connect via the short name,
pairing with the dev code, pages, a playback with its reports, marks, the TV (send from the sheet,
the bar's pause and stop, asking before replacing, a playback handed over at its position), downloads
(started, the chip to "Offline", Behalten, a confirmed delete), a WebM DASH pair through the segmenter
(copied, played and sought with hls.js), the TV's pairing link (QR code: `pair.html` → paired without
typing), phone and desktop widths;
`PWA_SHOTS=<dir>` saves screenshots (Firefox then renders into an invisible Xvfb). This Mac's
Firefox build decodes no H.264 and - in the page's MediaSource - no audio in MP4, so there the DASH pair
is checked up to hls.js reading its master playlist; the byte relay is test-web's, a VP9 file plays end
to end, and so does a segmented VP9 pair without sound. `tools/test-web` 14 checks the segmenter with
ffprobe: codecs, a keyframe at each segment's start, continuity, audio with video, a seek's job, the
idle stop, one encoder at a time, the fallbacks (no encoder, x264 only).

## Open questions (for the user)

- Subtitles of stored items are not offered in the browser yet (the TV shows them).
