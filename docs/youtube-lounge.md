# Sofa – YouTube "Link with TV code" receiver (Lounge API)

Status: researched from the receiver sources **and live-tested on 2026-11-03** from this
iMac (macOS 10.9.5, `/opt/local/bin/python3` 3.14, plain HTTPS to `www.youtube.com`, no
cookies, no API key, no User-Agent games). Everything marked **[live]** was observed on
the wire; **[src]** means "taken from the reference implementations, not reproducible
without a real phone".

Probes (both in `docs/probes/`):

* `lounge_probe.py` – complete Python receiver (stdlib only) with a *simulated* player.
  Persists screen id/device id, prints a TV code, keeps the long-poll alive, answers the
  phone. `--self-test` additionally runs a built-in sender (the same plain requests
  `pyytlounge` makes) that resolves the code, connects as `REMOTE_CONTROL` and sends
  `setPlaylist → pause → seekTo → play → getNowPlaying`. That gave a full round-trip
  **without a phone** (§9).
  Run: `unset DYLD_INSERT_LIBRARIES; /opt/local/bin/python3 -I docs/probes/lounge_probe.py`
  (options `--name`, `--duration`, `--self-test`, `--raw`, `--new-screen`; state in
  `~/Library/Caches/sofa-lounge-probe.json`). On the phone: YouTube → Settings →
  "Auf TV ansehen" → "Mit TV-Code verbinden", enter the printed code, cast a video.
* `lounge_stream.m` – ObjC test, shows which 10.9 HTTP stacks deliver the long-poll
  chunks in time. **NSURLSession does not** (§8.1) – this matters for the implementation.

Reference sources (fetched 2026-11-03): `yt-cast-receiver` 2.1.1 (patrickkfkan, Node/TS,
receiver), `plaincast` (aykevl, Go, receiver), `pyytlounge` (FabioGNR, Python, sender),
`casttube` (ur1katz, Python, sender).

---

## 0. TL;DR

```
 once, persisted          every start                     every ~5 min while "pair" UI shown
 ───────────────          ──────────────────────────      ──────────────────────────────────
 generate_screen_id  ──▶  get_lounge_token_batch     ──▶  get_pairing_code  ──▶ show "123 456 789 012"
 (screenId, 26 chars)     (loungeToken, 14 d)
 + own deviceId (UUID)         │
                               ▼
                          POST bc/bind  (count=0)   ──▶  SID + gsessionid + first messages
                               │
                               ▼
              ┌──▶ GET  bc/bind RID=rpc …  long-poll (server closes after ~5 min, noop every ~28 s)
              └─── reconnect immediately with same SID, AID = last index seen
                   POST bc/bind count/ofs/reqN__sc   ◀── our nowPlaying / onStateChange …
```

* No DIAL, no SSDP, no LAN listener, no Google login, no cookies. **[live]**
* Screen id is just an identifier; the server hands out a lounge token for *any*
  well-formed id **[live]**. Persist `screenId` + `deviceId` forever → the phone keeps the
  "Sofa" entry across Sofa restarts.
* Lounge token: lifespan 14 d, server-advised refresh 13 d **[live]**.
* TV code: 12 digits, valid **≈ 5 min (measured 300–307 s, not extended by use)** **[live]**,
  re-fetch every 5 min like yt-cast-receiver (better: every 4 min, see §3.1); every code stays
  valid until its own expiry, no "register" call.
* Minimal message set the phone needs: answer `remoteConnected` / `loungeStatus` with
  `onHasPreviousNextChanged + nowPlaying + onStateChange + onVolumeChanged +
  onAutoplayModeChanged(UNSUPPORTED)`; then `nowPlaying` + `onStateChange` on every
  player change, `onVolumeChanged` on `getVolume`/`setVolume`.
* `ctt` is not needed – Sofa resolves streams itself (yt-dlp, see `docs/youtube.md`).
* **Use libcurl (already linked by Sofa) or CFReadStream for the long-poll GET. NSURLSession
  on 10.9 buffers the stream and delivers nothing** **[live]**.

---

## 1. Identities and persistence

| item | how | format (live) | lifetime | persist? |
|---|---|---|---|---|
| `screenId` | `GET /api/lounge/pairing/generate_screen_id` | 26 chars `[a-z0-9]`, e.g. `5pvv1d…gj1` | unlimited (server accepts any id, see below) | **yes** |
| `deviceId` | generate locally, UUID v4 lowercase | `98f6df9a-7b27-4616-b9ab-e8322f593ff4` | ours | **yes** (yt-cast-receiver/plaincast persist it too) |
| `loungeToken` | `get_lounge_token_batch` | `AELpD4…` 119 chars, URL-safe base64 | 14 days | optional (cache with `expiration`) |
| pairing code | `get_pairing_code` | 12 digits | minutes (§3) | no |
| `SID`, `gsessionid` | `bc/bind` | 16 hex upper / 32 URL-safe | until idle (§4.6) | no |

### 1.1 generate_screen_id **[live]**

```
GET https://www.youtube.com/api/lounge/pairing/generate_screen_id
→ 200 text/plain
xxxxxxxxxxxxxxxxxxxxxxxxxx          (26 chars, no newline)
```

No parameters, no auth. Call **once**, store (`~/Library/Application Support/Sofa/lounge.json`
or NSUserDefaults). yt-cast-receiver stores `{screenId, deviceId}` per theme ("mdxContext");
plaincast stores `apps.youtube.screenId` + `apps.youtube.uuid` in its config.

