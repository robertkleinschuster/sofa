# Sofa architecture: framework, core, apps

Status: implemented (2026-11-05); keep this document current with the code.
User requirement: adding a new app reuses almost all UI; it is obvious where app-specific
logic lives; integration happens through clearly defined APIs (including how the home page is
composed). This document is the contract.

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
                resolving, feeds, search, theme tokens, app-only services (YouTube: SABR
                sidecar, yt-dlp fallback, bot breaker, phone pairing + remote commands).
src/Shell       The Sofa product: AppDelegate (player host, dev FIFO, update relaunch), launch
                order, app registration (SFApps.m), home composition, settings, migration.
```

Dependency rules, enforced by `tools/check-arch` (part of `tools/test-all`):
- Framework imports only Framework + the Core foundation headers (SFCore, SFModel, SFStore,
  SFNet, SFCurl, SFRuntime, SFVolume, SFJSON). Data it shows comes in through small
  protocols set by the core (e.g. `SFTileStatusSource`: download chip + progress on tiles).
- Core (Core/Library/Player/Browse) never imports Apps or Shell; it reaches apps only through
  `SFAppRegistry` and the `SFApp` protocol.
- An app imports Framework + Core, never Shell or another app.
- Shell names app classes only in `SFApps.m` (registration). `SFMigration.m` (one-time Kodi
  import) is the documented legacy exception.
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
(`start`, `prepareForRelaunch`).

## Player hooks

The player keeps the generic fallback chain (engine switch, DASH→HLS, alternates,
re-resolve) and counts it in SFStats. App knowledge comes through the protocol, keyed by the
stream description the app's resolver attached to the URL (`SFMPVSourceFor`):
`playbackIsSession:` / `playbackSessionFailed:item:retried:reason:` /
`playbackSessionLostNotification` (streams served by a local app service, e.g. YouTube SABR),
`playbackLiveEnded:done:`, `playbackPrepareReResolve:`, `upNextForItem:done:`,
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
above the channel's usual views (RSS `media:statistics`, `SFItem.viewCount`). Most apps derive them
structurally from their start page with `SFHomeFeaturesFromPage(page, leadShelf)`.
`SFHomeFeatures` asks every app (45 s timeout each; an app that fails keeps its previous
items), keeps each app's list (stored: Home shows them at once after a launch) and refreshes
every 30 min, when the network returns and when a live programme ends. A row is merged when
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

## Data

- One SQLite database (`SFStore`, `src/Core/SFStore.m`): the **whole schema lives there**,
  versioned with `PRAGMA user_version` - each migration step runs once, in order, in one
  transaction with its version bump (a failing step rolls back and is retried next launch).
  Never change a shipped step, add one. Modules only read and write their tables.
- Tables: `progress` (positions, history), `settings`, `jcache` (SFNet response cache),
  `downloads`, `subscriptions`, `follows`/`follow_items` (ordered by `pos`), `feed_cache` (an
  app's last parsed feed per followed show + change signature), `watch_later`, `stats`. Items are
  stored as their JSON (`SFItem dictionaryRepresentation`) and loaded into memory at launch;
  indexes exist only where a query pages or sorts on disk (`progress(updated)`, `jcache(t)`).
- WAL, `synchronous=NORMAL`, one connection on a serial queue; `auto_vacuum=INCREMENTAL`.
  The response cache is trimmed after launch and daily: 14 days, 64 MB at most, oldest first.
- `settings` holds preferences and small state only (`setSetting:nil` removes a key). Raw
  answers go to `jcache` (trimmed); data an app derives and must keep goes to its own table
  (`feed_cache`, dropped 90 days after its last change).
- Several writes that belong together go through `runAll:` (one transaction); write only what
  changed (follows compare the new list with the loaded one).

## Dev instances

`Sofa --dev --instance NAME` (tools/sofa-dev) never shares state with the real app: the data
directory is decided once at launch (`SFSetDevInstance`) - `~/Library/Application
Support/Sofa-dev/NAME` (database, sidecar state, downloads under `Downloads/`), or
`$SOFA_DATA_DIR`. Every test suite runs with a fresh temporary `SOFA_DATA_DIR`, so tests start
from an empty database, leave nothing behind and can run side by side. Caches
(`SFCacheDir`: images, the updater's work dir, yt-dlp's cache) live in `<data dir>/Caches`, and
settings in the defaults domain `de.sofa.dev.<instance>`. Shared on purpose
(`SFSharedCacheDir`, `~/Library/Caches/Sofa`): only the YouTube bot-check pause (one IP for every
instance) and the dev control pipes `dev-<instance>.fifo`.
`SOFA_ONLY_APPS=a,b` registers only those apps (tests without network).

Test knobs are environment variables read through `SFDevEnv` / `SFDevSeconds` (SFCore), which
honour them in dev instances only - the real app never sees them:
`SOFA_OFFLINE=1` (simulated offline), `SOFA_RETRY_BASE` / `SOFA_SOURCE_GAP` (download retry and
per-source start spacing, seconds), `SOFA_STALL_LIMIT` (player stall watchdog, seconds),
`SOFA_NO_PLAYLIST_PROXY=1`. Tests wait for log lines (`dev: shot written PATH`, ...), never for
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
  Up to header), remote grammar (OK, OK halten = Optionen, MENU, MENU halten = Start, ▶❚❚,
  hold Left/Right = seek), context menu builder.

## Adding an app

See docs/new-app.md; `src/Apps/Example` (dev instances with `SOFA_EXAMPLE_APP=1`) is the
executable template.

Not extracted yet (add when a second user appears): settings contributions per app, extra
context-menu actions per app, the component gallery dev page, docs/ui-framework.md.
