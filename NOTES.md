# Sofa — 10-foot media center for the iMac (macOS 10.9.5)

Binding architecture and product notes. **Read before any work on Sofa, update after
every decision** (section "Decision log").

## Goal
A self-made, polished "smart TV" product instead of Kodi: native Cocoa app operated with
the Apple Remote, one area per source with its own look (YouTube, ZDF, ARD, ORF,
media.ccc.de, all Mediatheken), local downloads + streaming + own subscription engine in ONE
program. Intuitive, stable, light on resources on the iMac12,2 (i5-2500S Sandy Bridge, no
AVX2, Radeon HD 6770M, 2560x1440).

## Architecture rule (user 2026-11-06, BINDING)
Build every architecture the way it would ideally be built from scratch - fewest runtimes and
processes, one responsibility each, explicit dependencies - and migrate to it; never keep a
component only because it already exists.

## Hard rules (user requirements 2026-11-03)
1. **New, clean monolith.** No dependency on old code (Kodi add-ons
   `script.ytdlsub`, `script.mobilecast`, `~/ytdl-sub/*.py`, run.sh). The old code
   only serves as a source of ideas/features.
2. **Own subscription engine** (replaces ytdl-sub), cleanly integrated (subscribe from every
   source app, scheduling, download, retention, progress in the UI).
3. **Own scrapers** for the Mediatheken, directly against the source APIs; MediathekView
   (MServer, open source) only as a reference for endpoints — **no dependency on
   MediathekView servers** in the final state.
4. ~~yt-dlp = the only external engine~~ (superseded 2026-11-06, user: yt-dlp removed): YouTube
   runs through Sofa's own YouTube engine `res/sofa-yt` (youtubei.js + SABR, one browser
   identity) inside the bundled Firefox (docs/youtube-engine.md).
5. Apple Remote **Menu button starts Sofa** (Front Row principle) via our own helper.
6. Final state: the self-contained release DMG (GitHub releases, `tools/make-release`), built with
   the MacPorts toolchain; MacPorts is only the build machine's workbench, follow the doctrine.
7. Subtitles are NOT needed.

## YouTube client goals (user 2026-11-06, BINDING - check every YouTube change against these)
1. **No bot checks in the first place.** Sofa must not trigger "Melde dich an, damit wir sehen,
   dass du kein Bot bist" at all - preventing it ranks above reacting to it (pause/backoff is
   only the safety net). Private use; the user explicitly allows making the client
   indistinguishable from a real browser.
2. **One identity, one client.** Every request to YouTube/Google (player, BotGuard/PO token,
   InnerTube pages, SABR media, captions, thumbnails as far as possible) comes from the same
   client with the same cookies, TLS and HTTP behaviour. Mixing clients under one visitor is
   counterproductive.
3. **A real browser, long-term stable.** Target: a bundled headless Firefox (port
   `firefox-x11`, 153 ESR, built and installed) is the YouTube client. Acceptable alternative
   only if it is equally indistinguishable from a real browser without Firefox. Feasibility
   2026-11-06: BiDi headless works on 10.9 (UA "Intel Mac OS X 10.15; rv:153.0"), page->client
   37 MB/s.
   **Target architecture (built as if from scratch, user rule 2026-11-06):** two runtimes only -
   Sofa (ObjC: UI, library, libmpv, ffmpeg, the loopback HTTP server mpv/ffmpeg read from) and
   Firefox (one hidden youtube.com page running Sofa's YouTube engine: youtubei.js web build,
   googlevideo SABR, BotGuard in the real DOM - no jsdom - plus the session/pacing logic of
   today's `res/sofa-yt/lib/session.ts`). Sofa talks to the engine through its WebExtension
   (not WebDriver: YouTube refuses a browser under remote control, measured 2026-11-06) and pulls
   media bytes over that channel. **No Node at runtime**: Node/TypeScript only at build time
   (bundle the engine to one JS file; a build dependency only), the engine's unit tests stay.
   Built 2026-11-07: `SFYTEngine` (docs/youtube-engine.md); Firefox on its own Xvfb display.
4. **Human cadence.** Few requests at a viewer's pace (downloads 20-30 min apart, no bursts,
   preloads only on real focus changes); no retries into a fresh block.
5. **Dependencies explicit** (user): every library/tool Sofa uses is declared (Makefile/release
   build/package.json), never only reached through another package.
6. Until the Firefox client is installed, the interim measures stay in the installed app
   (0.3.10: node sidecar): throttling, longer breaker pause. (Fulfilled 2026-11-07: the Firefox
   engine replaced the node sidecar.)

## Technology
- Objective-C + ARC, AppKit, Core Animation (layer-hosting, redraw only on
  change), mpv/libmpv (all playback), IOKit HID, SQLite (system libsqlite3).
- Build: clang-22 (`/opt/local/bin/clang`), no Xcode/SDK needed (headers from /System).
  **Pitfalls:** (a) the 10.9 headers know no lightweight generics → no `NSArray<X*>`;
  (b) `-fobjc-arc` when LINKING requires libarclite (missing) → `-fobjc-arc` only when
  compiling, link without it (the 10.9 runtime has ARC natively); (c) no 10.10+ APIs
  (NSQualityOfService, NSVisualEffectView etc.).
- Layout in design units 1920x1080, `U()` scales (SFScale = height/1080).
- Tested 2026-11-03 (then with AVFoundation): plays local MP4, ZDF/3sat/ARD/BR/ARTE/SRF/ORF
  VOD, live streams Das Erste/ZDF/ORF1/3sat (HLS) and the media.ccc.de CDN → 10.9 TLS
  is enough — EXCEPT ORF (api-tvthek, *.mdn.ors.at, *.sf.apa.at: only AES-GCM/TLS1.3).
- **TLS bridge (`SFCurl`)**: libcurl from MacPorts (OpenSSL). `SFNet`/`SFImageCache`
  use curl for known hosts or hosts learned from an SSL error. mpv reads ORF itself (its own
  TLS); VOD goes through `SFMediaProxy` (127.0.0.1, curl, the media store; docs/media-store.md).
  (The old `#EXT-X-VERSION` cap was for CoreMedia 10.9 - gone with AVFoundation.)

## Code structure (`~/src/sofa`)
Layered since 2026-11-05 – contract and rules in **docs/architecture.md**, how to add an app in
**docs/new-app.md**, rules enforced by `tools/check-arch` (part of test-all):
- `src/Framework` UI kit + design system (SFTheme tokens, SFScreen/SFNavigator, SFTile,
  SFMenuScreen, keyboard, SFLayers, icon art, logo).
- `src/Core` (+ `Library`, `Player`, `Browse`) app-agnostic media core: SFModel, SFApp contract
  + SFAppRegistry, SFHomeSection, SFStore, downloads/follows/watch later/search, player +
  engines, SFBrowseScreen + library pages (SFLibraryPages).
- `src/Apps/<App>` one folder per source (YouTube incl. SABR/YouTube engine/phone remote, ZDF, ARD, ORF,
  CCC; Example = dev template with `SOFA_EXAMPLE_APP=1`).
- `src/Shell` AppDelegate (player host, dev FIFO, update handover), app registration
  (SFApps.m), home composition + settings (SFHome), migration.
- `helper/` SofaRemote (LaunchAgent): holds Apple IR exclusively, Menu starts Sofa,
  forwards keys to the app via Mach port.
