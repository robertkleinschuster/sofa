# Sofa – YouTube part: InnerTube browsing (native ObjC) + streams via the YouTube engine

Since 2026-11-07 the engine runs in a real Firefox (`SFYTEngine`, [youtube-engine.md](youtube-engine.md));
where this document says "sidecar" (the node process it replaces) the engine now does the same job.

## Current concept (2026-11-05) – read this first

What we learned (bot-flagged IP, yt-dlp's player requests got "not a bot" while the web player's
did not, every extra request prolongs a flag) led to one rule: **Sofa has exactly one YouTube
identity, and every request to YouTube is counted and justified.**

| Layer | What | Runs |
|---|---|---|
| Browsing | InnerTube `browse`/`search`/`next`/`navigation/resolve_url` built and parsed in ObjC (`SFYTInnerTube` request, `SFYTParser` meaning, `SFYTPages`; modules: `SFYouTubeApp.h`), **sent by the sidecar's session** (`POST /yt/<endpoint>`); search suggestions via `GET /suggest` | in the app, transport in the sidecar |
| **YouTube engine** (`res/sofa-yt`, `SFYTEngine`, [youtube-engine.md](youtube-engine.md); before: the node sidecar, [sofa-yt.md](sofa-yt.md)) | the web player: one session, WEB player request with a video-bound PO token, SABR streaming as local URLs for mpv; lives/DVR as local HLS; downloads; focus preloads (budgeted). What it can't serve gets a clear message (bot check, not on air, `unanswered`, no mpv), never a second client | always (node, ~50 MB) |
| Breaker (`SFYTBreaker`, shared file `Caches/Sofa/youtube-block.json`) | a bot check pauses background work (follow checks, preloads, downloads) 1 h → 8 h; user playback waits 3 min right after the check | the sidecar writes it, every instance reads it |
| Counters (`SFStats`, table `stats`) | `yt.play.<outcome>`, `yt.live.*`, `yt.download.*`, `player.<fallback step>` per day | dev command `stats [days]` |

Retired 2026-11-06 (user: "brauchen wir yt-dlp überhaupt noch?", then "entscheide du"): **the yt-dlp
fallback** (`ytresolver.py`, `SFYTResolver`, Sofa's PO token plugin, `/pot`, the bundled Python). The
rule "fallbacks stay as long as the counters show they are needed" decided it: 11-05..06 it was used
25 times, delivered once (muxed low quality after 49 s) and sent 54 failed player requests as three
other clients (mweb, web_embedded, android_vr) - the second identity the bot check looks for. A
leftover cleanup removes its files once (`SFYouTubeApp removeYTDLPLeftovers`).

### One identity, human cadence (2026-11-06)

Diagnosis of the recurring bot checks (first 2026-11-05 16:30, production logs): Sofa looked like two
machines on one IP - native requests with a Safari UA over libcurl, no cookies/visitorData, a
hard-coded clientVersion, `player` requests without PO token; the sidecar with a truncated UA without
browser version and `en-US` - plus a dead RSS feed asked 135× per cycle, every followed channel
refreshed back to back every 30 min around the clock, and yt-dlp asking as three more clients when
the sidecar got no answer. Fixed causes:
- **One browser** (`res/sofa-yt/lib/identity.ts`): a current desktop Chrome on a Mac (major from
  Chrome's public version history, weekly), its client hints, `de-AT`/`AT`/`Europe/Vienna`, and a
  cookie jar (`<state>/cookies.json`, 0600, never logged), a fresh session per sidecar session (current
  clientVersion and YouTube's reading of the UA from `sw.js_data`; youtubei.js's session cache had
  kept June's clientVersion and the old UA's browser fields), the visitor kept - set on the global fetch, so InnerTube,
  BotGuard/WebPO, captions and SABR all send it. Underneath, the connection is Chrome's too
  (`lib/transport.ts`, global undici dispatcher): Chrome's cipher suites, groups (X25519MLKEM768
  first), signature algorithms and ALPN `h2` before `http/1.1` - Node's defaults (52 suites, X448/
  ffdhe, `http/1.1` first) were no browser's fingerprint. The JA4 cipher part now equals Chrome's;
  OpenSSL lacks a few of Chrome's extensions, so the extension part still differs.
  The app sends **no** request to youtube.com itself:
  every InnerTube call goes through `POST /yt/<endpoint>` (`player` refused there - only the sidecar
  asks it, with a PO token; the watch details come from `next`).
