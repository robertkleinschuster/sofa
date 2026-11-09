# Sofa architecture: framework, core, apps

Status: implemented (2026-11-05); keep this document current with the code.
User requirement: adding a new app reuses almost all UI; it is obvious where app-specific
logic lives; integration happens through clearly defined APIs (including how the home page is
composed). This document is the contract.

## Code rules

Binding for every change (user, 2026-11-06): **no guessing, no monster classes, clean interfaces,
modularity.**

- **No guessing on raw data.** Read the field the source provides for the purpose (InnerTube
  `accessibilityLabel`, `commandRuns` links, endpoint types, `publishDate`; XML through a parser)
  instead of positions, text heuristics, regular expressions over markup or thresholds ("shorter
  than 90 s = a Short"). Where a source has no such field, the comment says so and the code is
  the documented fallback.
- **Pure parsers, tested on real answers.** Turning a provider's JSON into items needs no request
  and no library state; recorded answers (cookies stripped) and their expected parse are the test
  (`tools/test-parse`).
- **One responsibility per module.** No source file above 500 lines (`tools/check-arch`, no
  exceptions). Split by responsibility - a request client, a parser, pages, the `SFApp` adapter
  (categories for protocol parts such as playback); a screen into parts (`SFBrowseScreen+Header`,
  `+Focus`, `+Hero`; `SFPlayerScreen+Engine`, `+Next`, `+Remote`, `+Input`) sharing ivars through
  its `+Private.h`, and self-contained pieces into their own module (`SFEndTile`, `SFMPVLayer`,
  `SFLoungeMessages`, `SFKeyboardKeys`, `SFFollowAction`).
- **Clean interfaces.** Modules talk through small headers, apps and the core only through the
  `SFApp` contract and the registry - an app never writes into a Library module directly.

## Layers

```
src/Framework   TV UI framework + design system: theme tokens, screens + navigator, focus/key
                grammar, components (tiles, menus, keyboard, image layers, icon art, logo).
                Knows nothing about apps, downloads or the player.
src/Core        App-agnostic media core: model (SFItem/SFPage), app contract + registry
src/Library       (SFApp), store (progress/history), library (downloads, storage, follows,
src/Player        watch later, search merge), player + engines, generic media screens
src/Browse        (SFBrowseScreen, library pages: shows, history, downloads, Platz schaffen).
src/Apps/<App>  Everything specific to one source: API client, JSON → SFItem mapping,
                resolving, feeds, search, theme tokens, app-only services (YouTube: the
                engine in Firefox, bot breaker, phone pairing + remote commands).
src/Shell       The Sofa product: AppDelegate (player host, dev FIFO, update relaunch), launch
                order, app registration (SFApps.m), home composition, settings, migration.
```

Dependency rules, enforced by `tools/check-arch` (part of `tools/test-all`):
- Framework imports only Framework + the Core foundation headers (SFCore, SFModel, SFStore, SFUserAgent,
  SFNet, SFCurl, SFHostFetch, SFRuntime, SFVolume, SFJSON). Data it shows comes in through small
  protocols set by the core (e.g. `SFTileStatusSource`: download chip + progress on tiles).
- Core (Core/Library/Player/Browse) never imports Apps or Shell; it reaches apps only through
  `SFAppRegistry` and the `SFApp` protocol.
- An app imports Framework + Core, never Shell or another app.
- Shell names app classes only in `SFApps.m` (registration).
- No app identifiers or ref namespaces as string literals (`@"youtube"`, `@"yt:…"`) outside
  `src/Apps`.

## The app contract: `SFApp`

One class per app conforming to `SFApp` (`src/Core/SFApp.h`, class methods: apps are
stateless for the core; app services keep their own singletons). The core never asks
"which app is this?"; `SFAppRegistry` finds the app that owns an identifier (`appNamed:`), a
ref namespace (`appForRef:`, the part before `:`) or an item (`appForItem:`), and the core
calls the protocol. Registering an app also registers its theme (base theme + the app's
`configureTheme:` tokens).

Required: identity (`appIdentifier`, `appName`, `appSummary`), `refPrefixes`,
`configureTheme:`, home tile (`homeTileColor`, `homeTileLogoVariant`), `homeLoader`.
Optional capabilities (absent = feature hidden, never a stub) – see docs/new-app.md for the
full table: search, resolve, shows/feeds, downloads/availability, player hooks, focus
preload, stored-item refresh, remote control, home sections, dev commands, lifecycle
(`start`, `stop` at quit).

## Player hooks

The player has one engine (mpv) and no generic fallback chain: a stream that fails ends in a
readable message, a session stream (below) is reopened by its app. App knowledge comes through the protocol, keyed by the
stream description the app's resolver attached to the URL (`SFMPVSourceFor`):
`playbackIsSession:` / `playbackSessionFailed:item:reason:` /
`playbackSessionLostNotification` (streams served by a local app service, e.g. YouTube SABR),
`playbackLiveEnded:done:`, `upNextForItem:done:`,
`watchDetailsForItem:done:` (info panel). End cards come generically in the stream
description under `endCards` (`kind`: video/playlist/channel/follow, `ref`, geometry, time);
opening them goes through `itemForRef:title:image:` / `listLoader:title:` / show pages.

## Remote control and the player host

A phone remote (YouTube "Mit TV verbinden") is an app capability: `startRemoteWithHost:`,
`stopRemote`, `remoteStatus:` (header pill text; Home shows every remote, an app page only
its own) and `remoteStatusNotification`. The shell implements `SFPlayerHost`
(`src/Core/SFPlayerHost.h`: navigator, visible player, present a player, wake the display)
and hands it to remotes and to app dev commands (`handleDevCommand:arg:host:`).

## Home composition

Sofa's home page is a list of `SFHomeSection`s (`src/Core/SFHomeSection.h`: id, title,
priority, tile style, grid, items block), read top down from "mine" to "discover"
(user 2026-11-05: Weiterschauen stays first): Weiterschauen (100), Neue Folgen (200), the app
tiles + Downloads/Verlauf/Einstellungen (300, two presses away), the mixed rows Jetzt live
(400), Nachrichten (500), Highlights (600), then Später ansehen (700), Meine Sendungen (800)
and the apps' own sections (`homeSections`, 900+, e.g. YouTube "Meine Kanäle" as circles).
Sections are sorted by priority (stable) and empty ones disappear. Rows mixing apps (all of
the above except the app tiles and an app's own section) show the app logo on each tile.

Mixed rows (`src/Core/SFHomeFeatures.h`): apps feature content on Home through the optional
`homeFeatures:` – items per *topic* (`SFHomeTopicLive`, `SFHomeTopicNews`,
`SFHomeTopicHighlights`; topics are defined in Core, a topic is a promise about what the row
means). ZDF/ARD/ORF read news from their news pages (lead cluster / "News" lane, ORF segments as
`orfseg:`); YouTube contributes Highlights without a request: videos of followed channels far
above the channel's usual views (`SFItem.viewCount`, read from the lists' view text: `SFYTViewCount`). Most apps derive them
structurally from their start page with `SFHomeFeaturesFromPage(page, leadShelf)`.
`SFHomeFeatures` asks every app (45 s timeout each; an app that fails keeps its previous
items), keeps each app's list (stored: Home shows them at once after a launch) and refreshes
every 30 min while the screen is awake (the TV in use; nothing while it sleeps, once on waking up), when the network returns and when a live programme ends. A row is merged when
shown: first what can't play here is left out, then round-robin in registry order (fair: every
app gets a place at the front; max 6 per app in Highlights). Live channels may carry their
programme (`SFItem.schedule` of `SFBroadcast`, from the source's EPG: ARD programm-api, ORF
/livestreams): tiles show what runs now ("Brisant · bis 18:00") with its progress, the hero
its time, "Danach: …" and description. Tiles in mixed rows carry the app
logo (`SFItem.showsSourceMark`). Watched videos are left out. Home only offers what plays here: no `drm` items and no
items whose `geoRegion` (raw source data, e.g. ZDF `geoLocation`) the device is known to be
outside of (`SFNet stateOfRegion:` – learned from every `checkRegion:…region:`, stored 24 h;
an app that features region-limited items probes once if the state is unknown).
An app's start page is framed the same way for every app (`SFHome appScreen:`): the app's
`homeLoader` shelves + followed shows/Neue Folgen (unless `homeIncludesFollows`) + Später
ansehen + the Suche tile and header button.