- Data: `~/Library/Application Support/Sofa/sofa.db` (schema + rules: docs/architecture.md
  "Data"), cache `~/Library/Caches/Sofa`, log `~/Library/Logs/Sofa.log`. Dev instances:
  `Application Support/Sofa-dev/<instance>` or `$SOFA_DATA_DIR` (docs/architecture.md "Dev instances").

## Data sources
- Offline library: `~/Movies/Sofa/<source>/<show>/<title> [<id>].mp4` + `.jpg`,
  poster.jpg/fanart.jpg per show; metadata only in the DB (`downloads`, `subscriptions`).
  `SFLibrary` is now only a view on it (grouped by source + show).
- MIGRATED 2026-11-03 (`SFMigration`, one-off, setting `migration.tvshows`): from
  `~/TV Shows` (ytdl-sub/Kodi) 1787 videos / 427 GB moved (rename, 0 errors),
  141 progress entries local:… → yt:/zdf:/ard:, 127 subscriptions from `~/ytdl-sub/subscriptions-kodi.yaml`
  (+ Jay Foreman manually: the channel is now called "Map Men", UCbbQalJ4OaC0oQ0AqRaOJ9g).
  Old library without subscription binding (never deleted automatically), new subscription episodes 90 days.
  Rest (NFO + info.json, 10 GB) in the trash. ytdl-sub daemon `com.ytdlsub.run`
  disabled via `launchctl unload -w`. The bgutil PO-token server (yt-dlp's resolver) is gone too: yt-dlp
  left on 2026-11-06, PO tokens come from the Firefox engine; the server was stopped on 2026-11-18.
- Apple IR: AppleIRController, consumer page usages: 0x40 Menu, 0x41 Select,
  0x42 Up, 0x43 Down, 0x44 Left, 0x45 Right, 0xCD Play/Pause, 0xB5/0xB6 Next/Prev,
  0xE9/0xEA Vol; GenericDesktop 0x89..0x8D System-Menu*. The exclusive open fails
  as long as XBMCHelper is running (0xe00002c5).
- YouTube: without sign-in (since 2026-11-04, see decision log).
- Mediatheken: official APIs (ZDF api.zdf.de, ARD api.ardmediathek.de, ORF
  api-tvthek.orf.at) — derive endpoints from MServer. MediathekView film list
  (`liste.mediathekview.de/Filmliste-akt.xz`, 77 MB xz / 477 MB JSON, 717k entries,
  fields: Sender,Thema,Titel,Datum,Zeit,Dauer,Größe,Beschreibung,Url,Website,...,
  empty fields = same as predecessor, "Url Klein/HD" = "offset|suffix") only as a reference.
- media.ccc.de: `api.media.ccc.de/public/{conferences,events/recent,events/<guid>}`.

## Feature template from the old Kodi setup (ideas only!)
Home: Übersicht / Neue Folgen / Begonnen / Sendungen / YouTube / Handy-Streams.
YouTube: search, open link, channels+subscriptions, history+continue watching, playlists,
queue, downloads, pair phone (Lounge API "Mit TV-Code verbinden").
Subscription options: lookback (2w..10y), retention (time / max. files), no streams,
minimum duration (ARD 900 s), 720p H.264/AAC MP4. Kiosk: keep display awake during playback,
ignore the first remote press after wake, center button in fullscreen = info, no
setup assistants over the app. Player: remaining time + "Endet um", autoplay next episode.
Import watched/resume state once from Kodi `MyVideos116.db`.

## Expansion stages
1. Core: UI engine, home, local library, player, keyboard + remote helper.
2. Sources online: ZDF/ARD/ORF/CCC natively, YouTube via the YouTube engine.
3. Subscription engine natively (replaces ytdl-sub + LaunchDaemon com.ytdlsub.run).
4. Phone pairing (Lounge), Kodi import, release DMG, replace XBMCHelper/Kodi autostart.

## Guiding principle "Excellent UX" (user requirement 2026-11-03, BINDING, top priority)
"UX ist super wichtig, exzellente professionelle UX soll unbedingt gewährleistet werden.
Alles selbsterklärend und intuitiv." (UX is extremely important, excellent professional UX
must be guaranteed. Everything self-explanatory and intuitive.) For every feature this means:
- Discoverable without instructions: make hidden gestures visible (the header shows
  "OK halten: Optionen" as soon as focus is on something with options).
- Smart-TV menu navigation, always designed for the 7-button Apple Remote (Menu = back,
  Play/Pause plays directly, OK hold = options, MENU on home = power).
- Labels in the user's language ("Energie", "Neue Folgen automatisch laden"), no tech speak.
- Most important first (options: Abspielen → Download → Gesehen …).
- Destructive actions only with a confirmation that names the consequence ("Ja, 7 Folgen löschen").
- Empty states explain the next step; every action gets visible feedback (toast).
- Before "done": check the UI via dev screenshot.

## Guiding principle "Premium experience" (user requirement 2026-11-03, BINDING)
Sofa is **not a download manager with a library** (like Kodi + ytdl-sub used to be), but
per source a **native client that streams AND works offline – like YouTube Premium**.
Applies to ALL apps (YouTube, ZDF, ARD, ORF, CCC …); the implementation may differ per source.
- One video = one object with states: online · downloading (x %) · available offline.
  Same ID online/local (`externalID`), shared progress, the local copy is
  preferred automatically (quality, instant start, offline).
- Actions directly on the content (context menu/Select long): "Herunterladen", "Download
  löschen"; on a channel/show: "Neue Folgen automatisch laden" (+ number to keep).
  = the subscription engine (replaces ytdl-sub), runs silently in the background.
- "Downloads" area per app (+ across apps on home), storage display,
  "Gesehenes automatisch löschen" (smart downloads).
- Offline (no network): the app shows its downloads instead of an error page.
- Sofa manages new downloads itself: own storage location + DB table `downloads`
  (source ID, item JSON, file, status). NO Kodi compatibility needed anymore (user
  2026-11-03: "Kodi brauchen wir bald wirklich nicht mehr berücksichtigen") → no
  NFOs/~/TV Shows structure for new downloads. ~/TV Shows (ytdl-sub legacy library) is
  taken over once (ID from NFO, progress local:… → source ID), afterwards the
  folder scan goes away. No separate library concept in the UI ("Meine Sendungen" disappears
  as a special world → channels/shows with offline marker). Kodi only remains a
  manual fallback until the user releases it.

## Decision log
- 2026-11-23: **A player whose engine session is gone reopens instead of "ending"** (Build 32).
  2026-11-22 19:38: a video paused for a day resumed; the engine had closed its session after
  10 min idle, mpv met 404s and reconnects for 1.5 min, a seek failed, and the player took EOF for
  the end ("end -> leaving"). The engine now names the session in that 404 (`gone`); Sofa posts
  SessionsLost for that sid only (`SFApp playback:lostIn:` picks the affected stream); the player
  reopens at once (playing) or on play (paused). Live dev check (`ytclosesession`): paused, close,
  play -> reopened at 21 s, first frame 0.4 s; playing -> detected at once (the 60-s reopen guard
  still ends a repeat right after a reopen, by design). All suites pass.