- **Cadence like a person** (`SFRefreshPlan`, `SFFollows`): each followed channel is checked on its
  own schedule - a quarter of its median upload gap, 2 h .. 24 h (2 h with fewer than 3 dates; was 45 min .. 6 h until 2026-11-07),
  ±20 % jitter, doubled at night (0-6 h), at least 20-40 s between two checks; `follows.checked`
  persists it across launches; during a bot-check pause the due follow waits for its end
  (`backgroundPausedUntil`, also what downloads wait for).
- No RSS (gone since 2026-11-05 ~21:30, HTTP 404), no table `feed_cache`.

Everything ships in the app bundle (user requirement): node and the sidecar's node_modules -
nothing to install.

The sections below are the original InnerTube browsing research, **live-tested on 2026-11-03**
on the target machine itself (macOS 10.9.5); all numbers are measurements from it.

---

## 1. Transport basics

### 1.1 Endpoint & headers

Since 2026-11-06 Sofa sends these requests only through the sidecar's youtubei.js session (one
identity, see the concept above); the headers and clientVersion below are the research record, the
session sets its own (current clientVersion from the page, Chrome UA, cookies).

```
POST https://www.youtube.com/youtubei/v1/<endpoint>?prettyPrint=false
Content-Type: application/json
User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:140.0) Gecko/20100101 Firefox/140.0
X-Youtube-Client-Name: 1
X-Youtube-Client-Version: 2.20261030.02.00
Origin: https://www.youtube.com
Accept-Encoding: gzip            (NSURLSession decodes gzip transparently)
```

* **API key: not needed.** Requests without `?key=` return 200 (tested with plain curl,
  no UA, no key: 200, 0.97 s). The page still exposes the public web key
  (`AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8`), keep it only as an emergency fallback.
* **clientVersion:** current is `2.20261030.02.00` (from `"INNERTUBE_CLIENT_VERSION"` in
  the youtube.com HTML). Old versions still work (`2.20200101.00.00` → 200), garbage
  (`1.0`) → 404. Recommendation: hardcode a recent value, optionally refresh weekly by
  regex-scraping `"INNERTUBE_CLIENT_VERSION":"([^"]+)"` from `https://www.youtube.com/`.
* `hl`/`gl` control language/region of all texts ("vor 8 Stunden", "2,27 Mio. Abonnenten").
* **10.9 TLS:** `/usr/bin/curl` (SecureTransport, same stack as NSURLSession) reaches
  `www.youtube.com`, `i.ytimg.com`, `yt3.ggpht.com`, `manifest.googlevideo.com`,
  `*.googlevideo.com` with TLS 1.2 → fine.
* Response sizes (WEB): 100 KB–2 MB JSON, parse with `NSJSONSerialization` off the
  main thread. Latency: 0.2–1.0 s.

### 1.2 Request body (common context)

```json
{
  "context": {
    "client": { "clientName": "WEB", "clientVersion": "2.20261030.02.00",
                "hl": "de", "gl": "AT" }
  },
  "...endpoint specific fields..."
}
```

### 1.3 WEB vs TV (TVHTML5) client — decision: **WEB**

| | WEB | TVHTML5 (`clientName:"TVHTML5"`, `clientVersion:"7.2025…"`, `X-Youtube-Client-Name: 7`) |
|---|---|---|
| search | `videoRenderer` / `shortsLockupViewModel` | shelves of `lockupViewModel` (grouped "Kürzlich hochgeladen", "Shorts") |
| browse (channel/subs/playlist) | almost everything is `lockupViewModel` now | `tileRenderer` inside `tvBrowseRenderer…tvSecondaryNavRenderer` (different schema again) |
| channel id on video items | yes (avatar onTap) | **no** (only channel name) |
| cookies auth | works | works (`logged_in=1`) |
| docs / community knowledge | lots | little |

TV JSON is not simpler — it mixes `lockupViewModel` (search) and `tileRenderer` (browse)
and is 2× bigger. The 10-ft look is a UI concern; use WEB and build your own model.

---

## 2. Authentication (cookies + SAPISIDHASH)

### 2.1 Cookie source

* Profile: `~/Library/Application Support/Firefox/profiles.ini` → the profile with
  YouTube login is **`Profiles/xxxxxxxx.default-default-2`** (the `[Install…] Default=`
  entry; the profile marked `Default=1` (`yyyyyyyy.default`) has *no* YouTube cookies).
  Robust algorithm: iterate all `Path=` entries, pick the one whose cookies contain
  `SAPISID` + `LOGIN_INFO` for host `.youtube.com`.
* `cookies.sqlite` is locked by a running Firefox → **copy `cookies.sqlite` *and*
  `cookies.sqlite-wal`** (if present) to a temp dir, open the copy with system
  `libsqlite3` (`-lsqlite3`), delete the copy afterwards.
