# Adding an app to Sofa

An "app" is one media source (YouTube, ZDF, ARD, ORF, media.ccc.de …). Everything specific to
it lives in `src/Apps/<Name>/`; Sofa's UI, library, player and home page are shared. The
contract is the `SFApp` protocol in `src/Core/SFApp.h` – read its comments, they are the
reference. `src/Apps/Example/` is a minimal, working app (registered in dev instances only):
copy it as a starting point.

## 1. The class

```objc
// src/Apps/Foo/SFFooApp.h
#import "SFApp.h"
@interface SFFooApp : NSObject <SFApp>
@end
```

Required: identity (`appIdentifier` = theme name, `SFItem.source` and logo file name;
`appName`, `appSummary`), `refPrefixes` (the ref namespaces the app owns, e.g. `foo`,
`fooshow`), `configureTheme:`, `homeTileColor`, `homeTileLogoVariant`, and `homeLoader`
(the app's own start page shelves). Everything else is optional – a missing method means the
feature is hidden for this app, never a stub.

## 2. Refs: how the core finds your app

Every item that belongs to your app carries a ref `"<prefix>:<id>"` in `resolverRef` (or in
`identifier`), and `source = appIdentifier`. The core never compares app names; it asks
`SFAppRegistry` for the owner of a ref or item and calls the protocol:

| core feature                         | protocol method(s)                                   |
|--------------------------------------|------------------------------------------------------|
| play a video                         | `resolve:done:` (+ `resolveOnline:done:`)            |
| search page, keyboard suggestions    | `searchLoader:`, `suggestions:done:`, `searchPlaceholder` |
| show/channel page, "Zur Sendung"     | `showRefPrefixes`, `showPageLoader:title:`, `showRefForItem:done:` |
| follows, "Neue Folgen", auto download| `feed:done:`, `backgroundPausedUntil`                |
| download a video                     | `downloadSourceForItem:done:`, `backgroundPausedUntil` |
| "Platz schaffen" online check        | `availabilityOfItem:done:`                           |
| player info panel / up next / cards  | `watchDetailsForItem:done:`, `upNextForItem:done:`, stream description key `endCards` |
| session streams (local services)     | `playbackIsSession:`, `playbackSessionFailed:…`, `playbackSessionLostNotification`, `playbackLiveEnded:done:` |
| focus preload                        | `preloadOnFocus:`                                    |
| stored items (history …)             | `updateStoredItem:`                                  |
| phone remote                         | `startRemoteWithHost:`, `stopRemote`, `remoteStatus:`, `remoteStatusNotification` |
| home page sections                   | `homeSections`                                       |
| mixed Home rows (Jetzt live, Highlights) | `homeFeatures:` (usually `SFHomeFeaturesFromPage`); set `drm` / `geoRegion` from raw data, live `schedule` from the EPG |
| dev FIFO commands                    | `handleDevCommand:arg:host:`                         |

Wording: `showsAreChannels = YES` makes shows "Kanäle" with "Videos" and round avatars
(YouTube); otherwise "Sendungen" with "Folgen".

## 3. Pages

A page is an `SFPage` of `SFShelf`s of `SFItem`s, delivered asynchronously by an
`SFPageLoader` block (`done(page, error)` on main). Folder items carry their own
`pageLoader`; videos carry a ref. The shell frames your `homeLoader` with the shared shelves
(Weiterschauen, Neue Folgen/Meine Sendungen, Später ansehen, Downloads, the "Suche" tile)
– don't add those yourself (`homeIncludesFollows = YES` if your start page shows followed
shows itself).

Long lists (all of a channel's videos, playlists): give the shelf a `moreLoader` instead of loading
everything up front - it is called when the viewer comes within six tiles of a rail's end (two
lines of a grid), appends the next portion without moving what is shown, and is dropped once it
answers `more = NO`. One portion per approach, at the viewer's pace (YouTube: the list's
continuation token, `SFYTPages moreFrom:keep:`).

## 4. Look

`configureTheme:` sets tokens on top of the base theme (`src/Framework/SFTheme.h`): colors
(`background`, `accent`, `focus`, `text` …), fonts, `corner`, the derived tokens
(`focusText`, `progressColor`, `seekBarColor`, `wordmarkColor`) and the header decoration
(`headerMark`, `headerMarkColor`) shown when there is no logo. Logo: `res/logos/<id>.png`.
Components never ask which app is showing – if you need a new visual decision, add a token.

## 5. Register

One line in `src/Shell/SFApps.m` (`SFRegisterApps`); the order is the home tile order.

## 6. Check

- `make` without warnings, `tools/check-arch` (layer rules: apps import Framework + Core
  only, never Shell or another app; no app literals outside `src/Apps`).
- `tools/test-all`, then a dev instance (`tools/sofa-dev`): `open app:<id>`, search, play.
- `SOFA_ONLY_APPS=<id>` (dev instances) registers only your app – no other app's requests;
  dev commands `shelves <id>` (start page survey) and `homerows` (what Home's mixed rows show).
