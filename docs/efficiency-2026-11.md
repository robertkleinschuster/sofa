# Efficiency work, November 2026 (Builds 23–27)

Findings and decisions of the efficiency review of 2026-11-17. Decision log entries: NOTES.md,
2026-11-17.

Host: iMac12,2, 10.9.5, 16 GB, one WD20EFAX (SMR, 5400 rpm) - small random writes and fsyncs are
the expensive thing; `noatime` on `/` since 2026-11-17.

## 1. Disk load (Build 23)

| Cause (measured, 120 s playback) | Before | After |
|---|---|---|
| Firefox HTTP disk cache (`cache2`, 986 of 1016 MB SABR answers - POSTs never served again; the index rebuilt after every hard restart: 2533 reads/min) | 54 I/Os, 24.9 MB | 0 (memory cache 64 MB) |
| Sofa.log (94 % `[debug]` from the diagnosis switch `ytEngineDebug`) | 6.6 MB/day | ~0.4 MB/day; rotation also while running |
| Picture cache `~/Library/Caches/Sofa/img` (no limit) | 332 MB | 150 MB cap, least recently used first |

Sofa itself was already sparse: SQLite in WAL + `synchronous=NORMAL`, no fsyncs in the window,
progress every 15 s; the media store writes large sequential blocks (wanted). Not done on purpose:
`synchronous=OFF` (crash safety after the hard restarts), fetch `cache: 'no-store'` (adds request
headers), turning off Alt-Svc/HTTP/3 (fingerprint).

## 2. Slim engine (Build 24)

Browser-side services off (`SFYTEnginePrefs.m`, each pref with its reason): new-tab page and feeds,
history, thumbnails, Safe Browsing, telemetry/studies, update checks, captive portal, suggestions,
translations/ML, profile backup; session store hourly. Hard limit: nothing a page can see or that
changes requests (prefetch/preconnect, favicons, push, GMP, remote settings, the spare process stay).
Measured: Firefox 10 -> 8 processes, ~1400 -> ~1130 MB five minutes after start, CPU unchanged.
Idle restart at 2.2 GB without a session (hard limit 3 GB). "Energie -> Ruhezustand" removed: after
standby the disk/SATA link did not come back (host diagnosis 2026-11-17, Nachtrag 4).

## 3. Rest mode and the fan daemon (Builds 25/26)

- **Rest** (`SFRest`) = the screen is off and nothing plays ("Ausschalten" and the sleep timer end
  playback, macOS display sleep counts too; never system sleep). Resting: no stall pings (20/s) or
  pointer watchdog, no prebuffer/focus preload, follows in batches (~2 h by day, 4-6 h by night),
  the engine's processes at `PRIO_DARWIN_BG` (`SFYTPriority`: one serial queue applies the wanted
  state, also to a new or taken-over browser; only what Sofa throttled goes back). Measured wake:
  66 ms to normal engine priority, first frame 0.2 s.
- **"Nachts ganz ruhen"** (Energie, default off): engine and phone connection end at night; a second
  stop at most once a night (each start is a new page and BotGuard attestation).
- **sofa-fand interface v1** (`SFFanLink`, datagrams only - the daemon does no disk I/O in its loop):
  hints `{"v":1,"ctx":"playback"|"idle"|"ruhe","vol":..,"ttl":90,"pid":..}` to
  `/var/run/sofa-fand/hint.sock` every context change and every 30 s, from Sofa's own socket
  `~/Library/Caches/Sofa/fand.sock` (0600); the daemon answers each hint and pushes level changes:
  `{"v":1,"level":0..3,"mode":..,"cpu_c":..,"gpu_c":..,"hdd_c":..,"psu_c":..,"amb_c":..,"fans":[..]}`.
  No answer for 120 s = level 0; a broken datagram keeps the last level; the socket is bound again
  when its path vanishes.
- **Thermal levels**: warm = background work waits (prebuffer, preloads, follows/Home refreshes,
  decorative animations); hot = also no new download, idle restart at 1.8 GB (never a restart during
  playback); critical = new videos at most 720p. VP9 in software stays (user: spare the GPU).
- **Independent review** of Build 25: 1 high (priority race: the engine could stay throttled), 6
  medium (taken-over browser not set, state file on the main thread, future timestamps, restart
  mid-video when hot, rest during playback, blocking night stop), 4 low - all fixed in Build 26 and
  checked again; leftovers R1-R5 in Build 27 (R1, a ≤1.5 s phone goodbye at night, kept on purpose).