## Network identity

Every source should see one genuine client, used like a person uses a TV (user 2026-11-06: "nicht
aussehen wie ein Bot"; survey of all apps in NOTES).
- **User agent** (`SFUserAgent`): Sofa is a native Mac app whose requests go out over the system's
  TLS or libcurl, so it says exactly that - the user agent macOS gives every native app, byte for byte
  CFNetwork's own (`Sofa/<build> CFNetwork/673.6 Darwin/13.4.0 (x86_64) (<model>)`, checked by
  tests/units/useragent.m) - on NSURLSession, curl, images and mpv. Until 2026-11-06 it was a Safari 17
  string over a TLS stack no Safari has, with app credentials (ZDF, ORF) next to it. A source that
  must speak to its service as a browser does it from that browser (YouTube: the engine's Firefox,
  for InnerTube and media) - and everything else of that service goes through the same client:
  `SFHostFetch` routes a source's hosts to its own client (YouTube: pictures of i.ytimg.com,
  yt3.ggpht.com, yt3.googleusercontent.com from the engine page, 2026-11-07), with no native
  fallback. Before, thumbnails, avatars and the lounge went out natively - first with the engine's
  Firefox user agent over libcurl's or SecureTransport's TLS, then as the native app: a second
  client next to the real Firefox on the same IP.