- 2026-11-23: **Replace a refused YouTube document at once; a paused player no longer pins it**
  (Build 31). Videos stalled at 60 s for 11 minutes: stream protection refused the PO token
  (SPS 3) of a document open for two days. The 6-hour refresh had not run since 2026-11-21:
  a player left paused with the screen off (2026-11-22 19:43) blocked it for 22 h. Every refusal
  in the logs came from such a stale document, none from a fresh one, and the in-page minter
  renewal never helped. Now (1) a refused token is reported to Sofa, which reloads the document
  at once - also under a playing player, which reopens at its position - at most every 15 min;
  (2) the age refresh waits only for a playing player or a pause under 30 min; (3) a player
  paused while its session service goes away reopens on play instead of in the dark (repeated
  dark reopens would have tripped the reopen guard). Validated: all suites, new forced-refresh
  unit test, live dev instance (paused: reopen on play at 15 s; playing: reopen at 180 s/376 s,
  first frame 0.2-0.4 s; second refusal within the gap: no reload). Dev command `yttokenrefused`.
- 2026-11-20: **Recover missing audio independently of video** (Build 30). Production
  stalled at audio 20 s while the combined SABR run still delivered video (frontier 27 s,
  SPS 1, HTTP audio wait expired after 25 s). Per-track advancing-media clocks prevent one
  track from masking the other's stall. After 8 s without audio progress for a live missing
  media read, start an audio-only run at the missing position; prefer and retain that run on
  later ticks. New reads/seeks get fresh grace, buffered reads/hints/linger do not rescue.
  Existing pump/start/backoff limits apply; unneeded recovery stops normally. No buffer or
  browser-pref changes. Backup/evidence: ~/Library/Logs/sofa-audio-fix-20261120-200114.
  Validated: 116 engine tests incl. typecheck, native playback regressions and architecture
  check passed. Six of seven new regression tests fail against the saved old scheduler; all
  seven pass with the fix. Live affected title delivered 105 s video / 110 s audio with SPS 1;
  idle page refresh/reconnect passed. Installed 20:07:45 via tools/sofa-deploy while idle.
  Installed executable/extension match the tested build; DB quick_check OK (1 download,
  346 progress entries, 135 follows). Engine and Lounge ready again. Build 29 is .prev and
  independently backed up. Long-term behavior still needs observation.
- 2026-11-20: **Bound the YouTube document's lifetime** (Build 29). A production page open for nearly
  three days stalled two videos at 60 s (SPS 3); minter renewal did not help. A fresh document with
  the installed engine and production prefs accepted the same video past 100 s. Refresh after
  six hours when idle, using document age across Sofa handovers; queue callers while reloading,
  recheck sessions/pending calls in the page, protect an open/paused native player. Normal page
  readiness and Lounge reconnect handle the replacement; no browser restart or identity reset.
  Installed 19:04:57 via tools/sofa-deploy. 109 engine tests, player regressions, live checks
  with a private copy of the production identity and native idle refresh passed; installed files
  match the tested build, DB quick_check OK, no rejection/stall in the first ~6 min afterward.
  Backup/evidence: ~/Library/Logs/sofa-youtube-fix-20261120-184606; .prev is Build 28.
  Exact server-side rejection criterion remains unknown. The `/att/get` challenge experiment was
  rejected in a controlled live check and removed. Details: docs/youtube-engine.md, "Document lifetime".
- 2026-11-03: Objective-C/AppKit/CA/AVFoundation chosen (native, no runtime ballast,
  hardware decoding; Kodi renders constantly via GL → CPU/GPU load). Name "Sofa".
- 2026-11-03: yt-dlp only for YouTube; everything else our own.
- 2026-11-03: Premium principle instead of download manager (see section above).
- 2026-11-03: Kodi compatibility no longer a criterion; downloads in Sofa's own storage.
- 2026-11-03: Migration done, ytdl-sub off; Kodi import (SFKodiImport) removed.
- 2026-11-03: Following instead of download subscriptions (user): "Folgen" is the core (new episodes streamed, Meine Sendungen/Kanäle, one shared Sofa list, YouTube account channels taken over once); "Automatisch herunterladen" only an add-on per followed show (the 128 taken over stay on). Downloads = a state of a video (fast start, offline), no longer a separate area in the foreground.
- 2026-11-03: No multi-user concept (user): the device is shared, everything is shared (history, continue watching, subscriptions). No sign-in/Firefox hints in the UI.
- 2026-11-03: ORF via libcurl + local HLS proxy instead of NSURLSession (10.9 TLS too old). User priority afterwards: YouTube + phone pairing.
- 2026-11-04: **No YouTube sign-in anymore** (user: the subscription/"Später ansehen" import was only a
  one-off import for us; no dependency on Firefox or similar). Firefox cookie reading, SAPISIDHASH,
  account feeds (FEsubscriptions/VLWL/FEchannels) and the cookie file removed; follows/watch list are
  Sofa's own data. yt-dlp without cookies: JS challenge with node instead of QuickJS (4 s instead of 20 s per video).
- 2026-11-06: **Firefox becomes the YouTube client** (user; supersedes "no dependency on Firefox" of
  2026-11-04 - that was about the sign-in/cookie import, the account stays out): all YouTube traffic
  through a bundled headless Firefox for one real-browser identity. Goals: section "YouTube client goals".
- 2026-11-17: **Less disk load on the SMR disk** (user approved review items 1-3; Build 23). The engine's
  HTTP cache is RAM only (`browser.cache.disk.enable=false`, memory 64 MB, SFYTBrowser.m): on disk it
  held ~1 GB, 986 MB of it SABR answers (POSTs, never served again; the media store keeps the bytes),
  ~12.5 MB/min written while playing and its index rebuilt after every hard restart. Sofa.log rotates
  at 4 MB while running too (SFCore.m). The picture disk cache is capped at 150 MB, least recently
  read first (SFLayers.m). The `ytEngineDebug` diagnosis switch was switched off (94 % of the log).
  Not done on purpose: `synchronous=OFF` (crash safety), fetch `cache: 'no-store'` (adds request
  headers), turning off Alt-Svc/HTTP/3. Review: ~/Library/Logs/sofa-efficiency-review-2026-11-17.
- 2026-11-17: **Slim engine browser** (user: as lean as sensible; Build 24). Off in the engine profile:
  new-tab page and its feeds (activity stream, contile, weather, Pocket, preloaded about:newtab),
  history, thumbnails, Safe Browsing updates, telemetry/studies/experiments/crash uploads, add-on/
  search/system-add-on update checks, captive-portal/connectivity probes, search suggestions,
  translations/ML, session store every hour instead of 15 s (SFYTBrowser.m, each with its reason).
  Hard limit: nothing a page can see or that changes requests to YouTube - so page-driven
  prefetch/preconnect, favicons, push, GMP codecs, remote settings (certificate revocation) and the
  spare content process stay. The browser restarts early when idle: past 2.2 GB and no session for
  two memory checks (~10 min) (SFYTEngine.m; the hard limit stays 3 GB).
- 2026-11-17: **Rest mode and thermal-aware load** (user: efficient everywhere, smart, integrated;
  Build 25, review fixes Build 26). "Ausschalten" and the sleep timer end playback (position saved),
  turn the screen off and Sofa rests (SFRest; also when macOS turns the screen off - never while a
  video plays on): no stall pings or pointer watchdog, no prebuffer/focus preload, follows in
  batches (~2 h by day, 4-6 h by night, jittered, SFRefreshBatchStep), the engine's processes at
  background priority (PRIO_DARWIN_BG, SFYTPriority: one serial queue applies the wanted state, also
  to a new or taken-over browser). The engine keeps running (a restart = a new page + attestation,
  bot risk); "Nachts ganz ruhen" (Energie, default off) ends it and the phone connection at night.
  A key or the screen waking ends the rest at once. Fan daemon sofa-fand (helpers/sofa-fand, own
  agent), datagrams only (SFFanLink, interface v1; the daemon does no disk I/O): Sofa sends its
  context (playback + volume, idle, ruhe; heartbeat 30 s, fire and forget) from a bound socket, the
  daemon answers with its thermal level; no answer for 120 s = level 0, a broken datagram keeps the
  last level. Warm = background work waits (prebuffer, preloads, follows/Home refreshes, decorative
  animations), hot = also no new download and an earlier idle restart (1.8 GB, never a restart
  during playback - the hard limit stays 3 GB), critical = new videos at most 720p.