* Query: `SELECT host,path,isSecure,expiry,name,value FROM moz_cookies
  WHERE host LIKE '%youtube.com' OR host LIKE '%google.com'` → 72 rows here.
  `expiry` is in **seconds** on this Firefox (guard: if > 10^11 divide by 1000).
* For InnerTube send **all cookies of host `.youtube.com`** (37 names here: `SID, HSID,
  SSID, APISID, SAPISID, __Secure-1PSID, __Secure-3PSID, __Secure-1PSIDTS,
  __Secure-3PSIDTS, SIDCC, __Secure-1PSIDCC, __Secure-3PSIDCC, LOGIN_INFO, PREF,
  __Secure-1PAPISID, __Secure-3PAPISID, …`) as one `Cookie:` header.
  Tested: minimal subsets (`SID,HSID,SSID,APISID,SAPISID` ± `__Secure-*PSID`) →
  `logged_in=0`. Send the full set like a browser.
* Firefox rotates `__Secure-*PSIDTS`/`SIDCC`: re-read cookies at app start and e.g.
  every few hours / on 401 or `logged_in=0`.

### 2.2 Authorization header

```
Authorization: SAPISIDHASH <ts>_<sha1hex("<ts> <SAPISID> https://www.youtube.com")>
X-Goog-AuthUser: 0
X-Origin: https://www.youtube.com
Origin: https://www.youtube.com
Cookie: <all .youtube.com cookies>
```

* `<ts>` = current Unix time in seconds; SHA-1 over the string
  `"<ts> <value of SAPISID cookie> https://www.youtube.com"` (single spaces), lowercase hex.
  In ObjC: `CC_SHA1` from `<CommonCrypto/CommonDigest.h>`.
* Optional (browser sends it, not required): append
  `SAPISID1PHASH <ts>_<sha1(ts + " " + __Secure-1PAPISID + " " + origin)>` and
  `SAPISID3PHASH <ts>_<sha1(… __Secure-3PAPISID …)>` space-separated in the same header.
* Test matrix (FEsubscriptions):

| variant | result |
|---|---|
| cookies + `SAPISIDHASH` only | `logged_in=1`, 101 items |
| cookies + 3 hashes | `logged_in=1` |
| cookies + `SAPISIDHASH`, without X-Origin/X-Goog-AuthUser | `logged_in=1` (keep them anyway) |
| cookies, **no** Authorization | `logged_in=0`, 0 items (HTTP 200!) |
| hash computed with wrong origin | `logged_in=0` |

* **Login check:** `responseContext.serviceTrackingParams[].params[]` contains
  `{"key":"logged_in","value":"1"}`. Failed auth is *silent* (HTTP 200, empty feed) →
  always check this flag on authenticated calls.

---

## 3. Endpoints (exact bodies, key paths)

Notation: `…` = skip, `[]` = iterate array. All bodies additionally contain `context`.

### 3.0 Generic parsing strategy (important)

YouTube is migrating to **`lockupViewModel`**; legacy renderers still appear. Write one
recursive walker that collects any of these item keys, regardless of path:

| key | used in | id field |
|---|---|---|
| `lockupViewModel` | channel tabs, playlists, subs feed, library, related (`next`) | `contentId` + `contentType` (`LOCKUP_CONTENT_TYPE_VIDEO` / `_PLAYLIST` / `_CHANNEL` / `_SHORT`) |
| `videoRenderer` | search | `videoId` |
| `shortsLockupViewModel` | search, channel home | `onTap.innertubeCommand.reelWatchEndpoint.videoId` |
| `channelRenderer` | search (channel filter), FEchannels | `channelId` |
| `playlistVideoRenderer` | **Watch Later (VLWL)** | `videoId`, `lengthSeconds`, `setVideoId` |
| `tileRenderer` | TV client only | `contentId` |

Then a "continuation finder" (see 3.9). This is far more robust than hardcoding the long
paths below (which are given for orientation and change regularly).

**Text helper:** a text node is `{"simpleText":…}` or `{"runs":[{"text":…},…]}` (concat)
or (view models) `{"content":…}`.

**`lockupViewModel` (video) fields:**

