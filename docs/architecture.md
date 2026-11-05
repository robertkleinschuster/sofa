# Sofa architecture: framework, core, apps

Status: target design (2026-11-05), migration in progress on branch `arch/apps`.
User requirement: adding a new app reuses almost all UI; it is obvious where app-specific
logic lives; integration happens through clearly defined APIs (including how the home page is
composed). This document is the contract.

## Layers

```
src/Framework   TV UI framework + design system. Knows nothing about apps or media sources.
                Screens, navigator, focus/key grammar, components, tokens, page model.
src/Core        App-agnostic services: model (SFItem/SFPage), store (progress/history),
                library (downloads, storage, keep), follows, watch later, search merge,
                player + engines, net/cache, settings, stats, updater, dev tooling.
src/Apps/<App>  Everything specific to one source: API client, JSON → SFItem mapping,
                resolving, feeds, search, theme, logo, app-only services (YouTube: SABR
                sidecar, yt-dlp fallback, bot breaker, phone pairing).
src/Shell       The Sofa product: AppDelegate, launch order, home composition engine,
                settings screen, migration. Wires Core + Apps together via the registry.
```

Dependency rule (checked by `tools/check-arch`): Framework imports nothing from Core/Apps/Shell;
Core imports Framework only; Apps import Framework + Core; only Shell may import Apps (and
only `SFAppRegistry` registration, no app classes elsewhere). No `@"youtube"`/`@"zdf"` string
literals and no `hasPrefix:@"yt:"` outside `src/Apps`.

## The app contract: `SFApp`

One class per app conforming to `SFApp` (Objective-C protocol, required + optional methods).
The core never asks "which app is this?"; it asks the registry for the app that owns an id,
ref prefix or item, and calls the protocol.

Required – identity and entry page:
- `identifier` (`"zdf"`), `name`, `summary` (home tile text), `theme` (tokens, see below),
  `logo` (+ variant), `refPrefixes` (`zdf`, `zdfshow`, …): the namespaces it owns.
- `homeLoader` → `SFPageLoader` for the app's start page (app shelves only; the shell adds
  the shared shelves – continue watching, watch later, downloads, search – via composition).

Optional capabilities (absent = feature hidden, never a stub):
- Search: `searchLoader:`, `suggestions:done:`.
- Playback: `resolve:ref done:` (→ `SFPlaybackSource`: URL(s), engine hints, live flag),
  `resolveOnline:` (skip local copy), `playbackDelegate` (see Player hooks).
- Shows/channels: `showPageLoader:title:`, `showRefForItem:done:` (lookup), `followFeed:done:`
  (new episodes for follows/auto downloads).
- Library: `downloadSource:done:`, `downloadPauseUntil`, `availability:done:` (online check
  for "Platz schaffen").
- Home contributions: `homeSections` (see Home composition) – e.g. YouTube "Meine Kanäle".
- Item actions: `actionsForItem:` → extra context-menu entries (core adds the shared ones).
- Settings: `settingsPage` → registered under Einstellungen, not hard-coded.
- Lifecycle: `start` / `stop` (services such as the YouTube sidecar), `didBecomeIdle`.
- Remote control service: `remoteService` (YouTube phone pairing) exposed through a core
  protocol `SFRemoteService` (status pill, pairing screen, commands → player).

## Player hooks: `SFPlaybackSource` + `SFPlaybackDelegate`

The player plays an `SFPlaybackSource` (stream URLs, audio URL, engine preference, live/DVR,
session token). App-specific recovery lives in the app's delegate, the player only calls:
- `playback:didFail:attempt:` → retry plan (re-resolve, alternate source, give up message)
- `playbackStatus:done:` (e.g. SABR session health), `playbackDidEnd:`
- `upNextForItem:done:`, `endscreenForItem:done:` (cards: video/playlist/channel)
- `noteWatched:` / `preloadOnFocus:` (focus preload budget)
The player's generic fallback chain (engine switch, HLS/DASH alternates, re-resolve) stays in
Core and is counted in SFStats; app delegates only add app knowledge.

## Home composition

The home page is assembled by `SFHomeComposer` (Shell) from contributions:
`SFHomeSection { id, title, priority, style, itemsLoader, refreshNotification, emptyPolicy }`.
Core contributes: app tiles (from the registry), Weiterschauen, Später ansehen, Neue Folgen,
Meine Sendungen, downloads/history/settings tiles. Apps contribute via `homeSections`
(e.g. YouTube "Meine Kanäle" as circles). Ordering = priority bands (apps row 0, continue 100,
watch later 200, new 300, follows 400, app sections 500+), stable inside a band. The same
mechanism builds each app's start page frame: shared shelves (Weiterschauen for this app,
Später ansehen, Downloads, Suche tile) + the app's `homeLoader` shelves.

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