- 2026-11-17: **Quiet disk while idle and resting; RAM where it pays** (user: the disk was heard
  seeking every few seconds; 16 GB, ~11 GB free; Build 27). The engine's Firefox profile runs on a
  512 MB RAM disk (SFYTRamProfile: hdiutil ram://, HFS, no Spotlight/fseventsd); the disk
  profile stays the lasting copy - changed files go back every 30 min awake, every 2 h at most
  resting, and when the browser ends (SQLite through the backup API, so storage.sqlite.exclusiveLock
  is off; files renamed into place, stale WALs removed first, deletions mirrored, caches never). A
  reboot fills the RAM disk from the disk profile again. TMPDIR of browser and display on it (not
  /var/folders: noatime is on, dirhelper would remove files there it thinks unused for 3 days). The
  log waits in memory (30 s awake, 10 min resting; failures, 64 KB, exit and a crash handler write at
  once). The picture cache counts uses itself (SFImageDiskLRU) - noatime leaves st_atime at the
  creation time. Review leftovers: the fan socket is bound again when its path vanishes, a night
  re-stop happens at most once a night (SFYTNight), PIDs written under the lock.
- 2026-11-18: **The site Cache API store stays in RAM** (user; Build 28): `storage/default/<origin>/cache`
  (caches.sqlite + WAL + morgue bodies) is skipped by fill and sync - its database stays locked
  exclusively despite shared locking, so every sync failed on it (night measurement 2026-11-17/18).
  The stale disk copy (bodies copied by Build 27, database never) is removed once, so a browser on the
  disk profile (rollback) starts it empty instead of mismatched. Firefox recreates it after a reboot.
  And the rest of the rest-mode writes, from the night measurement (Sofa/engine ≈97 HDD writes/h of
  ≈1390): the log waits up to an hour at rest (failures and waking write at once), pictures loaded at
  rest stay in memory, the follow batch writes its check times in one transaction at its end, and
  the RAM profile is synced at most every 4 h at rest (2 h before). Left: the sync bursts themselves,
  sofa.db/cache.db in the follow batches, cfprefsd touching a firefox domain (~7/h).

## Dev loop (closed loop, does not disturb the real app)
- **Rule (user 2026-11-04): install every change live immediately after testing**
  (`tools/sofa-deploy`, swap during playback < 1 s) and check in SofaRemote.log
  ("update installed", no "forcing").
- `tools/sofa-dev cycle` = build + invisible instance (`--dev`: offscreen window,
  ActivationPolicyProhibited, muted, no power assertion) + check.
- `tools/sofa-dev do "key down" "shot name" ...` → PNG in /private/tmp/claude-501/sofa-shots.
  Screenshots via `renderInContext` (the window server does not capture offscreen windows;
  video layer, masks and 3D transforms do not appear in them → solve effects image-based,
  e.g. backdrop gradients are baked into the image).
- No web server (removed 2026-11-07; the user views the screen via RustDesk). Measuring on the
  real app: its FIFO `~/Library/Caches/Sofa/sofa.fifo` takes `key <k>` and `framemeter on|off`
  only (e.g. `echo 'framemeter on' > ~/Library/Caches/Sofa/sofa.fifo`); dev instances take every
  command over theirs (`sofa-dev do ...`).
- Log `~/Library/Logs/Sofa.log`, stderr `~/Library/Caches/Sofa/dev.stderr`, crash reports
  are reported by `sofa-dev check`.
- CA pitfall: `actionForKey:` must return nil (not NSNull).

## Hardware requirement: Apple Remote aluminium (2011), 7 buttons
Up, Down, Left, Right, Center, MENU, Play/Pause — NO home button. Everything must be
fully operable with it. Mapping: MENU = back, MENU long = home;
Center = OK, Center long = context menu; Left/Right long = seek (player);
In the player: Up/Down (+/-) = system volume (CoreAudio VirtualMasterVolume,
1/16 steps, HUD), holding repeats. Play/Pause = playback. Long-press detection in the helper
(timing), the web viewer maps exactly these buttons. No feature may require keyboard/mouse
(text input for search → own on-screen keyboard).
- 2026-11-05: **Mixed Home rows from all apps** (user: apps feature content on Home, mixed lists
  filled from several apps). Concept: topics defined in Core ("Jetzt live", "Highlights"), apps
  contribute per topic (`homeFeatures:`), structurally from their start page (live = kind live,
  highlights = the editors' lead shelf; no title heuristics), merged round-robin in registry
  order, app logo on every tile, stored + refreshed every 30 min. Home only offers what plays
  here: `drm` and items whose `geoRegion` the device is outside of are left out (region state
  learned from geo checks, ZDF probes once). Found while testing: Das Erste outside DE is NOT
  blocked (302 to the `int` feed, `isGeoBlocked` only means "programmes partly replaced") ->
  ARD needs no region; ZDF `/de/` paths are hard 403. Next topic candidates: "Nachrichten"
  (tagesschau API / ZDF heute / ORF ZIB from proper raw sources), Dokus/Filme; YouTube stays out
  (bot-flagged IP, keep requests minimal).
  Review (background agent, same day) fixed: row signature now over the full stored item (a new
  broadcast changes ref/drm/subtitle under the same id), region knowledge only from definite
  answers (2xx/403/451/wrong text; 5xx, refused HEAD, network errors teach nothing; outside valid
  6 h, inside 24 h), a topic an app leaves out keeps its old items (ORF on a failed request),
  showsSourceMark not copied (leaked into "Später ansehen"), badges stored. Regression: tools/test-home.
- 2026-11-17: **No system sleep from Sofa any more** (user; removed, brought back, removed again the
  same day - Build 24). The iMac hung waking from sleep: it ran on from RAM (ssh worked) but the disk/
  SATA link did not come back after standby - disk errors, nothing could be written (host diagnosis
  ~/Library/Logs/crash-diagnose-2026-11-17/bericht.md, Nachtrag 4). Sofa's "Energie -> Ruhezustand"
  (`pmset sleepnow`) was practically the only trigger (pmset sleep 0). The entry and SFPower
  systemSleep are gone; switching off is the display only ("Ausschalten", sleep timer).

## Backlog (user requests — queue, tick off when done)
- [~] 2026-11-07 **YouTube engine in Firefox: roll out** (goals above). DONE: engine in the page via
      the extension (stream protection accepts it, `sps=1`), `SFYTEngine`/`SFYTBrowser`/`SFYTChannel`/
      `SFLocalHTTP` replace the node sidecar in Sofa, live-verified (test-playback 9); node sidecar,
      jsdom, identity/transport removed from the repo. OPEN, in order:
      1. ~~Release bundle: Firefox + Xvfb + Mesa relocatable in Contents/Runtime~~ (2026-11-07:
         firefox-x11 rev 3 opens libGL relative to itself; test-release all ok with /opt/local
         denied, WebGL included; DEPLOYED 08:27 via sofa-deploy --bundle - the installed app runs
         the engine, no node). Leftovers: ~~libepoxy (GTK's GL loader) named
         /opt/local/lib/libGL.1.dylib~~ (backport-toolkit libepoxy rev 5 opens @loader_path/libGL.1.dylib;
         make-release puts it beside libGL in Runtime/lib - next release build);
         ~~relink.py copied libmozglue + libnss3 into Frameworks~~ (gmp-clearkey reached them through
         MacPorts rpaths; now linked to the copies in Runtime/lib/firefox - next release build).
      2. ~~EU consent dialog in a fresh profile~~: accepted with a trusted XTest click (2026-11-07,
         consent.ts + SFYTPointer; LIVE 08:27 on the real profile's first start: detected, 4.9 s
         read, clicked, page reload, new lasting visitor id). Minor: a background open before the
         dialog appeared was lost with the reload (one wasted player request, once per profile).
      3. ~~Live HLS segments through the engine~~ (2026-11-07: local `/s/<sid>/seg/<n>`, live-verified
         1080p60; header emulation removed - the browser sends its own, a custom header meant CORS).
      4. ~~"Platz schaffen" availability (oEmbed over libcurl)~~ through the engine (2026-11-07,
         `availability`; unit-tested, not yet live).
- [~] ZDF / ARD / ORF natively per `docs/mediathek-apis.md` (mark geo/DRM restrictions). ARD+ZDF done (geo check before start), ORF done 2026-11-03 (TLS bridge, highlights `_embedded.video_item._embedded.item`, QXA streams only; individual qualities → 403). Maybe 3sat/ARTE later.
- [~] **Design system + TV UI framework** – APP ARCHITECTURE DONE 2026-11-05 (branch arch/apps,
      merged): SFApp protocol + registry, all five apps converted, player hooks, generic end cards,
      theme tokens instead of identifier checks, remote service + SFPlayerHost, src/Browse layer,
      SFTileStatusSource, home sections API, Example app, check-arch, docs/architecture.md +
      docs/new-app.md; review agent found 5 issues, 4 fixed (CCC start page frame accepted).
      OPEN (add when a second user appears): settings contributions per app, extra context-menu
      actions per app, component gallery (`open gallery`), docs/ui-framework.md, motion/spacing
      tokens. Original request (user 2026-11-05: "in ein konsistentes wiederverwendbares
      design system und framework umwandeln … auch das framework für die steuerung"; not urgent, but
      keep it in mind with EVERY UI change). Goal: easy extension (new apps/pages/dialogs without
      copying layout code). Scope:
  - Tokens: SFTheme as the single source for colors, type scale, spacing (U()), radii, motion
    durations/curves, opacities (backdrop 0.75/0.4, dim text) – no literals in screens.
  - Components: tile (SFTile styles), shelf/grid, hero, header bar (logo, Suche, status pills,
    OK-hint), side menu (SFMenuScreen: rows, toggles, details, scrolling, edge fade), confirm
    dialog, toast, keyboard, image layer (fallbackSource, fades), icons (SFIconArt), subtitle
    builder (SFDotJoin), empty/offline states.
  - Interaction framework: SFNavigator + SFScreen key handling, focus model (rows/grids, focus
    memory per row, Up to header), long-press semantics (OK halten = options, MENU halten = home),
    standard menus (context menu builder), transitions; one place documenting the remote grammar.
  - Page model: SFPage/SFShelf loaders, reloadSoon coalescing, live reload notifications.
  - Dev tooling as part of it: FIFO commands, screenshots/stream, a component gallery page
    (`open gallery`) rendering every component in every theme for visual regression shots.
  - **App modules (user 2026-11-05: adding a new app should reuse almost all UI, and it must be
    clear where the app-specific logic goes):** today every source is ad hoc (SFProviderZDF/ARD/
    ORF/CCC classes, SFYouTube, scattered registries like SFRegisterAvailabilityCheck /
    SFRegisterShowRefLookup, source-string switches in shared code). Target architecture:
    - `SFApp` protocol = the ONLY place for app logic: identity (id, name, theme, logo), page
      loaders (home, show/channel, category, search + suggestions), item mapping (API JSON →
      SFItem), playback resolving (ref → streams/engine hints), optional capabilities declared
      explicitly (live, downloads, follow/new episodes, availability check, show-ref lookup,
      phone pairing) – the core asks the app instead of `if source == …`.
    - App registry: one list of apps; home tiles, search, follows, downloads, stats iterate it.
    - **Clearly defined integration APIs (user 2026-11-05):** how an app plugs into Sofa AND how the
      Sofa home page is composed. Home = composition of contributions: each app (and core
      services: continue watching, watch later, new episodes, downloads, history, settings,
      phone) contributes home sections via a declared API (section id, title, priority/order
      rules, item source, refresh trigger, empty/offline behaviour); the home layout engine
      merges them – no app code in SFHome. Same for search (app search providers + merged
      results), context menu actions (core actions + app actions per item kind) and settings
      (app settings pages registered, not hard-coded). Versioned, documented in
      docs/app-api.md with the template app as the executable example.
    - Shared core stays app-agnostic: library (downloads/storage/keep), progress/history, follows,
      watch later, player + engines, net/cache, settings.
    - Folder layout: src/Framework (UI + interaction + page model), src/Core, src/Apps/<App>/
      (one folder per app, everything app-specific inside); docs/new-app.md = checklist +
      a minimal template app; a test hook per app (tools/test-* via the app protocol).
    - Migrate one app first (media.ccc.de, the smallest) as the reference, then the others.
  - Way: incremental – extract when touching code (no big-bang rewrite); docs/ui-framework.md as
    the contract; each extraction verified by screenshots in all themes + test-all.
- [ ] Periodic background review agents (user request) — after every larger building block.
  - 2026-11-05 12:10 review (tile subtitles, recent downloads, AV dev frames): no real bugs; hardened SFDotJoin (variadic, ARC-safe temporaries) and the dev output attach (active player only).
  - 2026-11-08 player review (16 findings, #2/#6/#7 fixed earlier), remaining 13 fixed: a stream broken after its start (any source, not only app sessions) is reopened once at its position - an early EOF of a plain stream used to count as "finished", an error midway left a dead "Verbindung unterbrochen" (test 7b); chosen audio/subtitle tracks carry over a reopen (by title); Play/Pause while loading decides how it starts (test 7); one leaveEnd for seek/replay at the end (up-next card and countdown go); the end waits up to 4 s for a recommendation still on its way; seek state reset on item switch; jumps before the first frame count from the start point; the stall watchdog also watches paused opens (test 7); resolve time limit 45 s and one failure format (failShowing:/failWith:); a track menu applies to the engine playing now; the navigator drops OK/Play for 0.3 s while a screen closes (double press, test 3); a failed queue/playlist entry moves on after 5 s (test 4b); routed image fetches wait at most 30 s. Tests added the same night: 4c (the end waits for a late recommendation, and leaves after the limit; Example app `upNextForItem:` behind SOFA_EXAMPLE_UPNEXT), 6b (a hand-chosen subtitle track survives a reopen; dev command `breakstream`). Then the last two: 4c also checks that a jump pending on the up-next card stays with the old video (seek reset per item), unit test imagefetch (a routed fetcher that never answers; limit shortened via SOFA_IMAGE_FETCH_LIMIT, runs in 0.5 s).
  - 2026-11-05 15:00 review (architecture refactor): end-card playlist id (autoplay left the list), tile status set after the first page (no progress at launch), unknown app crashed appScreen – fixed; CCC start page now framed like the other Mediatheken (accepted, CHANGELOG).

- [ ] **YouTube bot checks are behavioural** (analysis 2026-11-07 evening, user: "es muss an unserer Implementierung liegen"). LOGIN_REQUIRED came on every day with downloads (11-05: 20, 11-06: 28, 11-07: 8), not only after today's restarts. Ruled out by measurement: player/sts mismatch (the page itself loads player a5c2aafe = the engine's), PO token rejections (none), exit node/VPN (none; residential Mtel Austria, IPv4 changed .106 -> .17 by a router restart, same /24), WebGL softpipe (stream protection accepted it, sps=1, 2026-11-06). What a real browser does and the engine does not: (1) 50-130 player requests and 40-70 whole-video downloads a day as a logged-out visitor; (2) no playback reporting (stats/playback, stats/watchtime) - it fetches videos it never "watches"; (3) /player alone from the home page, no watch navigation with /next; (4) downloads at full speed. Plan (order proposed to the user, pacing amount awaits their decision): A) act like the web player: /next + /player per watch, playback/watchtime pings in step with mpv for watched videos; B) human download volume and pace (fewer per day, spread, rate-limited) - DONE 2026-11-07: YouTube starts 60 min (+ up to 30 random) apart, at most 18 subscription downloads per 24 h (SFApp subscriptionDownloadsPerDay, SFDownloadBudget; manual downloads only spaced), ffmpeg already reads at most 3x real time; C) the engine outlives Sofa restarts (below) - DONE; plus pictures and the lounge through the engine page (2026-11-07). A) waits for a capture of what youtube.com's own player sends (stats/playback, watchtime: params, cadence, cpn = the SABR one) - recorded in a dev Firefox after the bot-check pause, then rebuilt; youtubei.js' addToWatchHistory/updateWatchTime are rough approximations (fixed fmt=251, one final watchtime) and would look less like a browser, not more.
- [ ] **Bot checks 2026-11-07 15:01 and 16:01** (LOGIN_REQUIRED on player requests, both for download 9rqyfE0SRP0): after ~25 production restarts that day, each with two engine pages until the double start was fixed. The breaker doubled the pause (60 -> 120 min, until 18:01) and the first request after the pause was the same background download. Rule until the identity is calm again: no production restarts/deploys for testing, batch deploys. Open question (measure, don't guess): should the first request after a pause be a foreground one rather than the download that ran into it?
- [ ] test-downloads 8c flake under load (2026-11-09 00:15, load average 5.9, real app downloading): "a download: the timeline shaded end to end" got "player: stored 1 range(s), 59 of 60 s" for a complete download - the file shade comes only from SFMP4Index + the store's extents (no hasComplete), so the first answer covered < 59.5 s; 3 of 3 runs alone green. Suspect: the check reads the first "stored" line - find whether an early answer can miss the last chunk(s) (index parsed before the last write landed? extents copy vs. a refill) before touching the check. Not reproduced in 4 loaded runs (next to test-playback); since then a failing check keeps the instance log (test-all: /tmp/sofa-testall-failed/test-downloads/part-*-fail*.log) - read it at the next occurrence. 2026-11-09 15:15: 6 more loaded runs of part c green (next to test-units + test-home; the fixture is 180 s since the prebuffer work, the file part runs unthrottled since 15d3c96).
- [ ] Rare test-sofa-yt flake under test-all load (2026-11-07 evening, three times: unit-engine "injects as a preload script" - headless Firefox hung right after "You are running in headless mode", no BiDi port in 30 s, while a normal start prints it in 2-3 s (measured). Mitigated: firefox.ts ends a hung start and makes one fresh start, logged "firefox.ts: start hung"; cause of the hang still unknown - watch for that line) (2026-11-07: two found and fixed - unit-live "idle live sessions expire" raced its 50 ms idle window, unit-session "language switch" asserted a wasted second SABR run that a real bug caused (covers() before the index; fixed in session.ts); the 2026-11-06 one was an `assert.ok` with its own message, so possibly a third - keep watching) (2026-11-06, once in 6 runs: an `assert.ok` with its own message false, name lost in the tail; then 0 failures in 14 further runs - the one failure coincided with the real app relaunching on the same CPU). test-all now prints failing check names; catch it next time. Suspects (short deadlines under load): unit-process "request took < 1500 ms", unit-session "pull resumed" (3 s), "expired"/"pumps stopped" (3 s/2 s). Do not widen deadlines blindly.
- [ ] **mpv / playback performance optimisation without quality loss** (user 2026-11-07): measure first (mpv frame drops / vo-delayed frames / decoder load per format: VP9 1080p60, AV1, H.264; CPU share of Sofa, mpv, the engine's Firefox, ffmpeg downloads during playback), then optimise what the numbers point at - e.g. hwdec where the GPU can (VideoToolbox on 10.9: H.264 only), decoder threads, vo/opengl settings and render path (SFMPVLayer), demuxer cache sizes, the engine's media path (read sizes, copies), background work while playing. Never lower resolution, frame rate or codec quality; each change with a before/after measurement. Related: "Video decoder at high priority". STEP 1 2026-11-07: frames were delivered through the main thread (mpv update -> main queue -> setNeedsDisplay -> draw in the main commit, the render blocking there until the frame's display time): every main-thread stall dropped frames and the waits took UI time. SFMPVLayer is now an asynchronous CAOpenGLLayer: CA asks at every refresh, draws when mpv has a frame (update callback sets a flag), _rc guarded by a mutex against retire. CORRECTION (sample 2026-11-07 23:53): on 10.9 CA asks from a timer on the MAIN run loop (CAOpenGLLayer_timer_callback) - rendering incl. the frame's glTexSubImage2D upload is still main-thread time, the first frame's shader setup 115-250 ms. STEP 2 2026-11-07: render never blocks for the target time (a shutting-down vo held the draw and CA's layer lock 200 ms per close), mpv's render-thread work (reconfig, controls) runs on a queue of its own with the GL context (a layer off screen - display asleep, offscreen window - stalled the core and every main-thread property read for seconds: the playback-test flake), canDraw/devCopyFrame lock context then _rcLock. STEP 3 DONE 2026-11-08: a render thread of its own - a private CGL context (created with the layer, so the render context exists as soon as mpv is set) whose textures CA's context shares; mpv renders on the render queue into one of two textures (fences both ways), CA's draw only blits the newest (glBlitFramebuffer) and takes none of mpv's locks; a size change re-renders the current frame (no still-frame retry loop). The mpv core itself is created on a setup queue (mpv_create/initialize were ~220 ms main-thread time per open, visible once the render had left). Real screen, ARD download 50 fps, muted: open without any hitch (before: 270 ms), first frame 0.2 s after open (before 1.7 s), 10 min played - dropped 0, delayed 0; close 39 ms. SHELVED 2026-11-07 (patch in the session scratchpad, rebuild clean): display-synced output (video-sync=display-resample + interpolation tscale=oversample, display-fps-override from CVDisplayLink - the panel runs at 59.838 Hz, its mode reports 0): in an offscreen window CA draws at ~5 fps and A/V drifted apart (test-playback); needs switching by window occlusion (NSWindowDidChangeOcclusionStateNotification); the own render thread it needed is there now (STEP 3). BASELINE to compare (vo drops): 30 fps 0.08 %, 50 fps 1.13 %, 60 fps 0.37 % - re-measure from the log after a few days of plays (`grep 'mpv: played to' ~/Library/Logs/Sofa.log*`). MEASURED 2026-11-08 (Sofa.log since 11-06, plays >= 30 s): ~280 min of real playback, VP9 1080p25 (92 min), H.264 1080p25/30, 720p - 0 dropped frames, 0 delayed; Mediathek HLS 0.38 drops/min. Frame drops are no problem; the open question is CPU (heat, the old PSU). hwdec stays off (VideoToolbox fails on 10.9, measured 2026-11-04). Since 2026-11-08 23:4x every playback's stats line carries "Sofa CPU N% of a core while playing" (only the seconds that played) - aggregate per format from real use before changing anything (candidates then: vd-lavc-threads, scaler/vo options, the render path's copies).
- [ ] **Whole-UI smoothness like the mpv frame path** (user 2026-11-07: "ähnliche Optimierungen für das gesamte UI, super smooth"): find work on the main thread during animations and key handling and move it off - image decoding/scaling and text layout (SFLabel draws) on background queues with the result committed in one step, layer trees for rows/panels prepared before they slide in, no synchronous disk/JSON/locks on main (SFStore setting: barrier_sync seen 1 s at launch in the hitch log 2026-11-07), animations purely in the render server (no per-frame main work), rasterize static composites (shouldRasterize) where it measurably helps. Measure each with the hitch monitor (main stalls) and SFFrameMeter (composited fps) before/after; target: no hitch > 33 ms during navigation, 60 fps for every animation. PROGRESS 2026-11-07 (real screen, frame meter on in production): (a) hero text drawn off the main thread (SFLabelLook) - a colour emoji at hero size cost 110-180 ms per glyph on its first draw (title with three: 540 ms) and froze navigation; (b) every visible shadow has a shadow path; (c) backdrop edge fade baked again (a layer mask re-renders offscreen per frame). Shelf changes: 59-62 fps since 22:50 in every bench, but phases at 26-41 fps happened (13:43-13:58, 22:41-22:49) - ruled out as sole cause by experiment: CPU load (4 busy cores: 59 fps), GPU clock after display sleep, idle, a preceding playback, backdrop/masks/corners/text/hero fade/row fade, downloads (no correlation); VRAM paging occurs without fps drops. Removing all shadows at 22:49 coincided with the phase ending. Open: catch the next slow phase in the production frame-meter lines with GPU stats (ioreg PerformanceStatistics) and the user's time stamps.
- [ ] **YouTube start takes 6-13 s** (2026-11-07, 72 plays in the log: median 5.8 s to the first frame, p90 12.4 s, max 19.1 s; since 22:10 nearly every resume 12-13 s): the log is silent between "player: play 127.0.0.1 via mpv" and "mpv: first frame" - instrument the chain (engine session open, first byte the proxy serves, mpv's open/probe/seek to the resume position, first decoded frame) and fix what the numbers show; compare resume vs start from 0. FINDINGS 2026-11-08 (instrumented, muted plays on the real screen): a resumed start was three SABR runs one after the other, each ~5 s: (1) the header (init) from the first run, (2) a run from 0 for mpv's open (demux_mkv reads the first video packets: probe_if_image, no option), (3) the seek to the resume position. Every run's FIRST answer carries `nextRequestPolicy.backoffTimeMs` ~4800 ms and an empty playbackCookie (sps 0); googlevideo waits it out, the second request brings media (sps 1). DONE: (3) gone - the player tells the engine its start point (SFApp playback:startsAt: -> engine startsAt -> session hint), media there is fetched while mpv opens; (2) in progress - the engine serves a WebM's first Cluster ID (VirtualFile.known), mpv overlay port gets `--demuxer-mkv-probe-image` (patch-mkv-probe-image.diff, rev 10), Sofa sets it to no; verified locally (stall server, resume at 90 s: 20.1 s -> 0.1 s, no read from the first cluster), deployed 2026-11-08 01:16 (local bundle); prod measurement 2026-11-08 (debug switches ytEngineDebug + mpvDebugDemux, both removed afterwards): still ~14 s - two more causes found and fixed: (a) mpv's reference probes (playlist/directory demuxer) peek 8 KiB, past the Opus track's 4.7 KB header into media at 0: the audio opened only after a run from 0 -> `access-references=no` for DASH tracks (SFMPVEngine loadURL; test-playback 8d, 8 s -> 1 s); (b) mpv leaves its header parse's connection open after seeking: the engine took it for a demand, started a run from 0 and stopped the run at the resume position as "ran ahead of every reader" (also in the ms gaps between mpv's 1 MiB requests) -> one track = one sequential stream, only its newest request is a demand (Track.latestRequestAt, unit test). Also found: libmpv without cocoa lacked cfstr_get_cstr/cfstr_from_cstr (dyld crash on verbose CoreAudio logging) -> overlay mpv rev 11 (patch-coreaudio-without-cocoa.diff). RESULT live 10:29: first frame 6.3 s after open with ONE SABR run (was ~14 s, three to five runs); what is left is that run's first-answer backoff. OPEN: the ~4.8 s first-answer backoff itself - compare with youtube.com's own player on this IP (live-player test, opt-in, daytime, not during a bot-check pause): if the real player gets none, our first SABR request differs (playbackCookie/clientAbrState/PO token); if it gets it too, it is the server's view of this IP. MP4 (AV1/H.264 tracks), checked 2026-11-08 (local DASH-layout file ftyp/moov/sidx/moof, stall server, resume at 90 s): yes - lavf's mov header loop (ffmpeg 9.0.2 mov.c mov_read_default) only stops once it has seen moov AND an mdat, so it parses the first moof and reads to the first mdat header (a run from 0, same ~5 s cost); no lavf option skips it (the tail-4-byte mfra read happens only when the sidx does not cover the file, not with YouTube's files). Prod share: 5 of 210 opens (4 av01, 1 mp4a) - not worth an ffmpeg overlay now; if MP4 grows, the clean fix is an ffmpeg patch that ends the header once moov is found and the sidx index is complete. MEASURED 2026-11-08 (Sofa.log): from the media store median 1.7 s (n=8); online median 4.5 s, p90 8.8 s (n=34) - the resolve is <= 0.8 s, the rest is mpv waiting for the first bytes. The engine's first segment comes after a median 4058 ms (n=430 runs, strikingly constant): SABR request 1 is answered in ~95 ms (headers), request 2 goes out ~4 s later. googlevideo's SabrStream waits nextRequestPolicy.backoffTimeMs before every request -> suspected: the server orders ~4 s after the first answer. Logged since 2026-11-08 21:4x ("request 2 sent N ms into the run (server-ordered backoff X ms)"); confirm from real plays (no live tests at night), then find what makes the server order it (what request 1 lacks vs. the web player - raw data first, docs/youtube.md; YouTube client goals bind: nothing that looks less like the real player).
- [ ] **Main-thread stalls around launch, exit and update** (hitch monitor, real screen, 2026-11-08 log; not during navigation): launch 1.1-1.9 s - `SFHomeFeatures restore` reads its cache synchronously (`cachedJSON` -> sqlite pread on the cold HDD), `NSApplication _setPresentationOptions`, `SFTheme wordmarkFont` (font load), `SFStore rowsNow`; update check `SFUpdater applyIfIdle` 1.2 s in `fileExistsAtPath` (HDD); exit `SFDownloads stopForExit` 1.1 s (usleep while ffmpeg stops); once `enforceCursorHidden` 18 s in `NSCursor set` (window server did not answer, 00:17 - display asleep?). The launch ones sit before/at the first frame, so they delay Home rather than stutter it; fix without breaking "Laden ohne Springen": read the restore data on a queue while the launch screen shows and build Home once it is there (one readiness signal, no second layout), the cursor call off the main thread or only when the cursor is actually visible. Measure launch-to-first-frame before/after. PROGRESS 2026-11-08: the features restore reads on a queue, Home waits for it (whenRestored:) and builds once - launch hitch 623-1920 ms -> 334 ms, rows kept (no jump); left: the first NSCalendar loads the zone database (SFFormatDateShort, ~70 ms, one-time) and _setPresentationOptions (system). Also 2026-11-08: the Mac hung after 02:54 (swap exhausted, kernel suspended prod Sofa first, user rebooted 07:47); cause not reproduced - two guarded test-all runs (memory guard: stops tests below 2 GB) kept >= 8.5 GB free, idle Sofa 225 MB stable during a download. If it recurs: ~/Library/Logs/sofa-memguard/guard.sh (logs the biggest processes every 5 s, outside /tmp). PROGRESS 2026-11-08 evening (hitch log ranked): tile dates without ICU per call (SFFormatDateShortAt, 9x cheaper, was ~150 ms per Home refresh); media store manifests/completeness readable without waiting for its disk queue (was 687 ms after launch); end screen fonts warmed off the main thread before its tiles are built (was up to 1014 ms at a video's start); the cursor stall is gone since the CGCursorIsVisible check (none after 13:15). LEFT: a cold launch (page cache flushed - e.g. right after make-release wrote the bundle) blocks 0.5-1.1 s in SFStore init (sqlite first pages from the HDD) + SFMediaStore open + _setPresentationOptions - behind the launch screen, delays Home only; moving the stores' open off the main thread needs a readiness gate for every early settings read - weigh against the SSD upgrade (memory imac-performance-upgrade-path). UPDATE 2026-11-08 23:51: the media store opens on its queue (readiness group), the dev FIFO's file calls run on a queue - both gone from the launch stall. Left (~0.5 s cold): _setPresentationOptions (system), SFFollows init parsing all follow items (1581) synchronously (~60-100 ms; async needs a readiness gate for isFollowing/items readers - join Home's whenRestored gate), SFStore init's first page reads.
- [ ] **One quick menu: power + settings merged, with Bluetooth headphones** (user 2026-11-08) - STEP 1 DONE 2026-11-08: SFQuickMenu ("Sofa": Ausschalten / Zum Startbildschirm / Ton / Energie / Einstellungen - "Ausschalten" first as the most used entry, user 2026-11-08; named for switching off, not "Bildschirm aus": SFPower switchOff decides what it does - today the display off, smart sleep/wake later), MENU on Home + MENU held anywhere (helper decodes MENU held as 0x0C/0x40 alone), also over the player (plays on, test-playback 1), sound output switch over every CoreAudio output (SFAudioOutput; mpv ao-reload follows), test-home 8. STEP 2 BUILT 2026-11-08: SFBluetooth (IOBluetooth public API: audio-only inquiry, IOBluetoothDevicePair with PIN 0000 / SSP yes, SDP query, openConnection; the system's pairing list is the only memory), Ton menu lists paired audio devices (Verbinden / trennen) + "Kopfhörer koppeln" (live list via SFMenuScreen setOptions:), the sound moves to the device's CoreAudio output (UID contains the address) once it appears; fake radio for dev tests (SOFA_FAKE_BLUETOOTH, test-home 8). VERIFIED 2026-11-08 with AirPods Max: pairing, connect, output switch, reconnect work. LESSONS: (1) AirPods play for one host at a time - while the Samsung Fold held them the Mac stayed "connected" but its audio link took nothing (StartIO timeout) and mpv, whose clock is the audio output, held the video -> SFAudioOutput verify/checkCurrent (IO-callback health check after every Bluetooth switch and when a playing video stands still with data at hand; dead output -> built-in + toast). (2) rapid ao-reloads crashed libmpv's coreaudio hotplug listener (use after free) -> one reload once the output settled. (3) volume: on 10.9 the headphones' own volume is not synced (crown reports nothing) -> no second volume in front: the Mac's at full for Bluetooth outputs, the remote shows "Lautstärke an den Kopfhörern einstellen" (user decision: no pre-attenuation). OPEN: see the dead-output fallback live once (headphones held by another device); battery level / AirPods comfort features (user idea 2026-11-08: Apple's AAP protocol over L2CAP - research whether IOBluetooth on 10.9 can open it cleanly). merge the power ("Energie") and settings menus into one menu with submenus, so everything is quicker to reach. Opens as today from the Home screen, and additionally from anywhere by MENU long press (also over the player: it must not stop playback). DECIDED (user 2026-11-08): MENU hold no longer goes back to Home (SFScreen popToRoot goes away as a key action) - "Zum Startbildschirm" becomes an entry of the quick menu. New in this menu: connect Bluetooth headphones (scan, pair, connect, disconnect; remember the last device and reconnect it) and play the sound through them (audio output switch; mpv's coreaudio output and the system volume follow the chosen device, back to the speakers when they disconnect). Find the clean 10.9 path first (IOBluetooth pairing API, CoreAudio default output device), no guessing; Remote-friendly flow, German texts, regression checks.
- [ ] **UX + robustness sweep of the whole app** (user 2026-11-07): look everywhere for what does not feel smooth or finished yet and for unhandled cases (interrupted transitions, late data, errors, empty states, remote presses during animations); robustness absolutely important (see the rule below). Findings go here as items, each fixed with a regression check.
- [ ] Robustness (User 2026-11-04, standing rule): no ordering assumptions between async subsystems, readiness signal + timeout, watchdog/self-healing for long-lived state, one regression check per incident (`tools/test-playback`, `tools/test-resolver`).

## Display sleep/wake
- macOS manages the timeouts (pmset displaysleep 5, sleep 0); Sofa has NO power
  management of its own.
- SofaRemote: EVERY IR press → `IOPMAssertionDeclareUserActivity` (IR is grabbed
  exclusively, otherwise macOS doesn't see the keys → the display would turn off while navigating).
  Display off (IODisplayWrangler CurrentPowerState<3 or CGDisplayIsAsleep) → the first
  press only wakes (is swallowed).
- Player: NoDisplaySleep + NoIdleSleep assertion during playback, released on pause/end.
  No permanently active audio device (blocked sleep with Kodi).
- The remote wakes from real system sleep via firmware; not reliably from DarkWake.

## Update mechanism (user requirement: immediately, even during playback)
`tools/sofa-deploy` → build into /Applications/Sofa.app.staged. SofaRemote checks every 3 s,
sends the app msg 1000 (SF_MSG_PREPARE_UPDATE): the app saves resume.json (screens via
restoreKey "app:<source>", running item + position), shows "Sofa wird aktualisiert …",
flush, exit. The helper swaps the bundles (old → Sofa.app.prev), `launchctl start de.sofa.app`,
exits (KeepAlive starts a new helper). The new app restores the area + video at
position −2 s. Tested 2026-11-03: ~1 s interruption.
Rollback: rename /Applications/Sofa.app.prev back.
Details: the app exits with `_exit(0)` (exit() hung in framework handlers). de.sofa.app has
KeepAlive{SuccessfulExit=false} (crash → restart). The helper checks process exit via kill(pid,0),
relaunches Sofa if it was running, verifies the
start (up to 6 attempts), ignores keys during the swap.
Remote-shell note: launchctl/open from the Tailscale SSH session (background session) have no
effect in Aqua → `sudo launchctl bsexec <loginwindow-pid> sudo -u imac launchctl ...`.

