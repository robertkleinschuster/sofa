# Mediathek APIs: ZDF, ARD, ORF ON (native client reference)

Tested-at: **2026-11-03, 06:56–07:20 UTC**, from Vienna (AT, Mtel, IP geo-checks report `AT`).
Every endpoint below was called live with curl/python (no MediathekView servers involved).
References: yt-dlp master (`yt_dlp/extractor/{zdf,ard,orf}.py`), MServer master 3.1.295
(`src/main/java/mServer/crawler/sender/{zdf,ard,orfon}`), plus the GraphQL documents compiled
into zdf.de's Next.js chunks (decoded from the bundled graphql-tag ASTs).

General notes for the NSURLSession client:
- No special User-Agent is required anywhere (python-urllib and curl defaults worked). Sending a normal
  UA such as `Sofa/1.0 (Macintosh; Intel Mac OS X 10_9_5)` is fine.
- Rate limits: no `RateLimit`/`429` seen. ARD returns `cache-control: max-age≈110`; ZDF token `max-age=291`.
  Cache responses for about 2–5 minutes and fetch lazily (one shelf/page at a time).
- All three broadcasters geo-block some content. From AT: **ORF is fine except for DRM**. **ZDF/ARD are
  partly blocked (DE-only)**, and every response carries a flag you can use to grey such items out (see Pitfalls).
- Prefer stream types in this order: progressive MP4 H.264 720p (ZDF, ARD), then the HLS master (ORF has no MP4).

---

## 1. ZDF (incl. ZDFneo, ZDFinfo, 3sat, KiKA, phoenix, arte partner content)

There is a single API for the ZDF Mediathek. Since the 2025 relaunch it is **Apollo GraphQL at `https://api.zdf.de/graphql`**,
plus the old **PTMD** stream-metadata service (`https://api.zdf.de/tmd/2/...`). 3sat, KiKA, phoenix and arte appear
as *content owners* inside the ZDF catalog (`content-owner-3sat`, `content-owner-kika`); their own websites are
out of scope. The old app API `zdf-prod-futura.zdf.de/mediathekV2/*` still answers, but its **editorial start
page is frozen (teasers dated March 2026)**, so do not use it except for the token endpoint.

### Auth
```
GET https://zdf-prod-futura.zdf.de/mediathekV2/token          (no auth, no headers)
→ {"type":"Bearer","token":"087ee847a6d725180474cee3dcf62e3547702018",
   "expires":1793791446,"expiresDateTime":"04.11.2026 12:24:06","createdDateTime":"03.11.2026 04:00:06"}
```
- The header on **every** GraphQL and PTMD call is `Api-Auth: Bearer <token>`. yt-dlp uses this endpoint (it is what the Android app uses).
- The token **rotates daily** (created 04:00, valid about 32 h). Cache it and refresh when `now > expires`, or on 401/403.
- Fallback: zdf.de HTML embeds two web tokens in the RSC payload, `"videoToken":{"apiToken":"ahBaeMee…","expiresAt":"2026-11-04T17:22:23+01:00"}`
  and `"appToken":{"apiToken":"aa3noh…"}`. MServer scrapes `apiToken` from `https://www.zdf.de` (search for the first `apiToken\":\"`).
  All three tokens worked for GraphQL and PTMD.
- Without a token: GraphQL → empty 403. PTMD → 403.
- GraphQL CSRF guard: use **POST with `Content-Type: application/json`**. A GET without `Apollo-Require-Preflight: true`
  is rejected ("blocked as a potential CSRF"). Introspection is disabled and errors do not suggest field names,
  but **free-form (non-persisted) queries are accepted**. Use the queries below and do not rely on persisted hashes.

Request template (all ZDF GraphQL calls):
```
POST https://api.zdf.de/graphql
Api-Auth: Bearer <token>
Content-Type: application/json
{"query":"<query text>","variables":{...}}
→ {"data":{...}}  |  {"errors":[{"message":"Cannot query field \"x\" on type \"Y\"", ...}]} (HTTP 400)
```

### Endpoints

#### Start page (shelves)
Home is a `CuratedCollection` with canonical `mt2025-startseite-100` (found in www.zdf.de RSC: `"collection":{"canonical":"mt2025-startseite-100","id":"8c3f3656-…"}`).
```graphql
query SofaPage($canonical: String!, $first: Int) {
  curatedCollectionByCanonical(canonical: $canonical) {
    id canonical title
    modules { nodes {
      __typename
      ... on StaticHorizontalCluster {
        id title
        items(first: $first) { totalCount nodes {
          __typename
          ... on Video { canonical title editorialDate teaser { title description imageWithoutLogo { layouts { dim768X432 } } } }
          ... on ISmartCollection { canonical title teaser { title imageWithoutLogo { layouts { dim768X432 } } } }
          ... on MetaCollection { canonical title }
        } }
      }
      ... on DynamicHorizontalClusterList { id configuration maxCluster isPersonalised }
    } }
  }
}
variables: {"canonical":"mt2025-startseite-100","first":30}
```
Response key paths: `data.curatedCollectionByCanonical.modules.nodes[]` → `__typename`, `title`, `items.totalCount`, `items.nodes[]`.
Tested result: 25 modules, for example `StaticHorizontalCluster "Top-Serien zum Streamen" (25)`, `"Packende Krimis" (26)`,
`"Livestreams" (7: zdf-live-beitrag-100, zdfneo-live-beitrag-100, …)`, `"Nachrichten und Politik"`, and `"Kategorien" (26: MetaCollection pub-form-10004, …)`.
- `TeasersConnection` has **no `pageInfo`**. Raise `first` to get more items (max seen 26).
- Item `__typename` values seen: `Video`, `SeasonSeriesSmartCollection`, `HybridBingeSeriesSmartCollection`, `DefaultWithSectionsSmartCollection`,
  `DefaultNoSectionsSmartCollection`, `MovieSmartCollection`, `MiniSeriesSmartCollection`, `EndlessSeriesSmartCollection`, `MetaCollection`, `CuratedCollection`,
  `ExternalLink`, `ZappingChannel`, `Catalog`. Skip `ExternalLink`, `ZappingChannel` and `DynamicHorizontalClusterList` (personalised: "weiterschauen", "weil-du", "dkdi").