## 4. Engine at rest: CPU

Build 26 at rest (BG priority): engine ≈1.5 % of one core (YouTube tab 1.1 %, main 0.3 %, GPU,
socket, RDD, utility, Xvfb ~0), Sofa 0.01 %. Awake idle ≈4 %; during playback Sofa ~16-18 % (VP9
1080p decoding), Firefox ~5 %. Freezing the engine (SIGSTOP) would save the last ~1.5 % at a
session/bot-check risk and needs Sofa's own page watchdog changed - not done (recommendation: only
behind a switch and after a night-long test).

## 5. Writes while idle and resting (Build 27)

Inventory with `fs_usage` (180 s each, Build 26): idle - Sofa one burst per 30 min (response cache
after the Home refresh), Firefox prefs, settings, startup cache, cookie WAL (playback: also
AlternateServices.bin 12.5/min); resting - Sofa nothing, Firefox the YouTube page's IndexedDB with
fsync (~8 disk I/Os/min) and cookies. The loudest periodic writers were not Sofa: systemstatsd (up
to 19/min), a `netwatchdog.state` script, ASL/system logs, Tailscale's log, audit, utmpx (ssh
logins), fan tuning logs.

Build 27:
- **Engine profile on a 512 MB RAM disk** (`SFYTRamProfile`: `hdiutil ram://`, HFS, no
  Spotlight/fseventsd). The disk profile stays the lasting copy: changed files go back every 30 min
  awake, at most every 2 h resting, and when the browser ends - SQLite through the backup API
  (`storage.sqlite.exclusiveLock.enabled=false`, browser-side only), other files renamed into place,
  stale WALs removed first, caches never. A reboot refills the RAM disk. Review of Build 27 (0 high,
  4 medium) fixed before the deploy: copies are durable before they replace anything (fsync every
  file, one F_FULLFSYNC, then rename, then F_FULLFSYNC again) - a hard reset leaves each file old or
  new, never torn (the set may mix generations); only what the RAM profile had (a manifest) is ever
  deleted, nothing when anything could not be read, an unreadable entry fails the fill; a disk
  profile changed behind Sofa's back (a rollback ran a browser on it) is never overwritten - the
  RAM disk is filled anew; free space watched (<64 MB said with the consumers, <16 MB the next start
  runs on the disk profile, the console log truncated after each copy); quitting waits at most
  12 s; attach timeouts (20/30 s) detach an orphaned RAM disk. After a rollback the "SofaEngine"
  RAM disk stays mounted until a reboot or `hdiutil detach`.
- TMPDIR of browser and display on it - not `/var/folders`, where dirhelper removes files "unused"
  for 3 days by access time, which `noatime` no longer keeps. Nothing long-lived of Sofa there.
- Sofa.log waits in memory (30 s awake, 10 min resting; failures, 64 KB, exit, crash and SIGTERM
  write at once; a change of the delay - going to rest, waking - writes what waits).
- Sofa's own SQLite at rest: `sofa.db` only with follow batches (≤ every 2 h), `cache.db` with their
  answers and the daily trim; to be confirmed by a 10-min `fs_usage` at rest after the deploy.
- The picture cache counts uses itself (`SFImageDiskLRU`); no other atime use in Sofa.

System-wide suggestions (not done): systemstatsd off, the netwatchdog script rarer or in RAM, fewer
ssh logins, buffered tuning logs.

## 6. Night measurement (Build 27, 2026-11-17/18)

`fs_usage` from 23:01 to 09:35 (output over ssh, no disk I/O on the iMac). First 10 min at rest:
1008 HDD writes, 762 of them Spotlight re-indexing after the reboot; Sofa and engine 5 (≈0.5/min,
Build 26: ≈8/min). At rest 00:00-07:00 the HDD took ≈1390 writes/h - launchd (system logs, Tailscale
log, journal) ≈824, Spotlight ≈225, kernel ≈147, identityservice ≈103 - and Sofa/engine ≈97/h (≈7 %):
sofa.db WAL 14/h (follow batches), Sofa.log 9/h, the RAM->disk sync every 2.5 h, picture cache ≈4/h.
The RAM disk itself took ≈570 writes/h. The Cache API store failed every sync (locked) - left in RAM
from Build 28.