```
contentId                                        → videoId
contentType                                      → LOCKUP_CONTENT_TYPE_VIDEO
metadata.lockupMetadataViewModel.title.content   → title
metadata.lockupMetadataViewModel.metadata.contentMetadataViewModel.metadataRows[]
      .metadataParts[].text.content              → row0 = channel name (in feeds/playlists;
                                                   absent on channel's own tabs),
                                                   row1 = ["29.834 Aufrufe","vor 8 Stunden"]
metadata.lockupMetadataViewModel.image.decoratedAvatarViewModel.avatar.avatarViewModel
      .image.sources[].url                       → channel avatar (68 px)
metadata.lockupMetadataViewModel.image.decoratedAvatarViewModel.rendererContext
      .commandContext.onTap.innertubeCommand.browseEndpoint.browseId → channelId (UC…)
contentImage.thumbnailViewModel.image.sources[]  → {url,width,height} (360/720 w hq720)
contentImage.thumbnailViewModel.overlays[].thumbnailBottomOverlayViewModel.badges[]
      .thumbnailBadgeViewModel                   → {text:"35:35", badgeStyle:
          THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT} | {text:"LIVE", badgeStyle:
          THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE} | {text:"Anstehend"} (upcoming)
rendererContext.commandContext.onTap.innertubeCommand.watchEndpoint.videoId
```

**`lockupViewModel` (playlist)**: `contentId` = playlist id (note: new short ids like
`PLUxsF7qmly14` exist besides 34-char ones), thumbnail at
`contentImage.collectionThumbnailViewModel.primaryThumbnail.thumbnailViewModel.image.sources[]`,
video count badge in `…primaryThumbnail.thumbnailViewModel.overlays[].thumbnailOverlayBadgeViewModel.thumbnailBadges[].thumbnailBadgeViewModel.text`
("5 Videos"); onTap → `watchEndpoint{videoId,playlistId}`.

**`videoRenderer`** (search): `videoId, title, lengthText.simpleText ("35:35"),
viewCountText.simpleText, publishedTimeText.simpleText, ownerText.runs[0].text,
ownerText.runs[0].navigationEndpoint.browseEndpoint.browseId,
thumbnail.thumbnails[] (hq720 360/720 w),
channelThumbnailSupportedRenderers.channelThumbnailWithLinkRenderer.thumbnail.thumbnails[]`,
live: `badges[].metadataBadgeRenderer.label == "LIVE"`, viewCountText = "3.757 Zuschauer".

### 3.1 Search (+ pagination)

```json
{ "query": "tagesschau" }
{ "query": "tagesschau", "params": "EgIQAQ%3D%3D" }     // videos only
{ "query": "tagesschau", "params": "EgIQAg%3D%3D" }     // channels only → channelRenderer
{ "query": "tagesschau", "params": "EgIQAw%3D%3D" }     // playlists only → lockupViewModel
{ "query": "nachrichten live", "params": "EgJAAQ%3D%3D" } // live now
{ "continuation": "<token>" }                            // next page
```
(`params` values are sent URL-encoded exactly like this – verified working.)
The first answer carries them itself, as youtube.com's "Filter" button offers them:
`header.searchHeaderRenderer.searchFilterButton.buttonRenderer.command.openPopupAction.popup
.searchFilterOptionsDialogRenderer.groups[]` ("Typ", "Dauer", "Hochladedatum", "Eigenschaften",
"Priorisieren") `.filters[].searchFilterRenderer{label, navigationEndpoint.searchEndpoint.params}` -
Sofa takes the "Playlists" one from there (`SFYTParser searchTypeFilter:in:`, 2026-11-08: the same
`EgIQAw%3D%3D`). An unfiltered answer brings 0-2 playlists per 20 results (plus "courses",
`LOCKUP_CONTENT_TYPE_COURSE`, not shown yet).

Response (first page, 0.7 s, ~540 KB):
```
contents.twoColumnSearchResultsRenderer.primaryContents.sectionListRenderer.contents[]
   .itemSectionRenderer.contents[] .videoRenderer | .shortsLockupViewModel (in reelShelf) | .channelRenderer
   .continuationItemRenderer.continuationEndpoint.continuationCommand.token   ← next page
estimatedResults
```
Continuation page (1.0 s):
```
onResponseReceivedCommands[0].appendContinuationItemsAction.continuationItems[]
   .itemSectionRenderer.contents[].videoRenderer …
   .continuationItemRenderer.continuationEndpoint.continuationCommand.token
```
20 videos per page. Filter out shorts for the TV UI (`shortsLockupViewModel`,
`reelShelfRenderer`).

### 3.2 Channel page

