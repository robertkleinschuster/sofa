# Sofa — 10-foot media center for the iMac (macOS 10.9.5)

Binding architecture and product notes. **Read before any work on Sofa, update after
every decision** (section "Decision log").

## Goal
A self-made, polished "smart TV" product instead of Kodi: native Cocoa app operated with
the Apple Remote, one area per source with its own look (YouTube, ZDF, ARD, ORF,
media.ccc.de, all Mediatheken), local downloads + streaming + own subscription engine in ONE
program. Intuitive, stable, light on resources on the iMac12,2 (i5-2500S Sandy Bridge, no
AVX2, Radeon HD 6770M, 2560x1440).

## Hard rules (user requirements 2026-11-03)
1. **New, clean monolith.** No dependency on old code (Kodi add-ons
   `script.ytdlsub`, `script.mobilecast`, `~/ytdl-sub/*.py`, run.sh). The old code
   only serves as a source of ideas/features.
2. **Own subscription engine** (replaces ytdl-sub), cleanly integrated (subscribe from every
   source app, scheduling, download, retention, progress in the UI).
3. **Own scrapers** for the Mediatheken, directly against the source APIs; MediathekView
   (MServer, open source) only as a reference for endpoints — **no dependency on
   MediathekView servers** in the final state.
4. **yt-dlp = the only external engine**, only for YouTube (signature/nsig/PO-token
   arms race), encapsulated behind the resolver interface, separate process.
5. Apple Remote **Menu button starts Sofa** (Front Row principle) via our own helper.
6. Final state as a MacPorts port in the overlay (`~/backport-toolkit/ports`), follow the doctrine.
7. Subtitles are NOT needed.

## Technology
- Objective-C + ARC, AppKit, Core Animation (layer-hosting, redraw only on
  change), AVFoundation (hardware H.264, HLS), IOKit HID, SQLite (system libsqlite3).
- Build: clang-22 (`/opt/local/bin/clang`), no Xcode/SDK needed (headers from /System).
  **Pitfalls:** (a) the 10.9 headers know no lightweight generics → no `NSArray<X*>`;
  (b) `-fobjc-arc` when LINKING requires libarclite (missing) → `-fobjc-arc` only when
  compiling, link without it (the 10.9 runtime has ARC natively); (c) no 10.10+ APIs
  (NSQualityOfService, NSVisualEffectView etc.).
- Layout in design units 1920x1080, `U()` scales (SFScale = height/1080).
- Tested 2026-11-03: AVFoundation plays local MP4, ZDF/3sat/ARD/BR/ARTE/SRF/ORF
  VOD, live streams Das Erste/ZDF/ORF1/3sat (HLS) and the media.ccc.de CDN → 10.9 TLS
  is enough — EXCEPT ORF (api-tvthek, *.mdn.ors.at, *.sf.apa.at: only AES-GCM/TLS1.3).
- **TLS bridge (`SFCurl`)**: libcurl from MacPorts (OpenSSL). `SFNet`/`SFImageCache`
  use curl for known hosts or hosts learned from an SSL error; the player goes through
  `SFStreamProxy` (127.0.0.1, rewrites m3u8, segments streamed incl. Range).
  The proxy caps `#EXT-X-VERSION` at 6: otherwise CoreMedia 10.9 reports
  "Unsupported version: 7" → -12642 (ORF live streams are v7, but plain TS).
  Diagnostic tool: `docs/probes/avtest.m` (prints the AVPlayerItem errorLog).

## Code structure (`~/src/sofa`)
- `src/SFCore` basics, `SFTheme` looks per area, `SFLayers` (SFLabel, SFImageLayer,
  image cache), `SFModel` (SFItem/SFShelf/SFPage + resolver registry), `SFStore` (SQLite:
  progress, settings, jcache), `SFScreen` (screen + navigator), `SFTile`,
  `SFBrowseScreen` (shelves/grid, virtualized, hero), `SFPlayerScreen`.
- Providers (one file per source): YouTube, ZDF, ARD,
  ORF, CCC, Mediathek.
- `helper/` SofaRemote (LaunchAgent): holds Apple IR exclusively, Menu starts Sofa,
  forwards keys to the app via Mach port.
