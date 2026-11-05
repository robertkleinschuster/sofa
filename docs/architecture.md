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
(`start`, `stop`, `prepareForRelaunch`).

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
priority, tile style, grid, items block). `SFHome homeSections` (Shell) contributes the
app tiles (0), Weiterschauen (100), Später ansehen (200), Neue Folgen (300), the mixed rows
"Jetzt live" (310) and "Highlights" (320), and Meine Sendungen (400); apps add theirs through
`homeSections` (500+, e.g. YouTube "Meine Kanäle" as circles). Sections are sorted by
priority (stable) and empty ones disappear.

Mixed rows (`src/Core/SFHomeFeatures.h`): apps feature content on Home through the optional
`homeFeatures:` – items per *topic* (`SFHomeTopicLive`, `SFHomeTopicHighlights`; topics are
defined in Core, a topic is a promise about what the row means). Most apps derive them
structurally from their start page with `SFHomeFeaturesFromPage(page, leadShelf)`.
`SFHomeFeatures` asks every app (45 s timeout each; an app that fails keeps its previous
items), keeps each app's list (stored: Home shows them at once after a launch) and refreshes
every 30 min, when the network returns and when a live programme ends. A row is merged when
shown: first what can't play here is left out, then round-robin in registry order (fair: every
app gets a place at the front; max 6 per app in Highlights). Live channels may carry their
programme (`SFItem.schedule` of `SFBroadcast`, from the source's EPG: ARD programm-api, ORF
/livestreams): tiles show what runs now ("Brisant · bis 18:00") with its progress, the hero
its time, "Danach: …" and description. Tiles in mixed rows carry the app
logo (`SFItem.showsSourceMark`). Home only offers what plays here: no `drm` items and no
items whose `geoRegion` (raw source data, e.g. ZDF `geoLocation`) the device is known to be
outside of (`SFNet stateOfRegion:` – learned from every `checkRegion:…region:`, stored 24 h;
an app that features region-limited items probes once if the state is unknown).
An app's start page is framed the same way for every app (`SFHome appScreen:`): the app's
`homeLoader` shelves + followed shows/Neue Folgen (unless `homeIncludesFollows`) + Später
ansehen + the Suche tile and header button.

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