```json
{ "browseId": "UC5NOEUbkLheQcaaRldYW5GA" }                               // Home/featured tab
{ "browseId": "UC5NOEUbkLheQcaaRldYW5GA", "params": "EgZ2aWRlb3PyBgQKAjoA" }       // Videos
{ "browseId": "UC5NOEUbkLheQcaaRldYW5GA", "params": "EgdzdHJlYW1z8gYECgJ6AA%3D%3D" } // Live
{ "browseId": "UC5NOEUbkLheQcaaRldYW5GA", "params": "EgZzaG9ydHPyBgUKA5oBAA%3D%3D" } // Shorts
{ "browseId": "UC5NOEUbkLheQcaaRldYW5GA", "params": "EglwbGF5bGlzdHPyBgQKAkIA" }   // Playlists
```
Best practice: take the tab params from the first response instead of hardcoding:
`contents.twoColumnBrowseResultsRenderer.tabs[].tabRenderer.{title, selected,
endpoint.browseEndpoint.params}` — seen tabs: Übersicht, Videos, Shorts, Live,
Podcasts, Playlists, Beiträge. (`@handle` → channel id: `ownerText…browseEndpoint.browseId`
or `navigation/resolve_url` endpoint; not needed when navigating from items.)

**Header** (same in every tab response), `header.pageHeaderRenderer.content.pageHeaderViewModel`:
```
title.dynamicTextViewModel.text.content                         → "tagesschau"
image.decoratedAvatarViewModel.avatar.avatarViewModel.image.sources[]  → avatar 72/120/160 px
banner.imageBannerViewModel.image.sources[]                     → banner up to w2560 (2560x424)
metadata.contentMetadataViewModel.metadataRows[0].metadataParts[0].text.content → "@tagesschau"
metadata.contentMetadataViewModel.metadataRows[1].metadataParts[].text.content
                                                                → ["2,27 Mio. Abonnenten","37.403 Videos"]
description.descriptionPreviewViewModel.description.content     → description (truncated)
```
Also `metadata.channelMetadataRenderer.{title, description, externalId, avatar.thumbnails[0].url,
vanityChannelUrl, rssUrl}`.
Subscriber count is a localized string only ("2,27 Mio. Abonnenten") — display as-is.

**Videos tab** (0.33 s, 30 items/page):
```
contents.twoColumnBrowseResultsRenderer.tabs[i].tabRenderer.content.richGridRenderer
   .contents[].richItemRenderer.content.lockupViewModel
   .contents[last].continuationItemRenderer.continuationEndpoint.continuationCommand.token
   .header.chipBarViewModel.chips[].chipViewModel{text:"Neueste"|"Beliebt"|"Älteste",
          tapCommand.innertubeCommand.continuationCommand.token}   ← sort order
```
Next page `{"continuation": token}` →
`onResponseReceivedActions[0].appendContinuationItemsAction.continuationItems[].richItemRenderer.content.lockupViewModel`.
Live tab: identical structure (richGrid), items have LIVE/"Anstehend"/"vor 11 Stunden gestreamt".

**Playlists tab**:
```
…tabs[i].tabRenderer.content.sectionListRenderer.contents[0].itemSectionRenderer.contents[0]
   .gridRenderer.items[].lockupViewModel (contentType PLAYLIST)
   .gridRenderer.items[last].continuationItemRenderer…continuationCommand.token
```

Shortcut for "all uploads, newest first": playlist `UU` + channelId[2:]
(`VLUU5NOEUbkLheQcaaRldYW5GA`, 100 items/page, see 3.3).

### 3.3 Playlist contents

```json
{ "browseId": "VLPLUxsF7qmly14" }        // "VL" + playlistId
{ "continuation": "<token>" }
```
```
contents.twoColumnBrowseResultsRenderer.tabs[0].tabRenderer.content.sectionListRenderer
   .contents[0].itemSectionRenderer.contents[].lockupViewModel           (≤100 per page)
   …contents[last].continuationItemViewModel.continuationCommand.innertubeCommand
        .continuationCommand.token                                        ← NEW form!
continuation response: onResponseReceivedActions[0].appendContinuationItemsAction
   .continuationItems[].lockupViewModel, last = continuationItemViewModel…
```
Header comes in **two variants**:
* `header.pageHeaderRenderer.content.pageHeaderViewModel` — title in
  `title.dynamicTextViewModel.text.content`, rows e.g. `["Playlist","5 Videos","276 Aufrufe"]`.
* `header.playlistHeaderRenderer` (uploads playlists, WL) — `title.simpleText`,
  `numVideosText.runs`, `ownerText.runs[0]`, `viewCountText`.
Also `sidebar.playlistSidebarRenderer`, `microformat.microformatDataRenderer`.

### 3.4 Watch page metadata / related ("next")