- A `CuratedCollection` item is a sub-page: call the same query with its canonical (add `canonical` to the selection).

#### Categories / Rubriken
- The list of categories is the `"Kategorien"` cluster on the start page (`MetaCollection` canonicals such as `pub-form-10004` Filme,
  `pub-form-10003` Dokus, `pub-form-10010` Serien, `genre-10290` Sport). Content owners work the same way (`content-owner-3sat`, `content-owner-kika`).
- Sofa recognises that cluster by its items (all `MetaCollection`), not by its title, and takes each tile's `id` for
  `metaCollectionContent` (request `id` in the `MetaCollection` fragment). The id is a UUID for brand pages and equal to the canonical
  for `pub-form-*` (seen 2026-11-06) - never infer one from the other; only a bare canonical asks `metaCollectionByCanonical { id }`.
- Live: `currentMedia.nodes[].__typename == "LiveMedia"` (not the canonical); the channel is `LiveMedia.tvService`
  (`ZDF`, `ZDFneo`, `ZDFinfo`, `3sat`, `phoenix`, `arte`, `KI.KA`), Sofa's station id = its lowercase letters and digits (`kika`, as ARD's EPG).
- Content of a category:
```graphql
query SofaCategory($collectionId: String!, $input: MetaCollectionContentInput!) {
  metaCollectionContent(collectionId: $collectionId, input: $input) {
    tabs { id label }
    pageInfo { hasNextPage endCursor }
    smartCollections { canonical title collectionType }
  }
}
variables: {"collectionId":"pub-form-10004",
 "input":{"appId":"ffw-mt-web-879d5c17","filters":{"contentOwner":[],"fsk":[],"language":[]},
          "pagination":{"first":24,"after":null},"user":{"abGroup":"gruppe-d","userSegment":"segment_0"},"tabId":null}}
```
→ `data.metaCollectionContent.tabs[] {id:"genre-10292",label:"Thriller"}`, `pageInfo{hasNextPage,endCursor}`, `smartCollections[]`.
Use `tabId:"genre-10292"` for a sub-genre and `pagination.after:<endCursor>` for the next page (both tested). The `appId`/`user` values come from MServer and are required by the input type.
- Add teaser images by extending `smartCollections { … teaser { imageWithoutLogo { layouts { dim768X432 } } } }` (same `ISmartCollection` fields as above).

#### Shows A–Z
```graphql
query SofaAZ($tabIndex: Int, $after: Cursor, $first: Int) {
  specialPageByCanonical(canonical: "sendungen-100") {
    ... on Catalog {
      tabs { nodes { title index count } }
      content(filterBy: {tabIndex: $tabIndex}, after: $after, first: $first) {
        totalCount pageInfo { hasNextPage endCursor }
        nodes { __typename
          ... on ISmartCollection { canonical title collectionType teaser { description imageWithoutLogo { layouts { dim768X432 } } } }
          ... on MetaCollection { canonical title } }
      }
    }
  }
}
variables: {"tabIndex":12,"first":100}
```
`tabs.nodes[]` = `{title:"A",index:0,count:34} … {title:"I",index:10} … {title:"Z",index:31} {title:"0 - 9",index:32}`.
**Indices are not contiguous**, so always use `index` from `tabs`. Tested: K = 28 shows on one page with `first:100`.
(MServer uses the persisted op `specialPageByCanonical` with sha256 `63848395d2f977dbf99ce30172c8d80038a54615574295eee6f8704c5e6fcbee`, which also works today.)

#### Show → episodes (pagination)
Every series-like collection (`DefaultNoSections`, `DefaultWithSections`, `SeasonSeries`, …) exposes `seasons`. Movies expose `video`.
```graphql
query SofaShow($canonical: String!, $first: Int, $after: Cursor, $seasonIndex: Int) {
  smartCollectionByCanonical(canonical: $canonical) {
    __typename id canonical title collectionType
    ... on ISeriesSmartCollection {
      countSeasons countEpisodes
      seasons(first: 1, offset: $seasonIndex) {
        nodes { number title countEpisodes
          episodes(first: $first, after: $after, sortBy: [{field: EDITORIAL_DATE, direction: DESC}]) {
            pageInfo { hasNextPage endCursor }
            nodes { canonical title editorialDate }   # add VideoFragment fields as needed (see Video below)
          } }
        pageInfo { hasNextPage endCursor }
      }
    }
    ... on MovieSmartCollection { video { canonical title } }
  }
}
variables: {"canonical":"heute-journal-104","seasonIndex":0,"first":24}
```
Tested:
- `bares-fuer-rares-104` → DefaultNoSections, 5 seasons, 549 episodes. Season 0 = `number:2026,countEpisodes:196`.
- `heute-journal-104` → 7 seasons (years).
- `das-institut-100` → SeasonSeries, "Staffel 1".
- `longlegs-movie-100` → Movie, `video.canonical:"longlegs-100"`.

Season picker: iterate `seasonIndex` 0..`countSeasons-1` (season 0 = newest for year-seasons). Episodes page: pass `after: pageInfo.endCursor` while `hasNextPage`.
yt-dlp and MServer use page size 24. The show title is the collection `title`. The show description is not in the query above; extend the query with `teaser { description }`.