- **Cadence**: follows on their own schedule (`SFRefreshPlan`), Home rows only while the screen is
  awake, a source's background pause (`backgroundPausedUntil`) respected by follows and downloads.

## Data

- One SQLite database (`SFStore`, `src/Core/SFStore.m`): the **whole schema lives there**,
  versioned with `PRAGMA user_version` - each migration step runs once, in order, in one
  transaction with its version bump (a failing step rolls back and is retried next launch).
  Never change a shipped step, add one. Modules only read and write their tables. `tools/test-schema`
  migrates a 0.3.8 database and checks every step - extend it with each new step.
- The schema states the rules (step 18): required columns `NOT NULL`, value ranges as `CHECK`s,
  references as foreign keys to `items` and `follows` - `DEFERRABLE INITIALLY
  DEFERRED` (checked at commit: write parent and child in one `runAll:` in any order), enforced
  (`PRAGMA foreign_keys=ON` after the migration). A row others refer to is written as an upsert
  (`INSERT ... ON CONFLICT DO UPDATE`), never `INSERT OR REPLACE` (that deletes it first). A size or
  state another subsystem owns is read from it, not copied into a column (step 17: a download's
  bytes are the media store's). A statement the database refuses fails the test suite that caused
  it (`tools/lib/dev-instance.sh`).
- Tables: `progress` (positions, history), `settings`,
  `downloads` (what the user downloads: states queued/running/done/failed, "Behalten", the online
  check - automatic downloads and their `subscriptions` went with step 19), `follows` (with
  `checked`: the spread refresh plan) / `follow_items`
  (a follow's newest items, ordered by `pos`), `watch_later`, `stats`, `recent_searches`,
  `original_titles` (a video's title as its uploader wrote it, where the source's lists show another:
  `-[SFStore setOriginalTitle:forID:]`; a known one wins in every item write and in the stored item).
- `items`: an item's metadata **once** - its JSON (`SFItem dictionaryRepresentation`), referenced by
  id from `progress`, `downloads`, `watch_later` and `follow_items`, which keep only their own facts
  (position, file, state, list position, when added). Written through `-[SFStore itemWrite:]` /
  `saveItem:` only: merged field by field (`json_patch` - newer values win, fields a snapshot lacks
  stay), local paths (a download's file and thumbnail) left out - they are the download's. A
  download's show name (`channel`) and publication time (`published`) are its own columns and win
  over the item's. Rows nothing references go with the daily housekeeping.
- Loaded into memory at launch; indexes exist only where a query pages or sorts on disk
  (`progress(updated)`, `jcache(t)`).
- In memory a row is a typed record, never a dictionary: `SFDownloadRecord`
  (`src/Library/SFDownloadRecord.h`), `SFFollow` (`SFFollows.h`). Each reads its row
  (`...WithRow:`) and gives the statement that stores it (`writeStatement`) - the column list
  lives in one place. Absent values: nil / 0 / -1 ("unknown"), written as NULL
  (`tests/units/downloadrecord.m`).
- The response cache (`jcache`: SFNet's raw answers, apps' derived data) is not user data: its own
  file `cache.db` in the caches folder (`SFCacheDir`), attached to the same connection as schema
  `cache` (`-[SFStore attachCache]`). Losing it costs requests, nothing else.
- WAL, `synchronous=NORMAL`, one connection on a serial queue; `auto_vacuum=INCREMENTAL`.
  The response cache is trimmed after launch and daily: 14 days, 64 MB at most, oldest first.
- `settings` holds preferences and small state only (`setSetting:nil` removes a key). Raw
  answers go to `jcache` (trimmed); data a module derives and must keep goes to its own table.
- Several writes that belong together go through `runAll:` (one transaction); write only what
  changed (follows compare the new list with the loaded one: new items are news, new field values
  are written quietly; fields the stored item has beyond the list are no change).

## Dev instances

`Sofa --dev --instance NAME` (tools/sofa-dev) never shares state with the real app: the data
directory is decided once at launch (`SFSetDevInstance`) - `~/Library/Application
Support/Sofa-dev/NAME` (database, sidecar state, downloads under `Downloads/`), or
`$SOFA_DATA_DIR`. Every test suite runs with a fresh temporary `SOFA_DATA_DIR`, so tests start
from an empty database, leave nothing behind and can run side by side: with `SOFA_DATA_DIR` the
log (`sofa.log`) and the dev FIFO (`dev.fifo`) live in it too (`SFDevPrivateDir`), otherwise in
`~/Library/Logs/Sofa-dev-NAME.log` and the shared cache. Caches
(`SFCacheDir`: images, the updater's work dir) live in `<data dir>/Caches`, and
settings in the defaults domain `de.sofa.dev.<instance>`. Shared on purpose
(`SFSharedCacheDir`, `~/Library/Caches/Sofa`): only the YouTube bot-check pause (one IP for every
instance) and the dev control pipes `dev-<instance>.fifo`.
`SOFA_ONLY_APPS=a,b` registers only those apps (tests without network).

Test knobs are environment variables read through `SFDevEnv` / `SFDevSeconds` (SFCore), which
honour them in dev instances only - the real app never sees them:
`SOFA_OFFLINE=1` (simulated offline), `SOFA_RETRY_BASE` / `SOFA_SOURCE_GAP` (download retry and
per-source start spacing, seconds), `SOFA_STALL_LIMIT` (player stall watchdog, seconds). Tests wait for log lines (`dev: shot written PATH`, ...), never for
fixed times.

## Design system (Framework)

- Tokens: `SFTheme` (`src/Framework/SFTheme.h`) holds the visual decisions as named tokens –
  colors (background, surface, text, textDim, accent, accentText, focus), fonts, corner,
  logo/wordmark, and derived tokens with defaults (`focusText`, `progressColor`,
  `seekBarColor`, `wordmarkColor`, `headerMark` + `headerMarkColor`). Themes are registered
  by name (`registerTheme:builder:`; apps via `configureTheme:`). Components never compare
  theme names – a new visual decision becomes a token.
- Components: SFTile (styles), shelf/grid, hero, header bar, side menu (rows, toggles,
  details, scroll + edge fade), confirm dialog, toast, keyboard, image layer (fallback,
  fades), icon art, subtitle builder (`SFDotJoin`), empty/offline states.
- Interaction: SFNavigator + SFScreen key handling, focus model (row/grid, focus memory,
  Up to header), remote grammar (OK, OK halten = Optionen, MENU, MENU halten = Sofa-Menü (SFQuickMenu: Start, Ton, Energie, Einstellungen), ▶❚❚,
  hold Left/Right = seek), context menu builder.

## Adding an app

See docs/new-app.md; `src/Apps/Example` (dev instances with `SOFA_EXAMPLE_APP=1`) is the
executable template.

Not extracted yet (add when a second user appears): settings contributions per app, extra
context-menu actions per app, the component gallery dev page, docs/ui-framework.md.