```json
{ "videoId": "OzCYsIrrRyw" }
```
(0.7 s)
```
contents.twoColumnWatchNextResults.results.results.contents[]
   .videoPrimaryInfoRenderer.{title.runs, viewCount.videoViewCountRenderer.viewCount.simpleText,
                              dateText.simpleText ("02.11.2026")}
   .videoSecondaryInfoRenderer.owner.videoOwnerRenderer.{title.runs[0], subscriberCountText.simpleText,
                              thumbnail.thumbnails[], navigationEndpoint.browseEndpoint.browseId}
   .videoSecondaryInfoRenderer.attributedDescription.content           → full description
contents.twoColumnWatchNextResults.secondaryResults.secondaryResults.results[].lockupViewModel  → 20 related
   …results[20].continuationItemRenderer.continuationEndpoint.continuationCommand.token
contents.twoColumnWatchNextResults.autoplay…                                       → autoplay next
```
With `"playlistId":"…"` added, `contents.twoColumnWatchNextResults.playlist` gives the
playlist queue.

### 3.5 Player (metadata only)

```json
{ "videoId": "OzCYsIrrRyw", "contentCheckOk": true, "racyCheckOk": true }
```
(0.2 s) → `videoDetails.{videoId,title,lengthSeconds,channelId,author,shortDescription,
viewCount,isLiveContent,thumbnail.thumbnails[]}`, `microformat.playerMicroformatRenderer`.
`playabilityStatus.status` is `UNPLAYABLE` ("Video nicht verfügbar") and **no
`streamingData`** for WEB without PO-token/JS-challenge handling. Tested natively for
IOS, ANDROID_VR, WEB_EMBEDDED_PLAYER, MWEB, TVHTML5, WEB (with/without cookies): only IOS
returned formats, and those are SABR-only. → **Streams come from the YouTube engine** (the web
player with a PO token, [youtube-engine.md](youtube-engine.md)), never from a native `player` call.
Use `player` for: duration, isLiveContent, description when you don't need `next`.

### 3.6 Home / recommended

```json
{ "browseId": "FEwhat_to_watch" }
```
Path when filled: `contents.twoColumnBrowseResultsRenderer.tabs[0].tabRenderer.content
.richGridRenderer.contents[].richItemRenderer.content.lockupViewModel` (+
`richSectionRenderer` shelves, continuation as channel videos tab).
**On this account it returns only a `feedNudgeRenderer` "Der YouTube-Verlauf ist
deaktiviert"** (both anonymous and logged in) — watch history is switched off in the
Google account, so YouTube shows no recommendations. Sofa's "Home" should therefore be
composed by the app: subscriptions feed + "related to last watched" (`next`) + search
shelves. If history gets enabled later, the endpoint works as is.

### 3.7 Authenticated feeds (all with cookies + SAPISIDHASH, all ~0.25–0.7 s)

| what | body | items |
|---|---|---|
| **Subscriptions feed** | `{"browseId":"FEsubscriptions"}` | `…tabs[0].tabRenderer.content.richGridRenderer.contents[].richItemRenderer.content.lockupViewModel` (100/page, newest first, channel name in metadataRows[0]) + continuation `continuationItemRenderer` at the end |
| **Subscribed channels** | `{"browseId":"FEchannels"}` | `…tabs[0].tabRenderer.content.sectionListRenderer.contents[0].itemSectionRenderer.contents[0].shelfRenderer.content.expandedShelfContentsRenderer.items[].channelRenderer` → `channelId, title.simpleText, thumbnail.thumbnails[] (//yt3.googleusercontent.com/…, prefix https:), subscriberCountText ("1,98 Mio. Abonnenten"), videoCountText (actually the @handle!)` — 15 here, no continuation. Sort chips (A–Z, relevance, new activity) via `sectionListRenderer.header.chipBarViewModel` |
| Guide (sidebar) | endpoint **`guide`**, body `{}` | `items[].guideSubscriptionsSectionRenderer.items[].guideEntryRenderer.{formattedTitle, thumbnail, navigationEndpoint.browseEndpoint.browseId (UC…), presentationStyle (new-content dot)}` — 17 channel entries (some behind `guideCollapsibleEntryRenderer`). Also lists FE ids: FEsubscriptions, FEhistory, FElibrary, FEplaylist_aggregation, VLWL, VLLL, FEdownloads, … Good cheap alternative for the channel list incl. "has new videos". |
| **Watch Later** | `{"browseId":"VLWL"}` | `…sectionListRenderer.contents[0].itemSectionRenderer.contents[0].playlistVideoListRenderer.contents[].playlistVideoRenderer` (legacy renderer!) → `videoId, title.runs, lengthSeconds, lengthText, shortBylineText.runs[0], thumbnail.thumbnails[], setVideoId, isPlayable`; header = `playlistHeaderRenderer`. 7 items here. |
| Liked videos | `{"browseId":"VLLL"}` | like playlist; empty here ("Noch keine Videos in dieser Playlist") |
| History | `{"browseId":"FEhistory"}` | empty here (history disabled, shows "Verlauf aktivieren") |
| **Own playlists** | `{"browseId":"FEplaylist_aggregation"}` | `…richGridRenderer.contents[].richItemRenderer.content.lockupViewModel` (PLAYLIST) → here only WL "Später ansehen" and LL; user-created playlists appear here too |
| Library ("Du") | `{"browseId":"FElibrary"}` | `richGridRenderer.contents[].richSectionRenderer.content.richShelfRenderer.contents[].richItemRenderer.content.lockupViewModel` shelves (playlists, WL preview, …) |
| `FEyou` | — | HTTP 400 (not a valid browse id) |