#### Search
```graphql
query SofaSearch($query: String!, $first: Int, $after: Cursor) {
  searchDocuments(query: $query, first: $first, after: $after) {
    pageInfo { hasNextPage endCursor }
    results { item { __typename
      ... on Video { canonical title editorialDate currentMediaType teaser { description } smartCollection { canonical title } }
      ... on ISmartCollection { canonical title collectionType }
      ... on MetaCollection { canonical title } } }
  }
}
variables: {"query":"tatort","first":24}     # next page: "after":"NQ==" (cursor is base64 offset)
```
→ `data.searchDocuments.results[].item`. Mixed shows and videos. ZDF also indexes ARD collections (`collection-index-page-ard-…`, `page-video-ard-…`).
The web client also passes optional `mode: SearchMode` and `filters: SearchFilters`. Neither is needed.

#### Video detail (metadata + stream handles)
```graphql
query SofaVideo($canonical: String!) {
  videoByCanonical(canonical: $canonical) {
    id canonical title editorialDate sharingUrl
    availability { fskBlocked vod { visibleFrom visibleTo endDate fsk } }
    teaser { title description image { list } imageWithoutLogo { layouts { dim768X432 dim1280X720 dim1920X1080 original } } }
    episodeInfo { seasonNumber episodeNumber }
    smartCollection { canonical title }
    currentMedia { nodes { ptmdTemplate
      ... on VodMedia { duration aspectRatio vodMediaType geoLocation downloadAllowed }
      ... on LiveMedia { liveMediaType geoLocation tvService } } }
  }
}
```
Trimmed real response (`heute-journal-vom-2-november-2026-100`):
```json
{"data":{"videoByCanonical":{
 "title":"heute journal vom 2. November 2026","editorialDate":"2026-11-02T20:45:00.000000+00:00",
 "availability":{"fskBlocked":false,"vod":{"visibleFrom":"2026-11-02T20:45:00…","visibleTo":"2027-11-02T20:45:00…","endDate":"2027-11-03T00:00:00…","fsk":"none"}},
 "teaser":{"description":"Mit den Themen: …","image":{"list":{"dim2400x1350":"https://epg-image.zdf.de/…?layout=2400x1350",…}},
           "imageWithoutLogo":{"layouts":{"dim1280X720":"https://epg-image.zdf.de/fotobase-webdelivery/images/273e5545-…?layout=1280x720",…}}},
 "episodeInfo":{"seasonNumber":2026,"episodeNumber":327},
 "smartCollection":{"canonical":"heute-journal-104","title":"heute journal"},
 "currentMedia":{"nodes":[
   {"ptmdTemplate":"/tmd/2/{playerId}/vod/ptmd/mediathek/261102_2145_sendung_hjo_dgs/4?caption_source=…","duration":1772,"aspectRatio":"16:9","vodMediaType":"DGS","geoLocation":"NONE"},
   {"ptmdTemplate":"/tmd/2/{playerId}/vod/ptmd/mediathek/261102_2145_sendung_hjo/4","duration":1772,"aspectRatio":"16:9","vodMediaType":"DEFAULT","geoLocation":"NONE"}]}}}}
```
Field mapping: title=`title`, show=`smartCollection.title`, description=`teaser.description` (yt-dlp prefers `leadParagraph`, which also exists),
duration=`currentMedia.nodes[].duration` (seconds), date=`editorialDate`, availability end=`availability.vod.visibleTo` (fallback `endDate`),
geo=`currentMedia.nodes[].geoLocation` (`NONE` | `DE` | `DACH`), FSK=`availability.fskBlocked`, `vod.fsk`.
`currentMedia.nodes` is empty for scheduled or not-yet-available items (`scheduledMedia{availableFrom}` is in the web fragment).