Surprise: `get_lounge_token_batch` with a made-up id `aaaaaaaaaaaaaaaaaaaaaaaaaa` also
returns a valid-looking token **[live]**. So a screen id never "expires"; there is no
server-side failure mode to detect. yt-cast-receiver still has a fallback ("token fetch
with stored id failed → generate a new id and retry"); keep that as cheap insurance
(only for HTTP/JSON errors, never on a timer – a new id orphans the phone's pairing).

### 1.2 Same `deviceId` every time

The `deviceId` (`id=` on bind, `device_id=` on get_pairing_code) is what the phone sees
as the screen device (`mdxDiscoveryIds` in `get_screen`). Binding with a *different* id but
the same token joins the same lounge as a **second** LOUNGE_SCREEN **[live]** – avoid that.
A second bind with the *same* id does **not** kill an existing long-polled session
**[live]** (4 extra binds during the 10-min run left it untouched).

---

## 2. Lounge token

```
POST https://www.youtube.com/api/lounge/pairing/get_lounge_token_batch
Content-Type: application/x-www-form-urlencoded

screen_ids=<screenId>            (comma-separated list allowed – "batch")
```

Response **[live]** (token redacted):

```json
{"screens":[{"screenId":"xxxxxxxxxxxxxxxxxxxxxxxxxx",
  "refreshIntervalInMillis":1123200000, "refreshIntervalMs":1123200000,
  "remoteRefreshIntervalMs":79200000,  "remoteRefreshIntervalInMillis":79200000,
  "loungeTokenLifespanMs":1209600000,
  "loungeToken":"AELpD4vAm3…(119 chars)",
  "expiration":1794821494226}]}
```

* `loungeTokenLifespanMs` = 1 209 600 000 = **14 days**; `expiration` = now + 14 d (ms epoch).
* `refreshIntervalInMillis` = 1 123 200 000 = **13 days** → refresh after that.
  (`remoteRefreshInterval…` = 22 h is for senders.)
* Each call returns a **new** token; older tokens stay valid until their own expiry
  (two tokens fetched seconds apart both worked).
* Refresh procedure (yt-cast-receiver `#refreshLoungeToken`, plaincast on 410):
  fetch new token → **open a new bind session** with it (the token is part of every bind
  URL) → close the old long-poll. Pending outgoing messages get re-queued into the new
  session (their `ofs` restarts at 0).
* Also refresh on any bind answer `401` (`Invalid lounge id token: …` /
  `Lounge ID Token should not be empty.` **[live]**; pyytlounge also handles
  `401 … Expired`).

---

## 3. TV pairing code ("Mit TV-Code verbinden")

```
POST https://www.youtube.com/api/lounge/pairing/get_pairing_code?ctx=pair
Content-Type: application/x-www-form-urlencoded

access_type=permanent&app=sofa&lounge_token=<loungeToken>&screen_id=<screenId>
&screen_name=Sofa&device_id=<deviceId>
→ 200 text/plain
742475903594
```

**[live]** findings:

| variation | result |
|---|---|
| all six params (above) | 200, code; `get_screen` shows `name:"Sofa"` + `deviceId` + `mdxDiscoveryIds` |
| without `screen_name`, `device_id`, `app` | 200, code works, but `name:""` → phone shows nameless screen |
| without `?ctx=pair` | 200, works |
| GET with params in query | 200, works |
| bogus `lounge_token` | 200, code works (token isn't checked; screen_id is what matters) |

→ Send all six, as yt-cast-receiver does. `screen_name` is the name the phone shows
after pairing.

* Format: **12 decimal digits**. Display grouped `742 475 903 594` (as TVs do).
* Lifetime: **≈ 5 minutes** **[live, §3.1]**.
* Each call issues a *new* code; previous ones stay valid until they time out.
  A code can be resolved several times (the self-test resolved one twice) **[live]**.
* **Nothing else needs to be "registered" or kept alive.** The code is bound to the screen
  id at creation. `register_pairing_code` is the *DIAL* path (phone sends `pairingCode`
  in the DIAL launch POST, the screen registers it) – not needed for TV-code pairing.
* Refresh policy: yt-cast-receiver re-fetches every **5 min** (30 s retry when not ready)
  and only while its "pairing code service" is started. Do the same: fetch when the
  "Mit TV verbinden" screen is shown, refresh every 5 min, stop when hidden.
* Ordering: yt-cast-receiver fetches the code only after the bind session exists; the
  probe does the same. (Not tested whether a phone can pair while the screen is offline;
  it would see the screen but nothing could answer.)

### 3.1 Measured lifetime **[live]**

| code | issued (CET) | checks via `get_screen` | result |
|---|---|---|---|
| `686…227` | 10:37:27 | every 10 s | 200 until 10:42:24, **404 at 10:42:34 → dead after ≈ 300–307 s** |
| `788…084` | 10:31:47 | 10:35:00 → 200, 10:36:46 → 404 | dead after < 5 min |
| `742…594` | ≈ 10:33 | 10:38:47 → 200, 10:41:48 → 404 | ≈ 5 min |

Polling `get_screen` does **not** extend the lifetime. Because yt-cast-receiver refreshes
at exactly 5 min, its displayed code is invalid for a few seconds before the new one shows
up; Sofa should refresh every **4 min** (and immediately when the screen is opened) so the
shown code always has ≥ 1 min left.

### 3.2 What the phone does with the code (sender side, for reference) **[live]**

```
POST https://www.youtube.com/api/lounge/pairing/get_screen
pairing_code=742475903594
→ 200 {"screen":{"accessType":"permanent","screenId":"5pvv1d…","name":"Sofa",
        "loungeToken":"AELpD4…","loungeTokenRefreshIntervalMs":"1123200000",
        "expiration":"1794821657254","clientName":"unknown",
        "dialAdditionalDataSupportLevel":"unknown",
        "mdxDiscoveryIds":[{"type":"MDX_DISCOVERY_ID_TYPE_LOUNGE_DEVICE_ID","value":"<deviceId>"}],
        "deviceId":"<deviceId>"}}
unknown/expired code → 404
```

The phone then stores `screenId` and from then on only uses
`get_lounge_token_batch(screen_ids=…)` and `get_screen_availability(lounge_token=…)`
(`{"screens":[{"loungeToken":…,"status":"online"}]}` **[live]**, "online" while our bind
session is alive). That is why a **stable screen id = permanent pairing**.

---

## 4. The bind channel `/api/lounge/bc/bind`

It is Google's old **BrowserChannel** protocol (VER=8): one POST to create a session,
a hanging GET ("back channel") for server→screen messages, short POSTs ("forward channel")
for screen→server messages.

### 4.1 Common query parameters (sent on every bind request)

| param | value | needed? |
|---|---|---|
| `device` | `LOUNGE_SCREEN` | **required** |
| `id` | our persisted `deviceId` | **required** |
| `name` | screen name, e.g. `Sofa` (keep ASCII/Latin-1, see §8) | **required** |
| `loungeIdToken` | lounge token | **required** (401 otherwise) |
| `VER` | `8` | **required** |
| `app` | `sofa` (free text; yt-cast-receiver `ytcr`) | recommended (shown in loungeStatus) |
| `theme` | `cl` (YouTube) – `m` = YouTube Music | recommended (server defaults to `cl`) |
| `capabilities` | `dsp,mic,dpa,ntb` (server appends `que,mus`) | recommended |
| `mdxVersion` | `2` | recommended |
| `v` | `2` | recommended |
| `obfuscatedGaiaId` | empty | optional |
| `cst` | `m` | optional |
| `t` | `1` | optional |
| `zx` | 12 random `[a-z0-9]`, new per request (cache buster) | recommended |

"Required" = verified minimal set: `device,id,name,loungeIdToken,VER,RID` (+ `zx`)
created a working session **[live]** (that is plaincast's exact set); then `app` shows as `""`
and `capabilities` as `que,mus`. Use the full yt-cast-receiver set.

### 4.2 Session create (initial POST)

```
POST /api/lounge/bc/bind?<common>&RID=<rid>&CVER=1&deviceInfo=<json>&zx=…
Content-Type: application/x-www-form-urlencoded

count=0
```

* `RID`: random start value, yt-cast-receiver 41000–49999, plaincast 10000–89999; then
  **+1 for every POST** (initial and each send). Not used on the GET (`RID=rpc`).
* `CVER=1` only here.
* `deviceInfo` (only yt-cast-receiver sends it; shows up in `loungeStatus` and on the phone):
  `{"brand":"Apple","model":"iMac","year":0,"os":"Mac OS X","osVersion":"10.9.5","chipset":"",
  "clientName":"TVHTML5","dialAdditionalDataSupportLevel":"unsupported",
  "mdxDialServerType":"MDX_DIAL_SERVER_TYPE_UNKNOWN"}`. pyytlounge refuses screens whose
  `clientName` is `TVHTML5_FOR_KIDS` – irrelevant for the phone app.

Response **[live]** (one frame, see §4.4; ids redacted):

```
926
[[0,["c","503E3C…908","",8]]
,[1,["S","kcnE8L…iSk"]]
,[2,["loungeStatus",{"queueId":"RQwUFr…","devices":"[{\"app\":\"sofa\",\"capabilities\":\"dsp,mic,dpa,ntb,que,mus\",\"clientName\":\"unknown\",\"experiments\":\"\",\"name\":\"Sofa\",\"theme\":\"cl\",\"id\":\"98f6df9a-…\",\"type\":\"LOUNGE_SCREEN\",\"hasCc\":\"true\",\"deviceInfo\":\"{…}\",\"receiverIdentityMatchStatus\":\"IS_RECEIVER\"}]"}]]
,[3,["getNowPlaying"]]
,[4,["getDiscoveryDeviceId"]]
]
```

* `["c", SID, hostPrefix(""), negotiatedVersion(8)]` → store `SID`.
* `["S", gsessionid]` → store `gsessionid`.
* Then real messages. When a remote is already in the lounge, `loungeStatus` also has
  `cachedSessionState` and its `devices` list includes the `REMOTE_CONTROL` entries.
* Bind errors: `401 Invalid lounge id token` → refresh token (§2).

### 4.3 Back channel – long-poll GET

```
GET /api/lounge/bc/bind?<common>&RID=rpc&SID=<SID>&gsessionid=<gsessionid>
                       &CI=0&AID=<last array index seen>&TYPE=xmlhttp&zx=…
```

* `AID` = highest message index received so far (after the initial POST above: `4`).
  The server uses it as an ack and only sends newer entries.
* `CI=0` (0 = streaming allowed; 1 would ask for buffered/"chunked off" mode).
* Response `200`, `Transfer-Encoding: chunked`, `Content-Type: text/plain; charset=utf-8`.
  The first frame arrives immediately, usually `[[5,["noop"]]]`.
* Server sends `noop` every **≈ 25–30 s** **[live]** (measured 0.99, 29.69, 57.30, 86.95,
  115.63, 145.16, 171.05, 198.73, 225.38, 251.70, 277.22 s).
* Server **closes the GET cleanly after ≈ 265–303 s** (~4.5–5 min; observed 303.3 s and
  265.0 s, each time right after a noop) **[live]** → immediately open
  the next GET with the same SID/gsessionid and the current AID. That reconnect is normal
  operation, not an error (yt-cast-receiver/plaincast loop the same way).
* Use a read timeout of **≥ 60 s** (two noop periods). On timeout: abort, reconnect.

### 4.4 Framing **[live]**

```
<decimal length>\n<JSON array>\n
```

The length counts the JSON array text **including its trailing `\n`**
(e.g. `16\n[[5,["noop"]]\n]\n` – `[[5,["noop"]]\n]\n` is 16 chars). Inside the array,
entries are separated by `\n,`. One GET carries many frames back to back; one frame can
carry several entries. Body is ASCII only: non-ASCII is `\uXXXX`-escaped by the server,
so chars = bytes **[live]** (tested with `ä ö ü 📺`).

Each entry is `[index, [name, payload?]]`:

* `index` – the **array id**, strictly increasing per SID (0, 1, 2, …; noops consume
  indices too). This is what the GET's `AID` acks. Ignore entries with
  `index <= lastAID` (plaincast logs "old command" and drops them), log gaps.
* `name` – `c`, `S`, `noop`, or a lounge command.
* `payload` – a JSON **object whose values are all strings** (numbers and booleans
  arrive as `"0"`, `"true"`; nested structures as JSON-in-a-string, e.g.
  `devices`, `eventDetails`, `device`).

Parser recipe (ObjC): keep an `NSMutableData` buffer; loop: find `\n`, parse length `n`,
wait until `n` more bytes are buffered, `NSJSONSerialization` on those bytes, drop them.
Don't use yt-cast-receiver's regex parser (it's line-based and fragile).

### 4.5 Forward channel – sending messages (POST)

```
POST /api/lounge/bc/bind?<common>&deviceInfo=…&SID=<SID>&gsessionid=<gsessionid>
                        &RID=<rid++>&AID=<last index seen>&zx=…
Content-Type: application/x-www-form-urlencoded

count=2&ofs=7
&req0__sc=onStateChange&req0_state=1&req0_currentTime=42.000&req0_duration=212.000&…
&req1__sc=nowPlaying&req1_videoId=dQw4w9WgXcQ&…
```

* `count` – number of messages in this POST; `reqN__sc` (two underscores) = message
  name; `reqN_<key>` = payload fields, all strings.
* `ofs` – index of the first message in this POST, counting **all messages ever sent in this
  SID** (`ofs += count` after each POST; reset to 0 for a new SID).
* Response **[live]**: `8\n[1,16,0]` = `[backChannelPresent, lastArrayIdSentToUs,
  outstandingBackChannelBytes]` (BrowserChannel). `[0,-1,0]` means "no GET open right now".
  Nothing to act on; just check for HTTP 200.
* Messages go out in order (yt-cast-receiver serialises with a task queue, plaincast with a
  goroutine + 1 ms batching window). Do the same: one serial queue, batch whatever is
  pending into one POST.

`ofs` semantics **[live]** (screen sends, a REMOTE_CONTROL listens):

| sent ofs (expected) | HTTP | delivered? |
|---|---|---|
| 0 (0), 1 (1) | 200 | yes |
| 1 again (2) | 200 | **no – silently dropped as retransmit** |
| 5 (2) – gap | 200 | yes, and the window jumps to 6 |
| 2, 3, 4 afterwards | 200 | **no** (below window) |
| 6 | 200 | yes |

→ `ofs` must be exact and monotonic. A *retry* of a failed POST with the same `ofs`
is safe (dedup). Never "skip ahead".

`RID` semantics **[live]**: reusing/lowering RID was accepted; a far jump (99999 when at
~507) gave `401 RID_OUTSIDE_WINDOW` **and destroyed the session** (next request
`400 Unknown SID`). → strictly `rid++` per POST.

Terminate (optional, BrowserChannel): `POST …&TYPE=terminate` (pyytlounge sends it as a
remote with `clientDisconnectReason`). yt-cast-receiver instead sends a
`loungeScreenDisconnected` message before shutting down. On Sofa quit: send
`loungeScreenDisconnected` (best effort), then drop the connection.

### 4.6 Errors and reconnect rules

| situation | answer seen | action |
|---|---|---|
| GET closed after ~5 min / EOF | clean end of chunked body **[live]** | reconnect GET at once, same SID, current AID |
| network error / timeout | – | retry GET with backoff (plaincast: `retries² × 500 ms`, 25 tries ≈ 5 min; yt-cast-receiver: 3 immediate retries then refresh session) |
| `400 Unknown SID` (body `<TITLE>Unknown SID</TITLE>`) | session expired **[live]** | new session: initial POST (same token), reset `ofs=0`, `AID=-1`, new RID base. plaincast reconnects with `OSID=<old SID>&OAID=<old AID>` as an extra hint |
| `410 Gone` | wrong or missing gsessionid **[live]** | plaincast: refresh lounge token + new session |
| `401 …` (`Invalid lounge id token`, `RID_OUTSIDE_WINDOW`, `Expired`) | **[live]** | refresh token, new session |
| `404` | casttube treats it like 400 | new session |
| `502` | plaincast retries with backoff | retry |
| `noop` | every ~28 s | nothing to do except it acks (AID advances) |

Session idle expiry **[live]**: a session with no GET pending still accepted a GET after
5/15/25/35/45 s idle, but answered `400 Unknown SID` after 60 s, 180 s and 360 s.
→ **idle limit ≈ 45–60 s**. Re-open the GET promptly after each close (plaincast's
quadratic backoff can exceed that after a few failures – then just start a new session).

After a *new* session, re-send current `nowPlaying` + `onStateChange` (the phone stays in
the lounge; it just sees the new screen session).

---

## 5. Outgoing messages (screen → phone)

All values are strings. Times in seconds with decimals (`"42.000"`).

### 5.1 Player state codes

| code | meaning | used by |
|---|---|---|
| `-1` | idle / unstarted / nothing loaded | yt-cast-receiver `IDLE`, pyytlounge `Stopped` |
| `0` | ended / stopped | plaincast `STATE_STOPPED`, YouTube iframe API "ended" |
| `1` | playing | all |
| `2` | paused | all |
| `3` | buffering / loading (also while seeking) | all (plaincast maps seeking → 3) |
| `4` | yt-cast-receiver `STOPPED` (non-standard, sends `4` after stopVideo) | yt-cast-receiver only |
| `5` | video cued | pyytlounge (seen from real TVs) |
| `1081`/`1082` | ad playing / ad skipped | pyytlounge (real TVs); Sofa never |

Sofa: `-1` before first video / after stopVideo, `3` while AVPlayer item is loading or
seeking, `1`/`2` from `AVPlayer.rate`, `0` when the last item ended.

### 5.2 Message catalogue

| name | payload | when |
|---|---|---|
| `nowPlaying` | `videoId, currentTime, duration, state, currentIndex, listId, loadedTime, seekableStartTime("0"), seekableEndTime(=duration), cpn` – or `{}` when nothing loaded | on connect, on `getNowPlaying`, on video change, when going buffering→playing |
| `onStateChange` | `state, currentTime, duration, loadedTime, seekableStartTime, seekableEndTime, cpn` | every state change, after seek, periodically optional |
| `onVolumeChanged` | `volume` ("0"–"100"), `muted` ("true"/"false") | on connect, `getVolume`, `setVolume` (debounce 200 ms like yt-cast-receiver) |
| `onHasPreviousNextChanged` | `hasPrevious`, `hasNext` ("true"/"false") | on connect, after playlist changes |
| `onAutoplayModeChanged` | `autoplayMode`: `ENABLED`/`DISABLED`/`UNSUPPORTED` | on connect, `setAutoplayMode` |
| `autoplayUpNext` | `videoId` or `{}` | only with autoplay support |
| `onSubtitlesTrackChanged` | `videoId` (+ `languageCode`, `vss_id` when on: `.de` = manual, `a.de` = auto/ASR) | answer to `getSubtitlesTrack` / `setSubtitlesTrack`; Sofa also sends it on every subtitle change (menu, remembered language) and with a new video |
| `confirmPlaylistUpdate` | `updated: "true"` | plaincast answers `updatePlaylist` with it (old protocol, optional) |
| `nowPlayingPlaylist` | `videoIds, videoId, currentTime, duration, state, currentIndex` | plaincast answer to `getPlaylist` (old) |
| `loungeScreenDisconnected` | `{}` | before shutdown |

Notes:
* `cpn` = 16-char client playback nonce; yt-cast-receiver uses a random one per playback.
  Any 16 `[A-Za-z0-9_-]` works for the remote (**[live]** with a fixed value).
* `loadedTime`: yt-cast-receiver sends `duration` while playing/paused/loading, else 0.
* `listId`: echo the `listId` from `setPlaylist`. **[live]**: the server fills it in itself
  – even when we send `nowPlaying {}` the remote receives `{"listId":"RQwUFr…"}` (the lounge
  `queueId`). It also forwards `setPlaylist` with `listId` = that queue id even if the
  sender sent `listId=""`.
* `loungeStatus` and `playlistModified` / `onPlaylistModeChanged` seen by the remote are
  **generated by the server**, the screen does not send them **[live]**. The server also
  sends the remote a default `onAutoplayModeChanged UNSUPPORTED` on its own.

### 5.3 Minimal set for a working phone remote

1. On `remoteConnected` (and on `loungeStatus` when it lists a REMOTE_CONTROL you haven't
   greeted): `onHasPreviousNextChanged`, `nowPlaying`, `onStateChange`, `onVolumeChanged`,
   `onAutoplayModeChanged{UNSUPPORTED}` – one POST.
2. `getNowPlaying` → `nowPlaying`. `getVolume` → `onVolumeChanged`.
   `getSubtitlesTrack` → `onSubtitlesTrackChanged{videoId}` (plaincast: "Android doesn't
   care much", but answer anyway).
3. `setPlaylist` → `nowPlaying(state 3)` + `onStateChange(3)` + `onHasPreviousNextChanged`
   immediately, then `onStateChange(1)` + `nowPlaying(1)` when AVPlayer actually plays.
4. `play`/`pause`/`seekTo` → `onStateChange` with new state/time (seek: first `3`, then the
   old state).
5. `setVolume` → `onVolumeChanged`.

This is exactly what the self-test exercised; the remote side received every one of them
in < 0.4 s (§9).

---

## 6. Incoming commands (phone → screen)

Payload keys are strings. **[live]** = seen on the wire in the self-test (sender =
pyytlounge-style web remote, not the Android app).

| command | payload | Sofa action |
|---|---|---|
| `remoteConnected` **[live]** | `id, name, app, capabilities, theme, type=REMOTE_CONTROL, clientName, pairingType, experiments, device (JSON string), receiverIdentityMatchStatus`; phones also `user`, `userAvatarUri`, `obfuscatedGaiaId`, `ownerObfuscatedGaiaId` **[src]** | add remote, toast "📱 <name> verbunden", send §5.3 set |
| `remoteDisconnected` | same shape | remove remote; if none left → optionally stop player (yt-cast-receiver default) |
| `loungeStatus` **[live]** | `devices` (JSON string: array of `{id,name,type,app,theme,capabilities,deviceInfo,…}`), `queueId`, `cachedSessionState`, sometimes `connectionEventDetails` (JSON: `{deviceId, ui}`) | sync remote list. yt-cast-receiver uses `connectionEventDetails` to detect (dis)connect; `ui:"true"` = explicit disconnect |
| `getNowPlaying` **[live]** | – | `nowPlaying` |
| `getVolume` **[live]** | – | `onVolumeChanged` |
| `getSubtitlesTrack` **[live]** | – | `onSubtitlesTrackChanged{videoId}` |
| `getDiscoveryDeviceId` **[live]** | – | in every new session; no reference implementation answers it; ignoring it did not break the self-test. Unknown what the Android app expects (TODO with phone) |
| `getPartyGamesMode` **[live]** | – | sent after `remoteConnected`; unhandled by all references; ignore |
| `setPlaylist` **[live]** | `videoId, videoIds` (comma list), `currentIndex`, `currentTime`, `listId`, `eventDetails` (JSON `{"eventType":"PLAYLIST_SET","videoIds":[…]}`), `sourceDeviceType`; from phones also `ctt`, `params`, `audioOnly`, `prioritizeMobileSenderPlaybackStateOnConnection` **[src]** | build queue, play `videoIds[currentIndex]` from `currentTime`. `ctt` (credential transfer token) is **not needed** – yt-dlp resolves the stream |
| `updatePlaylist` | `videoIds, listId, eventDetails` (`VIDEO_ADDED/VIDEO_REMOVED/PLAYLIST_CLEARED…`), `currentIndex?` | replace queue keeping current video; if current vanished → stop |
| `play` **[live]** | – | resume |
| `pause` **[live]** | – | pause |
| `seekTo` **[live]** | `newTime` (seconds, may be fractional) | seek |
| `next` / `previous` | – | queue ±1 |
| `stopVideo` | – | stop, `nowPlaying {}` |
| `setVolume` | `volume` ("0"–"100") **or** `delta` (±n, plaincast), optionally `muted` | set app volume |
| `setAutoplayMode` | `autoplayMode` `ENABLED/DISABLED` | answer `onAutoplayModeChanged{UNSUPPORTED}` (no autoplay in Sofa v1) |
| `setVideo` | `videoId, currentTime` | plaincast (old protocol) – treat like single-item setPlaylist |
| `getPlaylist` | – | plaincast (old) → `nowPlayingPlaylist` |
| `dpadCommand` | `key`: `UP/DOWN/LEFT/RIGHT/ENTER/BACK` | optional: map to Sofa's own navigation |
| `setSubtitlesTrack` | `videoId, languageCode` ("" = off), `vss_id` (`.de` / `a.de`), `trackName` **[src: gotubecast]** | Sofa: picks the matching track (exact code > base language; `a.` prefers automatic), remembers it like the menu, toasts, answers `onSubtitlesTrackChanged` with the track actually chosen (unavailable → current state, toast "Keine Untertitel auf …") |
| `setPlaybackSpeed` | `playbackSpeed` | optional (then send `onPlaybackSpeedChanged`) |
| `skipAd` | – | ignore |
| `loungeScreenDisconnected` | – | (server→remote) |
| `noop`, `c`, `S` | – | protocol, see §4 |

Senders announce capabilities: `atp` = supports autoplay (yt-cast-receiver enables
autoplay only if all remotes have it), `que` = queue, `mus` = music, `dsdtr`, `vsp` =
playback speed. App `…-desktop` = supports mute.

---

## 7. State machine and sequence

### 7.1 States

```
          ┌───────────┐ no screenId           ┌────────────┐
 start ──▶│ NO_SCREEN │──generate_screen_id──▶│ HAVE_SCREEN│ (persist screenId+deviceId)
          └───────────┘                       └─────┬──────┘
                                                    │ get_lounge_token_batch
                                                    ▼
                                              ┌────────────┐ 401 / token age>13 d
                                     ┌───────▶│ HAVE_TOKEN │◀─────────────────────────┐
                                     │        └─────┬──────┘                          │
                                     │              │ POST bind count=0               │
                                     │              ▼                                 │
                                     │        ┌────────────┐                          │
                                     │        │ SESSION    │ SID, gsessionid,         │
                                     │        │ (idle)     │ ofs=0, AID=last          │
                                     │  400   └─────┬──────┘                          │
                                     │ Unknown      │ GET RID=rpc                     │
                                     │  SID         ▼                                 │
                                     │        ┌────────────┐  clean close / timeout   │
                                     └────────│ POLLING    │──────────┐               │
                                              │            │◀─────────┘ reconnect GET │
                                              └─────┬──────┘                          │
                                         410/401    └─────────────────────────────────┘

 Orthogonal: PAIR_UI_VISIBLE → get_pairing_code now + every 5 min (needs HAVE_TOKEN).
 Orthogonal: remotes = {} | {id…}; player = IDLE(-1) / BUFFERING(3) / PLAYING(1) /
             PAUSED(2) / ENDED(0).
```

### 7.2 Sequence: first start → code → phone pairs → setPlaylist → play/pause/seek

```
 Sofa (screen)                         www.youtube.com                     Phone (YouTube app)
 ─────────────                         ───────────────                     ───────────────────
 GET  pairing/generate_screen_id  ───▶
                                  ◀─── "5pvv1d…gj1"   (persist + own deviceId UUID)
 POST pairing/get_lounge_token_batch ─▶ screen_ids=…
                                  ◀─── {loungeToken, expiration(+14 d)}
 POST bc/bind RID=r CVER=1 count=0 ──▶
                                  ◀─── [0 c SID] [1 S gsid] [2 loungeStatus] [3 getNowPlaying] [4 getDiscoveryDeviceId]
 POST bc/bind RID=r+1 ofs=0 ───────────▶ nowPlaying {}
 GET  bc/bind RID=rpc AID=4 ─────────▶ (hangs, chunked)
                                  ◀─── [5 noop]
 POST pairing/get_pairing_code ──────▶
                                  ◀─── "742475903594"
 show "742 475 903 594"
                                                                 user types code
                                       ◀─── POST pairing/get_screen pairing_code=…
                                       ───▶ {screen: screenId, name "Sofa", loungeToken'}
                                       ◀─── POST bc/bind device=REMOTE_CONTROL … (phone session)
                                  ◀─── [6 loungeStatus{devices:[Sofa, Phone]}]
                                  ◀─── [7 remoteConnected{name:"Pixel", user:"…"}]
                                  ◀─── [8 getNowPlaying] [9 getSubtitlesTrack] [10 getVolume] [11 getPartyGamesMode]
 POST ofs=1 count=5 ─────────────────▶ onHasPreviousNextChanged, nowPlaying{}, onStateChange(-1),
                                       onVolumeChanged, onAutoplayModeChanged(UNSUPPORTED) ───▶ remote UI
 POST ofs=6 … answers to 8–10 ───────▶                                       ───▶
                                                                 user taps "cast" on a video
                                  ◀─── [12 setPlaylist{videoId, videoIds, currentIndex 0, currentTime 0, listId}]
 POST ofs=… nowPlaying(3)+onStateChange(3)+onHasPreviousNextChanged ───────▶ "loading…"
 (yt-dlp resolve 2.5–25 s, AVPlayer starts)
 POST onStateChange(1)+nowPlaying(1) ────────────────────────────────────────▶ shows ▶ + progress
                                  ◀─── [13 pause]
 POST onStateChange(2, t=3.3) ───────────────────────────────────────────────▶ ⏸
                                  ◀─── [14 seekTo{newTime:"42"}]
 POST onStateChange(2, t=42) ────────────────────────────────────────────────▶ bar at 0:42
                                  ◀─── [15 play]
 POST onStateChange(1, t=42) ────────────────────────────────────────────────▶ ▶
 … ~303 s: GET ends ◀─── (EOF)
 GET bc/bind RID=rpc AID=<last> ─────▶ (new hanging GET, same SID)
```

(The array indices are the real ones from the self-test log.)

---

## 8. Gotchas

1. **NSURLSession is unusable for the back channel on 10.9** **[live]**. With a delegate
   `NSURLSessionDataTask` the GET produced *no* `didReceiveResponse` and *no*
   `didReceiveData` in 64 s, while the same URL via **libcurl** (`CURLOPT_WRITEFUNCTION`)
   and **CFReadStreamCreateForHTTPRequest** delivered the 19-byte noop frame at +0.2 s
   and the next one at +25–30 s (`docs/probes/lounge_stream.m`, modes `nsurl`, `nsurl-badsid`, `cfstream`, `curl`).
   Control run (`nsurl-badsid`): the same NSURLSession code gets an immediate
   `400 Unknown SID` with body, so the delegate path works – only the streamed 200 body is
   held back. This is CFNetwork's ~512-byte content-sniffing buffer – frames are 19–2000 bytes, so
   commands would arrive late or never. Sofa already links `-lcurl` → run the GET with
   libcurl on a dedicated thread (or CFReadStream on a run loop); short POSTs may use
   NSURLSession or curl.
2. **`ofs` must be exact** – duplicates and anything below the window are dropped with
   HTTP 200, a jump ahead silently loses everything in between (§4.5 table). Reset to 0
   per SID. Retrying the same POST with the same `ofs` is safe.
3. **RID**: random base, +1 per POST (initial + sends), `rpc` on the GET. A big jump →
   `401 RID_OUTSIDE_WINDOW` and the session dies.
4. **AID**: the highest incoming array index; send it on GET *and* POST. Noops consume
   indices. Drop entries `<= AID`. After a new session the indices restart at 0
   (yt-cast-receiver nulls AIDs of queued messages after a refresh).
5. **zx**: 12 random lowercase alnum chars per request; pure cache-buster.
6. **Keepalive timings**: noop ≈ every 25–30 s, GET force-closed after ≈ 265–303 s, session
   dies after ≈ 45–60 s without a pending GET. Read timeout 60–90 s; reconnect immediately.
7. **theme**: `cl` = YouTube ("classic"), `m` = YouTube Music. The phone's YouTube app only
   talks to `cl` screens; the YT Music app to `m` screens. yt-cast-receiver runs **two**
   sessions (one per theme, separate screen ids) and rejects senders whose theme isn't
   `cl`/`m` [src]. `up` is not used by any reference implementation; it is (as far as
   known) YouTube TV/"unplugged" – Sofa needs only `cl`. Server defaults to `cl` when
   omitted **[live]**.
8. **Session expiry handling in the references**: yt-cast-receiver – on GET failure 3
   retries, then `#refreshLoungeToken()` = full restart (new token, new bind, close old
   GET); token refresh timer at `refreshIntervalInMillis` (13 d); send errors → one
   refresh+retry, then end session. plaincast – `400 Unknown SID` → new bind with
   `OSID/OAID`; `410 Gone` → reload token + new bind; network errors → quadratic backoff
   up to 25 tries; 502 → retry.
9. **Stale remotes**: a remote that vanished without disconnecting stays in
   `loungeStatus.devices` for minutes **[live]** (the self-test remote was still listed in
   the next run). Don't treat "a REMOTE_CONTROL in loungeStatus" as "phone is here";
   use `remoteConnected` / `connectionEventDetails`.
10. **Greet each remote once** – a connect produces both a `loungeStatus` (listing the new
    remote) and a `remoteConnected`; the first probe version answered both, so the remote
    got the greeting twice (harmless noise, visible in §9.1). The probe now keeps a
    `greeted` set.
11. **Name encoding**: `name="Sofa – Wohnzimmer äöü"`: `äöü` survived, the en dash came
    back double-escaped (`\\u2013`) **[live]**. Keep the screen name simple.
12. **Cookies**: bind responses set `S=youtube_lounge_remote=…`; none of the references
    send cookies back and it works without **[live]**.
13. **DIAL / SSDP is not needed** for TV-code pairing **[live]**: the whole self-test ran
    without any LAN listener; the phone finds the screen through the cloud
    (`get_screen`, `get_screen_availability`, "magnaKey cloudPairedDevice"). DIAL only adds
    "the TV appears automatically when phone and TV share a Wi-Fi" + `register_pairing_code`.
    Optional later.
14. One HTTP connection per request is fine (Python probe opens a fresh TLS connection
    each time; POST round-trip 150–350 ms from here).

---

## 9. Live record (2026-11-03, redacted)

### 9.1 Self-test round trip (`lounge_probe.py --self-test`)

```
   0.62 recv   [0] c SID=503E3C...908(len 16) extra=['', 8]
   0.62 recv   [1] S gsessionid=kcnE8L...iSk(len 32)
   0.62 recv   [2] loungeStatus {"queueId": "RQwUFr…", "devices": "[{…LOUNGE_SCREEN…}]"}
   0.62 recv   [3] getNowPlaying {}
   0.62 recv   [4] getDiscoveryDeviceId {}
   0.86 pair   get_pairing_code -> 200 OK body='123456789012'
   1.05 poll   GET open (AID=4) chunked=chunked
   1.05 recv   [5] noop
   1.10 rmt    get_screen(code) -> 200 screen={"accessType":"permanent","screenId":"5pvv1d…","name":"Sofa",…}
   1.50 recv   [6] loungeStatus {"cachedSessionState": "Ei8K…", "queueId": "RQwUFr…", "devices": "[…LOUNGE_SCREEN…,…REMOTE_CONTROL…]"}
   1.50 recv   [7] remoteConnected {"app": "web", "pairingType": "unknown", "capabilities": "que,dsdtr,atp,vsp,mus", "name": "Sofa probe remote", "theme": "cl", "id": "e936bf3e-…", "type": "REMOTE_CONTROL", "device": "{…}", "receiverIdentityMatchStatus": "MATCHES_RECEIVER"}
   1.50 recv   [8] getNowPlaying {}   [9] getSubtitlesTrack {}   [10] getVolume {}   [11] getPartyGamesMode {}
   1.67 send   ofs=1 onHasPreviousNextChanged + nowPlaying{} + onStateChange(-1) + onVolumeChanged + onAutoplayModeChanged -> 200 OK '[1,11,2027]'
   1.70 rmt    <- [7] nowPlaying [{"listId": "RQwUFr…"}]          (server added listId)
   4.93 recv   [12] setPlaylist {"listId": "RQwUFr…", "currentTime": "0", "eventDetails": "{\"eventType\":\"PLAYLIST_SET\",\"videoIds\":[\"dQw4w9WgXcQ\"]}", "sourceDeviceType": "REMOTE_CONTROL", "videoId": "dQw4w9WgXcQ", "videoIds": "dQw4w9WgXcQ", "currentIndex": "0"}
   5.25 send   ofs=14 nowPlaying(3) + onStateChange(3) + onHasPreviousNextChanged -> 200 OK '[1,12,0]'
   5.25 rmt    <- [21] nowPlaying [{"videoId": "dQw4w9WgXcQ", "state": "3", "currentIndex": "0", …}]
   6.06 send   ofs=17 onStateChange(1) + nowPlaying(1)
   9.09 recv   [13] pause {}
   9.24 rmt    <- [27] onStateChange [{"currentTime": "3.338", "state": "2", …}]
  12.29 recv   [14] seekTo {"newTime": "42"}
  12.47 rmt    <- [28] onStateChange [{"currentTime": "42.000", "state": "2", …}]
  15.48 recv   [15] play {}
  15.65 rmt    <- [29] onStateChange [{"currentTime": "42.000", "state": "1", …}]
  18.64 recv   [16] getNowPlaying {}
  18.96 rmt    <- [30] nowPlaying [{"currentTime": "45.160", "videoId": "dQw4w9WgXcQ", "state": "1", …}]
```

Command → receiver latency ≈ 10 ms after the sender's POST; screen → remote ≈ 150–350 ms.

### 9.2 Keepalive run (10 min, `--duration 600 --raw`)

```
   0.60 bind   initial POST -> 200 OK (1409 bytes)
   0.83 pair   get_pairing_code -> 200 OK body='123456789012'
   0.99 poll   GET open (AID=4) chunked=chunked
   0.99 raw    16 b'[[5,["noop"]]\n]\n'
  29.69 raw    16 b'[[6,["noop"]]\n]\n'
  57.30 raw    16 b'[[7,["noop"]]\n]\n'
  …     noops at 86.95 115.63 145.16 171.05 198.73 225.38 251.70 277.22 304.16
 301.07 pair   NEW CODE: 718 490 820 639                     (5-min refresh)
 304.16 poll   GET closed by server after 303.3s -> reconnect
 304.33 poll   GET open (AID=16) chunked=chunked            (same SID, noop right away)
  …     noops at 330.30 354.94 383.39 411.14 435.06 462.11 487.80 515.27 540.74 569.21
 569.21 poll   GET closed by server after 265.0s -> reconnect
 569.38 poll   GET open (AID=27) chunked=chunked
 594.93 recv   [29] noop
 601.29 pair   NEW CODE: 350 139 248 920
 601.53 done   rid=54883 ofs=6 last AID=29
```

No errors, no `Unknown SID`, one SID for the whole 10 minutes (while 4 other binds with
the same deviceId and several throwaway screens ran in parallel).

### 9.3 Error answers (all `text/html` GSE error pages, title = reason)

```
bind, bogus loungeIdToken           → 401 Invalid lounge id token: AELbogus
bind, no loungeIdToken              → 401 Lounge ID Token should not be empty.
GET/POST, SID ok-looking + bad gsessionid → 410 Gone
GET/POST, missing gsessionid        → 410 Gone
GET, unknown SID + valid gsessionid → 400 Unknown SID
GET, expired SID (> 60 s idle)      → 400 Unknown SID
POST, RID jumped by ~99 000         → 401 RID_OUTSIDE_WINDOW   (session dead afterwards)
POST TYPE=terminate (dead session)  → 400 Unknown SID
get_screen, unknown/expired code    → 404
```

---

## 10. Implementation checklist (ObjC, Sofa)

* `SofaLounge` object on its own serial dispatch queue; persisted `{screenId, deviceId,
  loungeToken, expiration}` in Application Support.
* Long-poll on a dedicated `NSThread` with libcurl (`CURLOPT_WRITEFUNCTION` → framer →
  `NSJSONSerialization` → dispatch to the lounge queue), `CURLOPT_LOW_SPEED_TIME 90`.
* Sender queue: coalesce pending messages, one POST in flight, `ofs`/`RID` advanced only
  inside the queue; retry a failed POST with the *same* body (same `ofs`, new `RID`).
* Player bridge: map Sofa's AVPlayer events to `onStateChange`/`nowPlaying`; resolve
  `setPlaylist.videoId` with the existing yt-dlp resolver (`docs/youtube.md`) and send state
  `3` immediately so the phone shows "loading" during the 2.5–25 s resolve.
* UI: "Mit TV verbinden" screen shows the code grouped 3-3-3-3, refreshes every 5 min;
  toast on `remoteConnected`.
* Run the Python probe against a real phone once (`python3 -I docs/probes/lounge_probe.py`)
  before writing ObjC, to confirm the Android-specific bits (`getDiscoveryDeviceId`, `ctt`,
  `user` fields).