Not needed now but available with the same auth: `browse/edit_playlist`
(`{"playlistId":"WL","actions":[{"addedVideoId":"…","action":"ACTION_ADD_VIDEO"}]}` —
the exact command is embedded in every lockup's Watch-Later hover button),
`subscription/subscribe` / `unsubscribe` (`{"channelIds":["UC…"]}`).

### 3.8 Anonymous vs authenticated

Search, channel, playlist, next, player metadata work **anonymously**. Use auth only for
FE* feeds, WL/LL and private playlists (keeps the rest independent of cookie health).

### 3.9 Continuation token forms (all seen live)

1. `continuationItemRenderer.continuationEndpoint.continuationCommand.token` (search, grids, subs, related)
2. `continuationItemViewModel.continuationCommand.innertubeCommand.continuationCommand.token` (playlists)
3. `continuations[0].nextContinuationData.continuation` (TV client shelves)

Request: same endpoint (`search` or `browse` or `next`) with body `{"continuation": token}`.
Response: `onResponseReceivedCommands[0].appendContinuationItemsAction.continuationItems`
(search) or `onResponseReceivedActions[0].appendContinuationItemsAction.continuationItems`
(browse). **Ignore** tokens found under `chipBarViewModel`, `engagementPanel`,
`showEngagementPanelEndpoint` (sort chips / description panels) — only take the
continuation item that is the *last element of the item list*.

---

### 3.10 Publication dates (which raw data to trust)
InnerTube lists (browse, search, channel tabs, lockups) carry only relative text
(`publishedTimeText` / metadata parts: "vor 11 Tagen", "vor 1 Jahr") – no timestamp anywhere in
the entry (checked 2026-11-05). Exact sources, in Sofa's order of use:
- **Feeds** (follows, "Neue Folgen", auto downloads): until 2026-11-05 the RSS of the
  uploads-without-Shorts playlist (`feeds/videos.xml?playlist_id=UULF…`, `<published>` to the
  second); it answers HTTP 404 since then and was removed. Feeds are now InnerTube `browse` of
  `VLUULF<channel id without UC>` (relative dates only), one per follow on its own schedule
  (`SFRefreshPlan`).
- **Player response**: `microformat.playerMicroformatRenderer.publishDate` / `uploadDate`
  ("2019-01-09T06:03:03-08:00"); the engine returns it as `published` (epoch s) from `/open`. Downloads store this exact time (SFDownloadURLDone info).
- **Watch page** (`next`): `dateText` "02.11.2026" (day; request is hl=de/gl=AT) – info panel.
`relativeDate()` in SFYTParser is the fallback for list entries only (approximate).

### 3.11 Titles: everything is translated, only oEmbed keeps the original (2026-11-08, revised 2026-11-25)

With hl=de every list renderer (browse lists, search, the watch page's related videos, cards, end
screen, `lockupViewModel.metadata...title`) carries YouTube's **translated** title where the creator
(or YouTube's machine translation) provides a German one - no marker, no original next to it.
2026-11-08 the watch page still had the original (`84ne8PrfFMY`: list "Einblicke in ein Haus aus
reinem Beton an einer mexikanischen Klippe", watch page "This Is What $4,900,000 Gets You in
Mexico"); by 2026-11-25 the watch page is translated too (`OXkGQO-CX48`, an English channel, stored
as "100 Yu-Gi-Oh Fragen, die sich jeder stellt"). YouTube has no setting against it. The original
is in the video's **oEmbed** answer (`/oembed?format=json&url=…watch?v=<id>`, field `title`) -
what the browser add-ons against the translation ask (yt-anti-translate, YouTube No Translation).

So (`SFYTOriginalTitles`): every video is asked once through the engine's page fetch (one client,
`oembed` call), one call at a time - what is shown now (a list, a follow's feed, the watch page)
every ~2 s, the stored backlog every ~15 s, nothing while the breaker holds. The answer goes into
`SFStore original_titles` (and rewrites the stored item) and wins from then on: list items
(`SFYTPages shownItem:`, follow feeds), every stored item (`itemWrite:`), the info panel. A list
shows the translated title until its video's answer is in. Schema step 20 dropped the watch-page
titles remembered before.

## 4. Images

### 4.1 Video thumbnails (`https://i.ytimg.com/vi/<id>/<name>.jpg`, no auth, no headers)

| name | size | note |
|---|---|---|
| `default.jpg` | 120x90 | 4:3, letterboxed |
| `mqdefault.jpg` | 320x180 | 16:9, always exists |
| `hqdefault.jpg` | 480x360 | 4:3 letterboxed, always exists |
| `sddefault.jpg` | 640x480 | 4:3, **may 404** (old videos) |
| `maxresdefault.jpg` / `hq720.jpg` | 1280x720 | 16:9, **may 404** (old/low-res videos) |
| `hqdefault_live.jpg` / `maxresdefault_live.jpg` | | live streams (current frame) |

10-ft grid tile (~400–500 px wide at 2560x1440): use `mqdefault.jpg` (16:9, no bars) or
the `hq720.jpg?sqp=…` URL from the response (720 w). Detail/hero: `maxresdefault.jpg`
→ on 404 fall back to `hqdefault.jpg` (crop the 4:3 bars, image is 16:9 content centred).
`vi_webp/<id>/*.webp` exist but **10.9 NSImage cannot decode WebP** → always `.jpg`.
Thumbnail URLs from responses with `?sqp=…&rs=…` are signed for that exact size; use
as-is or use the plain templates above.

### 4.2 Channel avatars / banners (`yt3.ggpht.com` / `yt3.googleusercontent.com`)

URL form: `https://yt3.googleusercontent.com/<key>=s<N>-c-k-c0x00ffffff-no-rj`.
Replace `=s88-…`/`=s68-…` with any size: tested `s88, s240, s512, s900` → exact pixel
size (JPEG). Responses sometimes give protocol-relative `//yt3.ggpht.com/…` → prefix
`https:`. Banner: `…=w1920-fcrop64=1,00005a57ffffa5a8-k-c0xffffffff-no-nd-rj` →
1920x318 (cropped TV-banner strip); `=w1920` alone → 1920x1080 full art.

---

## 5. Live streams

* InnerTube: live items carry badge `THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE` / text "LIVE"
  (lockup) or `badges[].metadataBadgeRenderer.label == "LIVE"` (videoRenderer); upcoming
  = "Anstehend" + "Geplant für: 03.11.26, 20:00". Search filter `EgJAAQ%3D%3D` = live now;
  channel tab "Live" (`EgdzdHJlYW1z8gYECgJ6AA%3D%3D`).
* Playback of lives (live edge and DVR) is the engine's job, see [youtube-engine.md](youtube-engine.md).

---

## 6. Pitfalls checklist

1. Silent auth failure (HTTP 200, empty) → check `logged_in` flag.
2. Two header schemas for playlists (`pageHeaderViewModel` vs `playlistHeaderRenderer`);
   WL uses legacy `playlistVideoRenderer`, the rest `lockupViewModel` → walker, not paths.
3. Continuation tokens in 3 forms; ignore chip/engagement-panel tokens.
4. Protocol-relative image URLs (`//yt3…`) → prefix `https:`.
5. `maxresdefault`/`sddefault` 404 on old videos → fall back to `hqdefault`/`mqdefault`.
6. WebP thumbnails unusable on 10.9.
7. All counts/dates are localized strings (de-AT) — display only; `lengthSeconds` only in
   `player`/`playlistVideoRenderer`; parse "35:35" badges for durations elsewhere.
8. Shorts are everywhere (`shortsLockupViewModel`, `LOCKUP_CONTENT_TYPE_SHORT`, Shorts
   shelves) → filter for the TV UI.
9. Firefox cookie DB locked → copy sqlite + `-wal`; never write to Firefox's DB.
10. Home/History empty because account watch history is off (not a bug).
11. Stream URLs (googlevideo) expire after 6 h and are IP-bound.
12. Never log or persist cookie values outside the 0600 cookie file.