- Data: `~/Library/Application Support/Sofa/sofa.db`, cache `~/Library/Caches/Sofa`,
  log `~/Library/Logs/Sofa.log`.

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
  disabled via `launchctl unload -w`; `com.bgutil.potserver` stays (yt-dlp resolver).
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
2. Sources online: ZDF/ARD/ORF/CCC natively, YouTube via yt-dlp resolver.
3. Subscription engine natively (replaces ytdl-sub + LaunchDaemon com.ytdlsub.run).
4. Phone pairing (Lounge), Kodi import, port, replace XBMCHelper/Kodi autostart.

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
- Live viewer: http://<tailscale-host>:8765/ (Tailscale IP + localhost only),
  MJPEG 1280x720 @6fps + remote control in the browser (`SFDevServer`).
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

## Backlog (user requests — queue, tick off when done)
- [x] Official logos (YouTube, ZDF, ARD, ORF, media.ccc.de, 3sat, ARTE ...) as PNG
      (Wikimedia renderings, 10.9 cannot do SVG) in `res/logos/`, in app tiles + header.
      Home use → allowed (user 2026-11-03).
- [x] Replace Kodi (user: currently nobody uses Kodi, Kodi stays the fallback):
      plists + /Applications/Sofa.app are ready; rest via `tools/switch-to-sofa.sh`
      (user must run/approve it). Afterwards: remote calibration (every button short+long,
      `~/Library/Logs/SofaRemote.log`), check video on the real screen.