### Stream resolution (PTMD)
1. Choose the `currentMedia` node with `vodMediaType == "DEFAULT"`. Other values are `DGS` (sign language) and `AD` (audio description). Then replace `{playerId}`:
   `https://api.zdf.de` + `ptmdTemplate.replace("{playerId}","android_native_6")` (yt-dlp's choice). `ngplayer_2_5` and `smarttv_6` also work.
2. `GET` it with `Api-Auth: Bearer <token>`. Real response (trimmed):
```json
{"basename":"261102_2145_sendung_hjo","attributes":{"duration":{"value":1772000},"geoLocation":{"value":"none"}},
 "captions":[{"format":"webvtt","uri":"https://…/02112026_hjo.vtt"},{"format":"ebu-tt-d-basic-de","uri":"…xml"}],
 "priorityList":[{"formitaeten":[
   {"mimeType":"video/mp4","type":"h264_aac_mp4_http_na_na","qualities":[
      {"quality":"hd","highestVerticalResolution":720,"mimeCodec":"avc1.640028, mp4a.40.2",
       "audio":{"tracks":[{"class":"main","language":"deu","uri":"https://nrodlzdf-a.akamaihd.net/none/zdf/26/11/261102_2145_sendung_hjo/1/261102_2145_sendung_hjo_3328k_p15v17.mp4"}]}},
      {"quality":"fhd","highestVerticalResolution":1080,…"_6628k_p61v17.mp4"}, {"quality":"veryhigh",540,…}, {"quality":"high",360,…}, {"quality":"low",270,…}]},
   {"mimeType":"application/x-mpegURL","type":"h264_aac_ts_http_m3u8_http","qualities":[{"quality":"auto","audio":{"tracks":[{"uri":"https://…/…,_508k_p9,_808k_p11,_1628k_p13,_3328k_p15,_6628k_p61,v17.mp4.csmil/master.m3u8"}]}},…]},
   {"mimeType":"video/webm","type":"vp9_opus_webm_http_na_na",…}]}]}
```
Selection: iterate `priorityList[].formitaeten[]`, use `mimeType=="video/mp4"`, then `qualities[]` with `highestVerticalResolution==720`
(`quality:"hd"`), then `audio.tracks[]` with `class=="main"` && `language=="deu"` (skip `class:"ad"`). Fallback: `mimeType=="application/x-mpegURL"`, `quality=="auto"`.
Skip webm (VP9). The `smarttv_6` player id returns MP4 1080/720/576 at higher bitrates (`_3360k_p36v17.mp4` for 720p) and no webm.
MP4 URLs are plain HTTPS (HTTP 200, `video/mp4`). They are not signed and do not expire.

### Images
- Use `teaser.imageWithoutLogo.layouts.dimWxH` (GraphQL field names: `dim384X216 dim768X432 dim1280X720 dim1920X1080 dim276X311 dim314X314 dim640X720 dim1200X480 dim1800X720 original`, and on collections also `dim1140X240 dim225X400 dim2400X1350 dim3840X2160 …`).
  Values can be `null`, so fall back to another size.
- `teaser.image.list` is a JSON map such as `{"dim1280x720": url, …}` with all available layouts.
- URL shapes: `https://www.zdf.de/assets/<name>~1280x720?cb=<n>` and `https://epg-image.zdf.de/fotobase-webdelivery/images/<uuid>?layout=1280x720`.
  **Only listed layouts exist.** `~960x540` → 404 and `layout=960x540` → 412, so pick from the returned map and do not build URLs by template.

### Live
- Channel list: hard-code the canonicals below, or use `getActiveLiveStreams` (`videos(filterBy:{availableStreamTypeIn:[LIVE,SCHEDULED_LIVE]})`). It works but returns about 60 nodes including many internal "Test" streams.
- PTMD: `GET https://api.zdf.de/tmd/2/android_native_6/live/ptmd/247onAir-<id>` (+Api-Auth). In the response, `priorityList[0].formitaeten[0]` has `mimeType:"application/x-mpegURL"`,
  and `qualities[]` has `quality` ∈ `auto|veryhigh|high|med|low`. Use `auto` (`…/high/master.m3u8`). `attributes.geoLocation.value` ∈ `de|dach`.

| Channel | canonical | PTMD id | HLS (auto) | geo | from AT |
|---|---|---|---|---|---|
| ZDF | zdf-live-beitrag-100 | 247onAir-201 | https://zdf-hls-15.akamaized.net/hls/live/2016498/de/high/master.m3u8 | de | **403** |
| ZDFneo | zdfneo-live-beitrag-100 | 247onAir-202 | https://zdf-hls-16.akamaized.net/hls/live/2016499/de/high/master.m3u8 | de | **403** |
| ZDFinfo | zdfinfo-live-beitrag-100 | 247onAir-203 | https://zdf-hls-17.akamaized.net/hls/live/2016500/de/high/master.m3u8 | de | **403** |
| 3sat | 3sat-live-beitrag-100 | 247onAir-204 | https://zdf-hls-18.akamaized.net/hls/live/2016501/dach/high/master.m3u8 | dach | 200 |
| phoenix | phoenix-live-beitrag-100 | 247onAir-205 | https://zdf-hls-19.akamaized.net/hls/live/2016502/de/high/master.m3u8 | de | **403** |
| KiKA | kika-live-beitrag-100 | 247onAir-207 | https://kika-live.ard-mcdn.de/kika/live/hls/de/master.m3u8 → 302 kikahls…/livetvkika_ww/master.m3u8 | ww | 200 |
| arte | arte-livestream-100 | 247onAir-208 | https://artelivezdf.akamaized.net/hls/live/2030993/artelive_de/index.m3u8 | de | **403** |

Resolve the PTMD at runtime rather than storing these URLs (hosts can change). The 3sat HLS has 3 audio renditions (TV-Ton, Klare Sprache, AD).
- EPG ("now on"):
```graphql
query SofaEpg($filter: EPGFilter!) { epg(filter: $filter) {
  broadcaster { id title now { title airtimeBegin airtimeEnd } } broadcasts { title airtimeBegin airtimeEnd } } }
variables: {"filter":{"broadcasterIds":["ZDF","ZDFneo","ZDFinfo","3sat","PHOENIX","KI.KA","arte"],"from":"2026-11-03T07:00:00+01:00","to":"2026-11-03T09:00:00+01:00"}}
```
→ `data.epg[] {broadcaster{id:"3sat",now{title:"ZIB",…}}, broadcasts[]}` (tested).

### Pitfalls (ZDF)
- **Geo**: the MP4 URL path encodes the geo zone: `…akamaihd.net/none/…` (worldwide), `/dach/…`, `/de/…`. From AT, `/de/` → **403** (tested: `longlegs-100`,
  `geoLocation:"DE"`, `https://nrodlzdf-a.akamaihd.net/de/zdf/26/10/261026_2215_sendung_spf/…_3328k_p15v17.mp4` → 403). Use `currentMedia.nodes[].geoLocation=="DE"`
  to mark such items before playback. Most films and series are DE-only; news and magazines are mostly `NONE`.
- ZDF main live channels are DE-only. Only 3sat (DACH) and KiKA play from AT.
- Persisted-query hashes (yt-dlp `seasonByCanonical` 9412a0…, `GetSmartCollectionByCanonical` cb4942…; MServer 63848…, 81237…, c85ca9…) break when ZDF redeploys.
  Free-form queries are safer. If the server ever rejects free-form queries, fall back to these hashes via GET with `operationName`, `variables` and
  `extensions={"persistedQuery":{"version":1,"sha256Hash":…}}` plus `Apollo-Require-Preflight: true`.
- `videoByCanonical` returns `null` for some zdfheute.de/logo.de pages. yt-dlp then falls back to `https://zdf-prod-futura.zdf.de/mediathekV2/document/<id>` (`document.streamApiUrlAndroid` → PTMD).
- `fskBlocked:true` (FSK 16/18) means the item may only be played 22:00–06:00. Hide it or show a notice.

---

## 2. ARD Mediathek (incl. Das Erste, BR, HR, MDR, NDR, RB, RBB, SR, SWR, WDR, ONE, alpha, tagesschau24, phoenix, funk, KiKA)

Plain JSON REST ("page-gateway"). **No auth, no token, no headers** required.
Base URL: `https://api.ardmediathek.de/page-gateway`. `{client}` = `ard` (all) or a regional/partner client:
`daserste br hr mdr ndr radiobremen rbb sr swr wdr one alpha tagesschau24 phoenix funk kika 3sat`.
The same item id works under any client.

### Auth
None. (Only optional: 18+ content via an `ams` login cookie + `x-authorization: Bearer <idToken>`. This is not needed.)

### Endpoints
| Purpose | Request | Response key paths |
|---|---|---|
| Start page | `GET /pages/{client}/home?embedded=true` | `widgets[] {type,title,compilationType,pagination{pageNumber,pageSize,totalElements},teasers[],links.self.href}` |
| Shelf paging | `GET /widgets/ard/editorials/{widgetId}?pageNumber=N&pageSize=M&embedded=true` (= `widgets[].links.self.href` with pageNumber changed) | `teasers[]`, `pagination` |
| Rubriken list | `widgets[]` with `title=="Rubriken"` on home, or `GET /pages/ard/compilation/alle-rubriken?embedded=true` | teasers `type:"editorialPage"` → `links.target.href` e.g. `/pages/ard/editorial/filme?embedded=true` |
| Rubrik page | `GET /pages/ard/editorial/{filme|serien|dokus|tagesschau|sport|kinderfamilie|shows_comedy|kultur|barrierefrei}?embedded=true` | same widget structure (filme: 31 widgets) |
| A–Z | `GET /pages/{client}/editorial/experiment-a-z?embedded=true` | `widgets[]` one per letter (`title:"A"`…), `teasers[]` (`type:"show"` or `editorialPage`) |
| Show page | `GET /pages/ard/grouping/{showId}?embedded=true` | `title, synopsis, images, widgets[0]` (gridlist of episodes, `links.self.href` = asset widget URL) |
| Show episodes | `GET /widgets/ard/asset/{showId}?pageNumber=0&pageSize=48[&seasoned=true&seasonNumber=N]` | `title`, `pagination{totalElements}`, `teasers[] (type:"ondemand")` |
| Compilation ("sammlung") | `GET /compilations/ard/{id}?pageNumber=0&pageSize=100` (yt-dlp) | `teasers[]` |
| Search videos | `GET /widgets/ard/search/vod?searchString=tatort&pageNumber=0&pageSize=24` | `teasers[]`, `pagination.totalElements` (2166) |
| Search shows | `GET /widgets/ard/search/grouping?searchString=tatort&pageNumber=0&pageSize=24` | `teasers[] (type:"show")` (47) |
| Item / stream | `GET /pages/ard/item/{itemId}?embedded=true&mcV6=true` | see below |
| EPG | `GET https://programm-api.ard.de/program/api/program?day=2026-11-03&channelIds=daserste&mode=channel` | `channels[].timeSlots[][]` |

A–Z tested: `ard` = 315 entries (curated subset), `daserste` = 302, `br` = 355. For a full catalog, merge the per-client A–Z pages and de-duplicate by `links.target.id` (this is what MServer does).
Under `embedded=false` the letter widgets have empty `teasers`, so use `embedded=true`.

Teaser (trimmed, real):
```json
{"type":"ondemand","coreAssetType":"EPISODE","id":"1FdQ5oz2JK6o2qmyqMsqiI:-5960296620350612879",
 "shortTitle":"Sie haben Namen | Team Rostock","longTitle":"Sie haben Namen | Team Rostock","duration":5302,
 "availableTo":"2027-11-01T19:15:00Z","broadcastedOn":"2026-11-01T19:15:00Z","maturityContentRating":"FSK12","binaryFeatures":["UT","DGS","AD"],
 "images":{"aspect16x9":{"src":"https://api.ardmediathek.de/image-service/images/urn:ard:image:77b68b90f6748163?w={width}&ch=8813477fb9e3f27f","alt":"…"},
           "aspect3x4":{"src":"…?ch=…&w={width}"}},
 "publicationService":{"name":"NDR","partner":"ndr"},
 "show":{"id":"crid://daserste.de/polizeiruf 110","title":"Polizeiruf 110","coreAssetType":"INFINITE_SERIES","hasSeasons":false,…},
 "links":{"target":{"id":"Y3JpZDovL25kci5kZS9mMDUzYjdmYi0zNDQ5LTQyY2MtYWQxNC1lMzY1YzM2MjE1YmQ",
                    "href":"https://api.ardmediathek.de/page-gateway/pages/ndr/item/Y3Jp…?devicetype=pc&embedded=true","type":"application/vnd.ard.page+json"}}}
```
Navigate by `type`:
- `ondemand` / `live` → item (`links.target.id`).
- `show` → grouping (`links.target.id` = showId, base64 of a crid).
- `compilation` / `editorialPage` → follow `links.target.href`.
- `external` → skip (for example the ZDF link in the live shelf).

### Stream resolution
`GET /pages/ard/item/{itemId}?embedded=true&mcV6=true`. In the response, find `widgets[]` with `type ∈ {player_ondemand, player_live}`:
```json
{"type":"player_ondemand","title":"Sie haben Namen","synopsis":"…","geoblocked":false,"blockedByFsk":false,
 "availableTo":"2027-11-01T19:15:00Z","broadcastedOn":"2026-11-01T19:15:00Z","maturityContentRating":"FSK12",
 "show":{"title":"Polizeiruf 110","id":"Y3JpZDovL2Rhc2Vyc3RlLmRlL3BvbGl6ZWlydWYgMTEw"},
 "mediaCollection":{"embedded":{
   "isGeoBlocked":false, "geoBlocking":null,
   "meta":{"durationSeconds":5302,"title":"…","synopsis":"…","seriesTitle":"…","broadcastedOnDateTime":"…","images":[{"url":"…?w=960&ch=…"}]},
   "streams":[{"kind":"main","kindName":"Normal","media":[
      {"mimeType":"application/vnd.apple.mpegurl","url":"https://…/TV-20261027-2057-3400.,ln,1080,hd,hq,mn,.mp4.csmil/master.m3u8","audios":[{"kind":"standard","languageCode":"deu"}],"maxVResolutionPx":1080,"videoCodec":"H.264"},
      {"mimeType":"video/mp4","url":"//ndr-progressive.ard-mcdn.de/progressive/2026/1027/TV-20261027-2057-3400.hd.mp4",
       "audios":[{"kind":"standard","languageCode":"deu"}],"maxHResolutionPx":1280,"maxVResolutionPx":720,"videoCodec":"H.264","forcedLabel":"HD 720p","isProtocolRelative":true},
      {"mimeType":"video/mp4",…,"videoCodec":"H.265",…}, …]},
    {"kind":"sign-language","kindName":"DGS","media":[…]}],
   "subtitles":[{"languageCode":"deu","sources":[{"kind":"webvtt","url":"…"},{"kind":"ebutt","url":"…"}]}]}}}
```
Selection: use `streams[]` with `kind=="main"`, then `media[]` where `mimeType=="video/mp4"` && `videoCodec=="H.264"` (**skip H.265**, which 10.9 cannot decode)
&& `audios[0].kind=="standard"` (skip `audio-description`; it is mixed into the same array) && `maxVResolutionPx==720`.
Fallback: `mimeType=="application/vnd.apple.mpegurl"` with `audios[0].kind=="standard"`.
**URLs may be protocol-relative (`//host/...`). Prepend `https:`.** Hosts seen: `*-progressive.ard-mcdn.de`, `ctv-videos.daserste.de`, `cdn-storage.br.de`
(all HTTPS, HTTP 200 from AT, unsigned). If there is no player widget, the item is not playable yet (future or trailer only).

### Images
`https://api.ardmediathek.de/image-service/images/urn:ard:image:<id>?w={width}&ch=<hash>`. Replace `{width}` with any integer (tested `w=1280` → 200, 256 KB).
The `ch` parameter is optional. Aspect keys: `aspect16x9`, `aspect16x7`, `aspect3x4` (posters), `aspect1x1`. On a show: `images["16x9"]`, …

### Live
The channel list is the home widget `title=="Unsere TV-Programme live"` (teasers `type:"live"`). Resolve each with the item endpoint (`player_live`), stream `kind:"main"` → `mimeType:"application/vnd.apple.mpegurl"`.
Tested from AT (`de` URLs auto-302 to the international `int` feed where one exists):

| Channel | HLS (from API) | from AT |
|---|---|---|
| Das Erste | https://daserste-live.ard-mcdn.de/daserste/live/hls/de/master.m3u8 → …/hls/int/master.m3u8 | 200 (int) |
| BR | https://mcdn.br.de/br/fs/bfs_sued/hls/de/master.m3u8 → …/int/… | 200 |
| hr | https://hr-live.ard-mcdn.de/hr/live/hls/de/master.m3u8 → hrhls.akamaized.net/…/index.m3u8 | 200 |
| NDR | https://mcdn.ndr.de/ndr/hls/ndr_fs/ndr_nds/master.m3u8 → ndrint.akamaized.net/… | 200 |
| WDR | https://wdr-live.ard-mcdn.de/wdr/live/hls/de/master.m3u8 → …/int/… | 200 |
| ARD alpha | https://mcdn.br.de/br/fs/ard_alpha/hls/de/master.m3u8 → …/int/… | 200 |
| tagesschau24 | https://tagesschau-live.ard-mcdn.de/tagesschau/live/hls/de/master.m3u8 → tagesschau.akamaized.net/… | 200 |
| KiKA | https://kika-live.ard-mcdn.de/kika/live/hls/de/master.m3u8 → kikahls…/livetvkika_ww | 200 |
| 3sat | https://zdf-hls-18.akamaized.net/hls/live/2016501/dach/high/master.m3u8 | 200 |
| MDR, rbb, SR, SWR, Radio Bremen, ONE, arte, phoenix | (various) | **403 geo** |

The international feeds (`int`) show a slate during rights-restricted programmes (sport, films). Regional variants (NDR Hamburg/SH/MV, MDR Thüringen/Sachsen-Anhalt, BR Nord, SWR RP, rbb Berlin)
are separate items, reachable via the client's own home page (`/pages/ndr/home`) live widget.

### Pitfalls (ARD)
- **Geo**: `mediaCollection.embedded.geoBlocking = {"regionCheckUrl":"https://geo-check.ard-mcdn.de/test/de.txt","expectedResponse":"1","regionName":"Deutschland"}`.
  From AT, `test/de.txt` → 403 and `test/dach.txt` → `1`. Real implementation: fetch both check URLs once per session, then mark items whose `regionCheckUrl` does not answer `1`.
  Tested: DE-only `…/content-de/….mp4` and `…/deutschlandweit/….mp4` → 403. DACH films (`progressive_geo_dach`, `ctv-videos.daserste.de/dach/…`) → 200.
  **`isGeoBlocked` / `geoblocked` alone are not reliable for live** (SR/SWR report `false` and still return 403).
- `blockedByFsk:true` → only 22:00–06:00 (or 23:00 for FSK18) without login. Show a notice.
- Item and show ids in `links.target.id` are unpadded base64 crids. Pass them through unchanged in URL paths.
- AD versions appear as separate teasers ("… (Audiodeskription)"). Filter them by title suffix or by `binaryFeatures`.

---

## 3. ORF ON (ORF 1, ORF 2 + regional, ORF III, ORF SPORT +)

REST API `https://api-tvthek.orf.at/api/v4.3` (HAL-style JSON). v4.4/v4.5/v5 → 404.
Paged lists look like `{page,limit,pages,total,_links{next…},_embedded{items[]}}`. Some lists (`lane/*`, schedule) use `_items[]` instead.

### Auth
Static HTTP Basic credentials (from MServer `OrfOnConstants.AUTH`, which decodes to `orf_on_v43:jFRsbNPFiPSxuwnLbYDfCLUN5YNZ28mt`):
```
Authorization: Basic b3JmX29uX3Y0MzpqRlJzYk5QRmlQU3h1d25MYllEZkNMVU41WU5aMjhtdA==
```
Without it → 401. No rotation observed (hard-coded in the app). Exception: `GET /public/episode/encrypted/{base64("3dSlfek03nsLKdj4Jsd"+episodeId)}` works without auth (yt-dlp).

### Endpoints
| Purpose | Request | Response key paths |
|---|---|---|
| Start page | `GET /page/start` | array of lanes `[{type:"hero"|"categories"|"lane"|"mostviewed", id, layout:"poster"|null, title, videos:<count>, _links.self(.href)}]` (33 entries). `_links.self` may be a string or `{href}` |
| Lane content | `GET /lane/{id}?limit=20&page=N` (also `/lane/mostviewed`, `/page/startpage/highlights`) | `{page,limit,page_count,total,next,title,_items[]}` |
| Categories | `GET /page/start/genres` (19) or `GET /genres` | `[{id:2703825,title:"ZIB & Info",_links.self.href:".../genre/2703825"}]` |
| Category shows | `GET /genre/{id}/profiles?limit=50&page=N` | `{page,limit,pages,total,_embedded.items[] (profile)}` (Sport: 87) |
| A–Z | `GET /profiles/lettergroup/{A..Z,0}?limit=200` (MServer page size 200) | `_embedded.items[] {id,title,_links.episodes.href}` (A: 79) |
| Show | `GET /profile/{id}` | `id,title,description,_links{episodes,latest_episode,…},_embedded.image…` |
| Show episodes | `GET /profile/{id}/episodes?limit=50&page=N` | `_embedded.items[]` (episodes) |
| Search | `GET /search/{query}?limit=20` | `search.episodes{total,page_count,next,items[]}`, `search.history{…}`, `suggestions{…}`. Next page: `next` → `/search-partial/episodes/{q}?limit=&page=` |
| Episode / stream | `GET /episode/{id}` | see below |
| Schedule (Sendung verpasst) | `GET /schedule/{YYYY-MM-DD}?limit=200` | array of episodes |
| Live now | `GET /livestreams` | `{orf1:{items[]},orf2:{…},orf3:{…},orfs:{…},live_special:{…}}` |
| Live detail | `GET /livestream/{id}` | `sources{hls[],dash[]}` |
| Channels | `GET /channels` | `_embedded.items[] {id,name,reel}` (1180 ORF 1 `orf1`, 1181 ORF 2 `orf2`, 3026625 ORF III `orf3`, 76464 ORF SPORT+ `orfs`, 3299861 ORF 2 Wien `orf2w`, …) |

Episode item (trimmed, real, `/lane/13869361` → `_items[0]`):
```json
{"id":14345720,"title":"Benko - Size Does Matter","headline":"…","sub_headline":"Aufstieg und Fall eines Immobilienimperiums",
 "description":"Der fiktionale Spielfilm …","date":"2026-11-02T20:15:00+01:00","delete_date":"2027-05-31T20:15:00+02:00","killdate":"2027-05-01T20:15:00+02:00",
 "duration_seconds":5336,"genre_title":"Film","right":"austria","is_drm_protected":false,"age_classification":"12+",
 "youth_protection_type":"limited-20-06","has_active_youth_protection":false,"has_subtitle":true,"video_type":"episode",
 "share_body":"https://on.orf.at/video/14345720/benko-size-does-matter",
 "_links":{"self":{"href":"https://api-tvthek.orf.at/api/v4.3/episode/14345720"}},
 "_embedded":{"image":{"public_urls":{"highlight_teaser":{"url":"https://api-tvthek.orf.at/assets/segments/0242/83/thumb_24182184_segments_highlight_teaser.jpg"},
                                     "player":{…},"list":{…},"small":{…},"reference":{…}}},"image2x3":{…},"image16x9_with_logo":{…}}}
```
Field mapping: title=`title`, show=`profile_title` (on `/episode`), description=`description` (fallback `teaser_text`),
duration=`duration_seconds` (`exact_duration` in ms), broadcast date=`date`, availability end=`delete_date` (UI also shows `countdown`),
geo=`right` (`austria` = AT-only, `worldwide`), DRM=`is_drm_protected`.

### Stream resolution
`GET /episode/{id}` → `sources.hls[]` / `sources.dash[]`:
```json
"sources":{"hls":[
  {"quality_key":"Q4A","quality_description":"Mittel","src":"https://apasfiis.sf.apa.at/ipad/cms-worldwide_episodes/14345752_0013_Q4A.mp4/playlist.m3u8","is_adaptive_stream":false,"is_drm_protected":false},
  {"quality_key":"Q6A","quality_description":"Hoch",…}, {"quality_key":"Q8C","quality_description":"Sehr hoch",…},
  {"quality_key":"QXA","quality_description":"Adaptiv","src":"…_QXA.mp4/playlist.m3u8","is_adaptive_stream":true},
  {"quality_key":"QXB","quality_description":"Adaptiv",…}],
 "dash":[…same keys, …/dash/…/manifest.mpd]}
```
- **Use `quality_key=="QXA"` (adaptive HLS).** Tested: the single-quality Q4A/Q6A/Q8C playlists now redirect to
  `https://vod-ww.mdn.ors.at/gp_nas/…/insert_video_not_available_Q8C.mp4/playlist.m3u8` (a placeholder clip). This happened for worldwide and Austria-only items alike.
  `QXA` 301-redirects to a working Wowza `.smil` master, for example `https://vod-at.mdn.ors.at/cms-austria_nas/_definst_/nas/cms-austria/online/…_s16178741.smil/playlist.m3u8`:
  `EXT-X-MEDIA TYPE=AUDIO` (de, AAC, separate `.aac` chunks) + video-only TS variants 512x288 … 1280x720 (4.165 Mbit) … 1920x1080 (6.1 Mbit).
  AVFoundation follows the redirects itself. `QXB` gives the same ladder (`_hr.smil`).
- **No progressive MP4**: `https://apasfpd.sf.apa.at/cms-austria/…_Q8C.mp4` → 302 to `/gp/online/insert_geoprotection_q8c.mp4`. MServer also only emits HLS URLs for ORF now.
- Segmented items (ZIB etc.): root `sources` = the full show. `_embedded.segments[]` have their own `sources`. Use the root unless `sources` is empty (then play the segments as a playlist, as yt-dlp does).
- Subtitles: `_embedded.subtitle.{srt_url,ttml_url,sami_url,vtt_url}`.
- `is_drm_protected:true` → `sources` are `QXADRM/QXBDRM` (FairPlay/Widevine) → **not playable on 10.9**. Filter these out.

### Images
Fixed named sizes in `_embedded.image.public_urls` (measured): `highlight_teaser` 1280x720, `player` 640x360, `list` 320x180, `small` 120x68, `reference` (original).
Posters are in `image2x3.public_urls.*`, and variants with the channel logo in `image16x9_with_logo`. There is no width template.

### Live
`GET /livestreams` gives the current programme per channel. Then `GET /livestream/{items[0].id}` gives the sources (tested 07:13 UTC):

| Channel | current item | sources | from AT |
|---|---|---|---|
| ORF 1 | Young Sheldon (`right:austria`) | `QXADRM` https://orf1.mdn.ors.at/orf/orf1/drmqxa/manifest.m3u8 (`#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://drm.ors.at/acquire-license/fairplay?…"`) | **DRM** |
| ORF 2 | ZIB 8:00 (`worldwide`) | `QXADRM` https://orf2w.mdn.ors.at/orf/orf2w/drmqxa/manifest.m3u8 | **DRM** |
| ORF III | WETTER/INFO | `QXA` https://orf3.mdn.ors.at/orf/orf3/qxa/manifest.m3u8 (non-DRM; also Q4A/Q6A/Q8C `…/out/u/orf3/q8c/manifest.m3u8`, though q8c → 403 at test time) | 200 |
| ORF SPORT + | Yoga-Magazin | DRM | **DRM** |

The non-DRM paths `https://orf1|orf2|orfs.mdn.ors.at/orf/<ch>/qxa/manifest.m3u8` → **403**. Only the `drmqxa` variants exist for ORF 1/2/S+.
A `drmqxa` manifest loads (200) and looks playable, but segments are SAMPLE-AES FairPlay encrypted. FairPlay Streaming is not available to third-party apps on OS X 10.9
(it needs a newer AVFoundation with FPS key delivery plus an ORF-issued application certificate), so **ORF 1/2/Sport+ live is a blocker**. DRM is decided per broadcast item (`is_drm_protected`), so check it each time.
`live_special` (events, press conferences) and ORF III are usually non-DRM.

### Pitfalls (ORF)
- Geo: `right:"austria"` content works from AT (HLS via `vod-at.mdn.ors.at`). `https://apasfiis.sf.apa.at/admin/proxycheck/` returns `<xml ip=… isallowed="true" isproxy="false">` and is what the web player uses to show its geo banner.
- `youth_protection_type:"limited-20-06"` is set on almost everything. Only `has_active_youth_protection:true` actually restricts playback to 20:00–06:00.
- Lists are mixed `_items` vs `_embedded.items`, and `_links.self` is a string or an object. Parse defensively.
- `delete_date` / `killdate` are local times with offset. `date` is the broadcast time.

---

## Recommended per-feature mapping (summary)

| Feature | ZDF | ARD | ORF |
|---|---|---|---|
| Home shelves | GQL `curatedCollectionByCanonical("mt2025-startseite-100")` | `/pages/ard/home?embedded=true` | `/page/start` → `/lane/{id}` |
| Categories | "Kategorien" cluster → GQL `metaCollectionContent` | Rubriken widget → `/pages/ard/editorial/{x}` | `/page/start/genres` → `/genre/{id}/profiles` |
| A–Z | GQL `specialPageByCanonical("sendungen-100")` tabs | `/pages/{client}/editorial/experiment-a-z` | `/profiles/lettergroup/{L}` |
| Episodes | GQL `smartCollectionByCanonical.seasons.episodes` (cursor) | `/widgets/ard/asset/{showId}?pageNumber=` | `/profile/{id}/episodes?page=` |
| Search | GQL `searchDocuments` | `/widgets/ard/search/vod` + `/grouping` | `/search/{q}` |
| Stream | PTMD `android_native_6` → MP4 720p H.264 | item `player_*` → MP4 H.264 720p (`https:` prefix) | `/episode/{id}` → HLS `QXA` |
| Live | PTMD `live/ptmd/247onAir-2xx` | home "live" widget → item | `/livestreams` → `/livestream/{id}` |
| Auth | `mediathekV2/token` (daily) | none | static Basic |
