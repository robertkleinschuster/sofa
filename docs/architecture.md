# Sofa architecture: framework, core, apps

Status: target design (2026-11-05), migration in progress on branch `arch/apps`.
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

## Design system (Framework)

- Tokens: `SFTheme` holds every visual decision as a named token – colors (background,
  text, textDim, accent, focus, onFocus, progress, tile placeholder), type scale, spacing
  (`U()`), radii, motion (durations/curves), opacities (backdrop hero/grid, dim). Apps define
  their theme by tokens; no `if (theme.identifier == …)` in components. Header decoration
  (ZDF/ARD/ORF accent marks) becomes a theme token (`headerMark`).
- Components: SFTile (styles), shelf/grid, hero, header bar, side menu (rows, toggles,
  details, scroll + edge fade), confirm dialog, toast, keyboard, image layer (fallback,
  fades), icon art, subtitle builder (`SFDotJoin`), empty/offline states.
- Interaction: SFNavigator + SFScreen key handling, focus model (row/grid, focus memory,
  Up to header), remote grammar (OK, OK halten = Optionen, MENU, MENU halten = Start, ▶❚❚,
  hold Left/Right = seek), context menu builder. Documented in docs/ui-framework.md.
- Gallery: dev page `open gallery` renders every component in every theme for screenshots.

## Adding an app (docs/new-app.md)

1. `src/Apps/<Name>/` with `SF<Name>App.{h,m}` conforming to `SFApp`.
2. Theme tokens + logo in the app folder (`res/logos/<id>.png`).
3. Implement `homeLoader` and the capabilities it supports.
4. Register in `SFAppRegistry` (one line in Shell).
5. `tools/test-app <id>`: loads home/search/resolve through the protocol.
The template app `src/Apps/Example` (dev builds only) is the executable reference.

## Migration plan (big bang on `arch/apps`, merged when complete)

1. Folders + `SFApp`/`SFAppRegistry`; apps become `SFApp` classes; replace main.m
   registrations, home tiles, app screen routing, search routing, theme lookup, the 9
   `SFRegister…` hooks → protocol methods. Verify: test-all + screenshots of every app.
2. Player hooks: move SABR/yt-dlp recovery, up next, endscreen, preload into the YouTube
   app delegate. Verify: test-playback (incl. SABR/live opt-in suites).
3. Home composer + app start page frame; app home sections; settings/actions contributions.
4. Theme tokens instead of identifier checks; header marks; gallery page.
5. Remote service (phone) behind `SFRemoteService`.
6. `tools/check-arch`, docs/new-app.md, template app, docs/ui-framework.md.
Each step keeps the app working; merge to main after full test-all + exploratory pass in all
themes; then release.