- [x] media.ccc.de app (own app, API api.media.ccc.de).
- [~] ZDF / ARD / ORF natively per `docs/mediathek-apis.md` (mark geo/DRM restrictions). ARD+ZDF done (geo check before start), ORF done 2026-11-03 (TLS bridge, highlights `_embedded.video_item._embedded.item`, QXA streams only; individual qualities → 403). Maybe 3sat/ARTE later.
- [x] Update without disruption (sofa-deploy, immediately even during playback, position kept).
- [~] YouTube online (InnerTube natively + yt-dlp resolver) per `docs/youtube.md`. DONE 2026-11-03: `SFYouTube` (Firefox cookies → SAPISIDHASH, subscriptions/Später ansehen/channels/channel page UULF without Shorts/playlists), `SFYTResolver` + `res/ytresolver.py` (own venv `~/Library/Application Support/Sofa/ytdlp`, yt-dlp 2026.10.21, ~3.5 s/video, 1080p HLS), player retry -12643 + fallback URLs (95 → 18). Local copy is preferred (`externalID`). Search done. Channel header (banner as TV backdrop, @handle, subscribers, description) + tile "Automatisch laden: An/Aus" done. OPEN: Live tab.
- [x] Own subscription engine (replaces ytdl-sub + com.ytdlsub.run; live since 2026-11-03, feeds yt/zdf/ard/orf), subscribe from every app. → now as the premium offline layer (see guiding principle): `SFDownloads` generic (ffmpeg -c copy from HLS/MP4, ORF via proxy), downloads in Sofa's own storage (DB `downloads`), ~/TV Shows only migration, identity = source ID (yt:…), progress migration from local:…, context menu Herunterladen/Automatisch laden, tile status.
- [x] Phone pairing (YouTube "Mit TV verbinden", Lounge API) natively — 2026-11-03: `SFLounge` (libcurl long poll, NSURLSession buffers on 10.9!), `SFPairScreen` (YouTube → Mehr → "Mit Handy verbinden"), commands in main.m (`loungeCommand:`), wakes the display + brings Sofa to the front. Tested with `tools/lounge-remote.py <code>` (simulated phone): setPlaylist/pause/seek/play/getNowPlaying ok. Dev instance only with SOFA_LOUNGE=1 (own screenId `lounge.dev.*`). Tested with a real phone: works (user 2026-11-03). Only open: getDiscoveryDeviceId unanswered (auto-discovery without code).
- [x] On-screen keyboard for search (only 7 remote buttons) + search in all apps.
- [x] Downloads (2026-11-03): tile on home + "Downloads" shelf per app (after continue watching/first shelf, tile with download symbol in app colors) → page "Downloads · X GB belegt · Y GB frei" with Wird geladen / Zuletzt geladen / Sendungen und Kanäle; show: "Automatisch laden An/Aus", "Alle Downloads löschen" with confirmation (focus on Abbrechen); context menu Abspielen → Download → Gesehen; header "OK halten: Optionen". Offline pages reload live when the library changes.
- [x] Smart downloads: delete watched SUBSCRIPTION episodes 1 day after watching (default on; manual + legacy never), switch "Gesehenes löschen An/Aus" in the options of the downloads tile. Dev has its own settings key (the settings table is shared!).
- [x] Offline (2026-11-03): SystemConfiguration reachability (`SFNet isOnline`), header "Keine Internetverbindung – Downloads sind verfügbar", download queue + subscription check pause while offline (no attempts used up). Cached online pages stay visible (up to 30 days). Dev test: `SOFA_OFFLINE=1 tools/sofa-dev start`.
- [x] Review agent 2026-11-03 (offline layer): 7 findings fixed — cancelling the running download blocked the queue; ARD/ZDF file names collided (long IDs are now an FNV hash); new subscriptions downloaded the back catalogue (since after first check); unsubscribed subscriptions came back; episodes deleted later after unsubscribing; library message swallowed; show only by name (now name+source, "Einzelne Videos").
- [x] Mouse pointer (2026-11-03, user: was still visible): 3 layers — transparent cursor via cursor rects (SFNavigator), 1 s watchdog (CGCursorIsVisible → CGDisplayHideCursor, log "cursor: was visible"), clean unhide on app switch. The old solution counted hide/show and didn't notice when the system showed the pointer again.
- [x] 2026-11-03 afternoon (user feedback): dev isolation of progress (`dev_progress`, tests had changed "Weiterschauen"/"gesehen" of the real app – Creepfan video repaired, 141 migration entries without image repaired); contrast of the light ORF theme (tiles without image dark text, textDim 0.74, header band gradient behind clock/hint, menu labels full width); ZDF brand pages (resolve MetaCollection via canonical → internal ID, "Bares für Rares" was empty); ZDF seasons with real name ("2026") + image of the show; YouTube channel tiles of migrated channels → real channel page (online + local); history (home tile, by day); phone: status in every header, on "Mit Handy verbinden" OK = options: pause connection (pairing stays) ≠ disconnect all phones (new screenId, code needed), "Am Handy anzeigen" default = only playback started from the phone. Dev: `sofa-dev open pair|history`.
- [x] Status line top right (2026-11-03): one center line, right→left clock · phone pill (home + YouTube only) · [OK] keycap "halten: Optionen". Home tile "Handy" → settings (pause, Am Handy anzeigen, Neues Handy verbinden, Alle trennen). Kodi tile removed (a dev test had started Kodi through it!). YouTube channels alphabetical.
- [x] 2026-11-03 evening: follow concept (SFFollows, see decision log), downloads throttled (-readrate 3), seeking without jumps back, YouTube preloading on focus, autoplay "Als Nächstes" (YouTube /next, card with preview image), keyboard ABC/QWERTZ (remembered) + live suggestions in all apps, "Suchen" key outline only; helper starts Sofa after every update; ZDF brand page crash (endless loop) fixed; dev isolation now complete: progress (dev_progress), follows/downloads (dev_* tables), ALL settings (SFStore prefix "dev.").
- [ ] OPEN (user 2026-11-03, in order): (1) YouTube channel page closer to YouTube (subtle subscribe switch instead of a big tile, sections Videos/Popular/Playlists/Live), (2) autoplay "Als Nächstes" with YouTube recommendations, (3) playlists, (4) keyboard: QWERTZ toggle (saved) + live suggestions while typing in all apps, (5) seeking: jumps/race on fast forward/back, (6) speed up YouTube start (resolver timing, preload on focus; Creepfan 22 s), (7) check the mpv picture on the real screen.
- [x] 2026-11-03 evening: (1) channel page: buttons [✓ Gefolgt] · [Automatisch laden] instead of a tile, "Neueste Videos" (12) + playlists shelf (without mixes) + grid "Alle Videos"; unfollow only after confirmation (the button has focus on opening). (2) Autoplay card. (3) Playlists: autoplay follows the playlist ("Nächstes in der Playlist"). (4) Keyboard + suggestions; "hold Right" = to the suggestions, Left = back to the key you came from. NEW: "Suche" button in the header of every app (Up from the first row; also on empty/offline pages). Player hints (Fortgesetzt bei …) above the timeline, text-wide, show the real start point. Review agent 21:15: no crash classes; focus bugs fixed. OPEN: channel sections Popular/Live, (5)–(7).
- [x] 2026-11-03 22:30 "Später ansehen" (user: gap, you couldn't add anything): own shared watch list `SFWatchLater` (table watch_later, dev: dev_watch_later) for ALL apps; OK hold on a video → "Später ansehen" / "Aus ‚Später ansehen‘ entfernen"; shelf per app after "Weiterschauen" (`SFWithWatchLater`) + home (all apps); watched items drop out automatically; the YouTube account list (VLWL) is taken over once (setting watchlater.import.youtube) – same logic as follows. Focus stays at the same position in the row after removal. Channel: Live tab ("Jetzt live" + "Livestreams"), "Beliebt". mpv picture verified.
- [x] 2026-11-03 23:30 (6) YouTube start: resolver two pools (fg = playback, bg = warm-up/preload/downloads; before, a click waited behind preloading: 10.6 s instead of 3.5 s), job sharing per video (click during preload: 2.8 s), ObjC dedupe + `prefetch:`. AVFoundation retry 0.1 s instead of 0.3 s – measurement from 46 real starts: 23 immediately, 13 after the 1st, 8 after the 2nd retry, 2 → mpv; the cause is always CoreMedia -12643 on googlevideo HLS, retries stay (H.264 hardware). Channel: Live/playlists shelf only if the selected tab really is /streams or /playlists (otherwise YouTube silently returns "Übersicht" → Kurzgesagt showed normal videos as "Livestreams"). Review agent "Später ansehen": no crash/thread/dev leaks; 2 focus bugs in the grid fixed.
- [x] 2026-11-04 00:15 Exploratory ZDF/ARD/ORF: context menu "Zur Sendung „X“" / "Zum Kanal „X“" for episodes of all sources (`SFItem.showRef`: YouTube channel ID from lockup/renderer, ZDF `smartCollection.canonical`, ARD `show.id` (89/89 teasers), ORF `_links.profile` – only with profile_title, not for genre "Film"); older stored YouTube entries (watch list/continue watching/downloads) via `SFRegisterShowRefLookup` → InnerTube `player` → `videoDetails.channelId` on selection. Not on the show's/channel's own page (`folderIdentifier`). "Später ansehen" import of the YouTube account at startup. Show pages: `SFPage.focusShelf` – focus starts on the episodes, "Weitere Staffeln" stays visible at the top (no scrolling as long as the row fits). Grid row spacing 40→58 (titles of the enlarged focused tile overlapped the next row).
- [x] 2026-11-04 07:45 Review agent (resolver pools + showRef): `SFItem` stored `url` even WITH externalID (the else hung on the showRef if) → fixed. Resolver: a superseded preload job hands its result to playback via `superseded_by` (even after it ended), bg jobs > 60 s in the queue are dropped ("stale"), `run()` with finally (the job is always removed). ObjC: a failed playback request reports immediately, a resolver restart calls back waiters only after draining. "Zum Kanal" only opens if you are still on the page (lookup is asynchronous).
- [ ] **Clean, easily installable end product** (user 2026-11-04: "ist auf unserer Maschine
      entstanden, soll ein sauberes einfach installierbares Endprodukt werden" (was built on our
      machine, should become a clean, easily installable end product) – also makes Sofa
      here + development more stable/independent). Repo: github.com/robertkleinschuster/sofa (public).
  - [x] Sofa creates the yt-dlp venv itself + daily `pip install -U` (42d30c4; tested in isolation with
        `SOFA_YTDLP_DIR`, 20 s, resolve 1080p ok).
  - [x] Makefile: `MP` (MacPorts prefix), `PREFIX`, `DESTDIR`; SofaRemote finds Sofa.app via its
        own bundle (no fixed /Applications path anymore).
  - [x] (2026-11-04, 2.0.2, runs as nobody only on 127.0.0.1; plugin automatically kept in step via /ping pinning) Port `net/bgutil-pot-server` (overlay): bgutil-ytdlp-pot-provider 1.3.1 server (node26,
        node_modules as vendor tarball on the toolkit release `distfiles`, `canvas` natively against
        MacPorts cairo), LaunchDaemon via startupitem. Replaces the hand-made setup
        `~/bgutil-ytdlp-pot-provider` + `/Library/LaunchDaemons/com.bgutil.potserver.plist`.
  - [x] (2026-11-04, destroot verified) Port `multimedia/sofa` (overlay): source = GitHub tag; build with clang-22 (`make CC= MP=`),
        depends_lib curl sqlite3 mpv ffmpeg quickjs librsvg python314, depends_run bgutil-pot-server;
        `reinplace /opt/local -> ${prefix}`; Sofa.app into ${applications_dir}; two LaunchAgents
        (de.sofa.remote, de.sofa.app) via `startupitems … location LaunchAgents custom_file`.
        Test `port -n destroot` first (don't touch the real app).
  - [~] Tag v0.1.0 set (the port builds from it); GitHub release page + license (still missing, user decides) open.
  - [x] (2026-11-04 09:36, v0.1.1) This machine switched to the port: Sofa runs from
        /Applications/MacPorts/Sofa.app, agents = /Library/LaunchAgents/org.macports.sofa{,-remote}.plist
        (labels de.sofa.app/de.sofa.remote). Old hand-made agents → ~/Library/LaunchAgents/disabled-handbuilt/,
        old bundle → /Applications/Sofa-handbuilt-backup (no longer .app → no duplicate bundle ID).
        Loading agents from SSH only works via `sudo launchctl bsexec $(pgrep -x Dock) sudo -u imac launchctl load -w …`
        (`port load` fails without a GUI session). Live update: `SUDO_PW=… tools/sofa-deploy` (external swap
        via sudo, ~2 s); back to the port state: `sudo port -n upgrade --force sofa`.
        Original item: (replace the manual /Applications/Sofa.app, ~/Library/LaunchAgents/de.sofa.*,
        hand-made daemon); the dev loop stays `sofa-dev` on build/; clarify how `sofa-deploy`
        (live update) plays together with port-managed files.
  - [ ] `port mdmg sofa` → .dmg with all runtime dependencies as a release asset (for Macs without MacPorts).
  - [x] README: installation via `sudo port -n install sofa` + `port load`.
  - [ ] First-run setup in the app (explain YouTube login via Firefox, check the Apple Remote) – nothing in the terminal.
- [ ] **Distant future (user idea 2026-11-04):** multi-user + YouTube account sync natively in Sofa –
      only if anonymous resolving becomes unreliable. Then sign-in IN Sofa itself (no browser),
      maybe conveniently via the phone (code/QR like "Mit TV verbinden").
- [ ] Periodic background review agents (user request) — after every larger building block.
- [ ] Video frames in the dev stream (AVPlayerItemVideoOutput), otherwise black.
- [ ] MacPorts port in the overlay (final state), the /Applications copy is transitional.
- [x] System volume via remote (player: +/-), no app-internal volume.
- [x] Dev viewer in the browser (Tailscale), separate view/test instances.

- [ ] **Add modern codecs** (user 2026-11-03) — RESEARCH + MEASUREMENT GATE DONE: `docs/codecs-research.md` (libmpv as the 2nd engine; VP9 1080p60 8.5x, AV1 6.3x real time; user: newest mpv, H.264 stays AVFoundation, max 1080p60). mpv PORT DONE (2026-11-03): overlay `~/backport-toolkit/ports/multimedia/mpv` (0.41.0, platforms darwin>=13, without Cocoa/Swift, plain-gl, MLS static, patch `patch-10.9-coreaudio.diff` = dispatch_block replacement via cancel token + CoreAudioTypes path; deliberately not in MLS). Installed: `mpv +libmpv +opengl +python314 -bundle -osd -bluray -dvd -audiocd -libarchive -rubberband -network_ytdlp` (+ ffmpeg 9.0.2, libplacebo +opengl, libsixel). Verified: no MLS dylib dependency, `mpv` runs natively, VP9 1080p60 decodes. SOFA: engine abstraction `SFEngine` (SFAVEngine = the previous AVPlayer code, SFMPVEngine = libmpv render API in a CAOpenGLLayer, weakly linked `-weak-lmpv`). Choice: H.264 → AVFoundation; mpv for better DASH (VP9/AV1 higher resolution/fps), WebM/MKV, or when AVFoundation fails; mpv fails → AVFoundation; everything rejected (YouTube 403/-1102) → resolve fresh once. The resolver delivers `dash` (VP9 before AV1, ≤1080p60, Opus). Dev test: `SOFA_FORCE_MPV=1` (real-time playback verified; picture only checkable on the real screen, the dev window is offscreen). PICTURE VERIFIED 2026-11-03 21:45: `sofa-dev frame NAME` renders via GL readback into its own FBO (YouTube VP9 1080p + ZDF HLS: sharp, colors/orientation correct). The one-off "INVALID_FRAMEBUFFER_OPERATION" was a sticky error flag from CoreAnimation (0x506 before mpv) → now fetched beforehand; render only on FRAMEBUFFER_COMPLETE. Window captures (screencapture/CGWindowList) fundamentally don't work from the SSH shell.: play every source without problems,
  defuse the format selection. Today: AVFoundation 10.9 = only H.264/AAC in TS/MP4 HLS;
  no VP9/AV1/HEVC/Opus, no fMP4/DASH, HLS ≤ v6 (the proxy caps), sporadic -12643.
  Options (research + present BEFORE implementing, doctrine: natively via MacPorts):
  (a) libmpv (MacPorts mpv/ffmpeg) as a second player engine behind SFPlayerScreen,
      output into its own GL/CALayer surface; AVFoundation stays for H.264 (hardware).
  (b) own decoder path libavcodec/libavformat + rendering (more effort).
  Gain: YouTube directly DASH/VP9 (1080p60/1440p, without the HLS detour), ORF/ARD without
  version tricks, downloads without remux limits. Check: CPU (2011 iMac) for VP9/AV1
  in software, hardware only H.264 → selection rule "prefer H.264, otherwise software".
- [x] 2026-11-04 **TLS certificate verification off everywhere, code signed** (user decision "Aus + Signatur"): curl (`SFCurlNew` VERIFYPEER/HOST 0), all NSURLSessions (`SFTrustAllSessionDelegate`, verified on 10.9 against expired.badssl.com), mpv (ffmpeg default), yt-dlp (`nocheckcertificate`), node (`NODE_TLS_REJECT_UNAUTHORIZED=0`). AVFoundation (now only a fallback) still verifies system-side. CODE: (a) Sofa updates = RSA-3072 signature `Sofa-X.dmg.sig` (make-release signs with `~/.config/sofa/release-signing-key.pem` – NEVER commit/copy; public `res/sofa-release-public.pem`; verified by `SFSignature` via SecTransform; test-updater + `TAMPER=1`). `.sha256` stays as an asset so that 0.2.0 (still verifies via TLS+SHA) can update to 0.3. (b) yt-dlp: no venv/pip anymore – official zipapp (contains yt-dlp-ejs) in the bundle (`res/ytdlp.lock`, `tools/fetch-ytdlp`), newer release daily into `App Support/Sofa/yt-dlp`, verified via `SHA2-256SUMS.sig` (maintainers' GPG, pure Python verifier `res/ytdlp_verify.py`, cross-checked against gpg). bgutil plugin in the bundle (matching the PO server, only with Sofa updates). The old venv is deleted at startup. TODO port `sofa`: distfiles for yt-dlp/plugin into the Portfile (otherwise make fetches them over the network).
- [~] **Remove AVFoundation? (user decision 2026-11-04: yes)** — STEP 1 DONE: mpv plays everything (YouTube DASH VP9, ZDF/ORF HLS, downloads picture-checked in dev); AVFoundation only a fallback on mpv errors + emergency switch `defaults write de.sofa.app preferAVFoundation -bool YES`. mpv streams without TLS verification (user decision: media data, CA aging must never break playback; updater/pip/node stay verified). STEP 2 open: after a few days of observation (CPU/heat, failed starts) remove the AVFoundation code entirely. — Measurement 2026-11-04 (i5-2500S, mpv software, `--vo=null --untimed`): 720p50 H.264 ≈ 19 % of a core, 1080p50 H.264 ≈ 34 %, 1080p50 VP9 ≈ 31 % (test pattern; real content ~1.5x). mpv `--hwdec=videotoolbox(-copy)` does NOT work on 10.9 ("hwaccel initialisation returned error") → AVFoundation is the only hardware H.264 decoding. Cost of AVFoundation: ~1/3 of YouTube HLS starts fail at first (-1102/-11800/-12643), retry/mpv fallback 1–2 s; no VP9/AV1; double maintenance. Proposal to the user: mpv as the default engine, AVFoundation as a hidden emergency switch, removed entirely after a few days of observation.
- [x] 2026-11-04 YouTube failed starts analysed (docs/youtube.md §6 update): two kinds. (1) -11800/-12939 = CoreMedia fails fetching the playlist → playlists from manifest.googlevideo.com now go through the local proxy (VOD cache 10 min, preloaded after resolve/focus); served locally 0/25 instead of 4/25 errors. (2) -1102/-12660 = HTTP 403 on segments, also hits mpv, in bursts (test load!) → server-side, stays with retry/re-resolve. Dev: `open yt:<id>`, A/B with `SOFA_NO_PLAYLIST_PROXY=1`. When testing: don't flood YouTube with dozens of resolves per minute. Watch in production: the share of `retry 1` with -11800 should be ~0.
- [x] 2026-11-04 Update restart during YouTube: the resolver cache is saved along (`yt-resolved.json` in App Support, readable once, 0600, not in dev instances) → resumed video without a new resolve (before: gap ~9 s, ~5 s of it resolving).
- [ ] (no priority, research first) YouTube end screens / cards (User 2026-11-04): YouTubers link further videos, playlists and the channel in the last 5-20 s (end screen) and in "i" cards during the video. Check what the player response still exposes (`endscreen.endscreenRenderer`, `cards.cardCollectionRenderer`; classic annotations were shut down in 2019), whether yt-dlp/InnerTube deliver it anonymously, and design a remote-friendly overlay (e.g. at the end: focusable tiles in the positions the creator placed them, OK opens, otherwise autoplay continues). Combine with the planned player info panel / "up next".
- [x] 2026-11-04 Player info panel (User: "info UI im Player … zur Sendung/Kanal, Beschreibung, folgen/entfolgen, Empfehlungen, mit Untertitel/Tonspur zusammengeführt, für Playlists"): OK hold in the player opens `SFPlayerInfoScreen` (replaces the "Ton & Untertitel" menu; OSD hint "[OK] halten: Info", always shown). Built on `SFBrowseScreen` in overlay mode (not opaque -> video keeps playing, dimmed 0.72->0.92; header only clock + key hint; hero = current video with up to 6 description lines). Rows: actions (Ton/Untertitel only with a choice, Online abspielen for downloads, Zum Kanal/Zur Sendung via `SFShowLink` = same rules as the context menu, Folgen/✓ Gefolgt, Herunterladen/Download abbrechen (x %)/Download löschen (confirm), Später ansehen; pills sized to their label), Playlist (whole list, running entry "Läuft", focused) or phone queue "Als Nächstes", "Weitere Folgen von „X“" (downloaded show), YouTube "Empfehlungen". YouTube description/channel ID/avatar/recommendations come from ONE cached InnerTube `next` call (`+[SFYouTube watchPageFor:]`, also behind `relatedFor:`/`upNextFor:`). Decisions: leaving the video for a full screen (channel page, context-menu "Abspielen") replaces the player (progress saved) instead of keeping a dead player under it; MENU closes the panel directly; Play/Pause toggles the video underneath; a video that ends without successor while the panel is open stays until the panel closes. `topPlayer` (phone, dev FIFO) now also finds a player under overlays. Regression check: `tools/test-playback` step 3 (+ step 5 through the panel).
- [ ] Robustness (User 2026-11-04, standing rule): no ordering assumptions between async subsystems, readiness signal + timeout, watchdog/self-healing for long-lived state, one regression check per incident (`tools/test-playback`, `tools/test-resolver`).

## Display sleep/wake (from the Kodi experience, see ~/kodi-setup-NOTES.md "Sleep/Wake-Modell")
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
only restarts Sofa if it was in FRONT (otherwise it would e.g. cover Kodi), verifies the
start (up to 6 attempts), ignores keys during the swap.
Way back from Kodi: Sofa in the background + another app in front → MENU twice quickly (<0.7 s) brings Sofa back.
Remote-shell note: launchctl/open from the Tailscale SSH session (background session) have no
effect in Aqua → `sudo launchctl bsexec <loginwindow-pid> sudo -u imac launchctl ...`.
