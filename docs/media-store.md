# Media store: buffer and download are one thing

Status: agreed with the user 2026-11-08; phases 1-5 built - every download is the store's (YouTube, the
mediatheks' progressive files, ORF's HLS); tiles, "noch X MB" and the exact timeline shade show it.

## Revision in progress: bounded predictive startup buffers (2026-11-09)

The user superseded the automatic whole-item fills described below. Only a manual download fills
all tracks and keeps them permanently. Automatic work selects likely next items using usage and
suggestions and prepares only a bounded window at the resume position (zero for a new video).
User clarification 2026-11-09: playback, predictive pre-buffering and manual downloads MUST share
one persistent buffer. A download is only that same buffer completely filled and pinned against
automatic eviction. No separate download file, storage root or persistent prefetch cache; filling
reuses every already stored range. The temporary demux reader must only read through the existing
store-backed proxies so its fetched bytes become part of that same buffer.

The channel/show auto-download option goes away. Playback takes priority and buffers a moving
window ahead; automatic work uses the same store, stays evictable, and has explicit candidate,
concurrency, transfer, memory and time limits. Pick measured budgets and verify startup latency.

Current verified state (2026-11-09 13:56): **Sofa 0.3.11 Build 20, Firefox rev5**.
- Complete no-MacPorts bundle check passed (fonts/WebGL included). Browser runtime SHA256
  8da8a18d6cc2d7ebc762bc55c65bf377b4d10cc4e912babfe7add13fd1eb7486 is identical to the successful
  three-profile IPC/audio memory gate. New production browser PID 86954 started 12:15:49;
  engine ready 12:15:56, all prior Build-18 runtime processes normally stopped before the swap.
- Real private YouTube playback passed: 144 s from the beginning, then 84 s after a resume at
  725 s, forward cache ~30 s, both tracks remain partial. Native RSS settled around 150 MiB;
  combined browser/app RSS settled around 1.3–1.4 GiB, global swap slightly decreased. This is
  a pre-reboot stress observation; the clean-baseline measurement is recorded below.
- A real uncached prediction at 1000 s exposed a five-second HTTP timeout shorter than token
  setup plus first SABR segment. It caused retries of the cached file prefix and exhausted the
  response budget before useful target bytes arrived. Local regression with first track bytes
  delayed six seconds fails before the fix (0 predictive bytes), passes afterwards including
  partial store, manual missing-only fill and offline reopen. Transport timeout now matches
  playback at 20 s; the 30 s total / 16 MiB response / 32 MiB generic-source limits stay intact.
  Budget exhaustion has its own `byte limit` outcome instead of reporting a filled window.
- Actual new-position prediction then passed: 12 s at position 1000, ~4.94 MiB added to the same
  partial store, 9,736,142 response-budget bytes remaining. First frame from that buffer: 0.7 s,
  versus 5.7 s for the earlier uncached resume. This is one measured comparison, not a guaranteed
  latency for all sources. Cancellation against a stalled source still takes 0.617 s.
- Native binary and Firefox hashes match the tested candidate after deployment. Both DBs pass
  quick_check; all download/subscription/progress rows match pre-deploy hashes, 291 download rows,
  267 progress, 135 follows, 83 tracks. .prev is Build 18. Snapshot:
  ~/Library/Logs/sofa-memguard/browser20-backup-20261109-121510.
- Evidence: browser20-release-test-20261109.log; browser19-memory-test-20261109.json;
  browser19-live-20261109-120035/{report.json,prefetch-report-20-timeout.json};
  youtube-prebuffer-slow-{before,after}-fix-20261109.log; reader-timeout-cancellation-20261109.log.
  All under ~/Library/Logs/sofa-memguard. Private test profiles never change real viewing state.
- Final clean-host acceptance: explicit reboot approval received 13:26; reboot completed
  13:30:28. Sofa automatically returned as Build 20, production PID 313 / Firefox 349, same
  tested runtime. Both DBs pass quick_check after reboot, full download/progress/subscription
  rows match their pre-reboot snapshots, counts remain 291 / 267 / 0; 135 follows, 83 tracks.
- Pre-reboot global swap 42706.75 MiB and compressor RAM 8210.20 MiB -> both zero. Kernel
  MAC.Labels 139609 -> 3190 and compressor_pager 149258 -> 0 after actual media work.
  The one-shot logger completed 41 samples over 20.1 min: swap and occupied compressor pages
  zero in EVERY sample. Production native RSS 126.08–133.93 MiB; full production tree after
  warmup 1221.56–1347.31 MiB, final 1288.11 MiB. Separate private test processes are excluded
  from production metrics by ancestry; unfiltered measurements remain in postboot.jsonl.
- Postboot actual prediction at a previously uncached 1200 s: 10.933 s buffered, 11,775,653
  response-budget bytes remaining, both tracks still partial. First frame 0.5 s, plays from
  1203.05 s, no actual user-history changes; global swap/compressor still zero afterwards.
  The targeted final scheduler suite passes. The logger removed its plist and its completed
  launchd job has been removed; no permanent new autostart setting remains. Buildcache persisted
  across reboot (1,473,332 KiB); no manual blanket cleanup or cache deletion.
- Completion evidence: ~/Library/Logs/sofa-memguard/reboot-20261109-132747/
  {completion-evidence.json,postboot.jsonl,finished.json,postboot-validation.json,
  postboot-after-media-kernel.json}; actual test report in
  browser19-live-20261109-120035/prefetch-report-20-postboot.json. The accepted observation
  scope is these workloads and durations; all requested implementation, deployment and
  diagnostic/cleanup steps are complete.

Implementation checkpoint:
- Channel buttons/context actions and download empty-state text no longer offer auto-downloads.
- Startup retires old automatic queued/running/retrying/done records into ordinary cache before
  recovery and integrity checks; explicit kept/manual records survive. Subscription records are
  removed in the same transaction; no media bytes are deleted. (Since schema step 19 this is a
  migration step, and the subscription columns, table and code are gone.) Full-fill enqueue rejects automatic
  callers; follow notifications no longer start fills. Record migration tests pass. The app binary
  builds with clang-22 and its Mach-O minimum deployment target is 10.9. Deployed as Build 15;
  Build 16 additionally removes the redundant "geladen" tile badge.
- Candidate policy implemented in SFPrebufferPlan: focus, resume history, channel affinity and
  already loaded suggestion order; at most three candidates, no discovery requests, deduplicated,
  excluding watched/live/DRM/local content except a focused replay. Eight focused checks pass.
- SFPrebufferReader is a headless paused libmpv worker (null audio/video); bounded forward cache,
  no backward cache, cancellable polling and wall-time limit. Its first local MP4 probe stops at
  the cache threshold at the actual resume position (70 s tested, with cancellation-before-start).
  Reproducible local-only probe: tests/units/prebufferreader.m (tools/test-units). Integration with the common store,
  transfer caps and mid-read cancellation now pass the tests recorded below. The current
  stream-bytes-read property returns zero for the local MP4 probe; SFHTTPBudget therefore enforces
  the shared response-body limit in the loopback server rather than relying on that property.
- POSIX-shm name audit for current Firefox parent/content pids found zero lingering named objects
  among counters 0..19999 (O_RDONLY only). This rules out those named-object leaks, not every
  possible shared-memory/kernel retention problem. libproc PROC_PIDFDPSHMINFO also totals open
  unlinked objects at only a few MiB for the current parent and long-lived children, so those
  open POSIX objects cannot explain the ~39 GiB swap usage either.
- SFPrebuffer now wires the policy to focused browse screens and reads through the existing
  store-backed YouTube/media-proxy URLs. One worker; cancellation on leaving its screen, real
  playback and display sleep; manual fills have priority. Initial request budget: 12 starts/hour,
  >=20 s apart, 10 min/item cooldown. YouTube prepares isolated sessions (no view reports) so
  cleanup cannot close or reuse the viewer's session. Native build passes.
- SFHTTPBudget caps response bodies across all audio/video/HLS connections of a speculative reader
  at 16 MiB via a private request header; exhausted/revoked budgets reject new requests before
  dispatch. HTTP tests prove streamed cut-off, no retry bypass, revocation and ordinary unbounded
  playback; existing WebSocket and local-reader regressions pass. Upstream retention is separately bounded
  by the 32 MiB source budget described below.
- Local end-to-end MP4/HLS download suite (part c) passes: stored ranges reused, completed
  downloads play offline without their origin, exact timeline shading. New 200-reader lifecycle
  regression passes and preserves an active neighbor session. Found/fixed a concrete retention
  bug: SFMediaProxy never removed sessions (including parsed MP4 chunk indexes and HLS metadata).
  Playback teardown and speculative-reader completion now release their owned proxy URL; shared
  persistent tracks are untouched. This has NOT been proven to explain the historic 39 GiB swap.
- Browser predictive SABR sessions now have their own limits (12 s ahead, 15 MiB total per-track
  eviction caps), independent of playback defaults; TypeScript plus 25 offline session tests pass.
- Updated end-to-end migration suite (part b, unique instance prebuffer-migration-b2-20261109)
  passes: queued/running/retry/done automatic entries retired before recovery; subscriptions
  removed; actual manual download and its persistent bytes preserved; no automatic restart;
  manual Herunterladen refills the same store. Parts b/c both exit 0; logs for this checkpoint:
  /private/tmp/sofa-prebuffer-migration-b2.log and /private/tmp/sofa-proxy-lifetime-c.log.
- Actual speculative coordinator/MP4 reader integration now verified (part c, instance
  speculative-store-c3-20261109): saved resume 30 s, partial common buffer 786432/1344741 bytes,
  no download row, then manual fill reuses these bytes. No separate persistent prefetch cache.
- Added separate upstream budget (32 MiB per speculative token) to progressive source chunks,
  HLS playlists/resources/range fetches before retaining/storing bytes. Cached responses use only
  the response budget (16 MiB). Curl's transport/socket buffering can overshoot reception by a
  callback chunk; over-budget chunks are rejected before retention. YouTube SABR has its own
  predictive session caps (above). Generic full fetch preserves redirect URLs and checks idle
  progress for cancellation. Nine curl-budget checks pass including oversized local response,
  exact-limit exhaustion, cancelled retry, stalled-origin cancellation and ordinary fetches.
- Full part-c rerun after source budgets passes (/private/tmp/sofa-speculative-byte-c.log): exact
  524288 cached bytes are reused by manual fill. Logging/assertions use exact byte counts rather
  than rounded MiB. Actual speculative HLS run also passes (/private/tmp/sofa-speculative-hls-c.log):
  686624 bytes of encrypted HLS resources in the common store, no download row, subsequent
  playback/manual fill/offline playback still work. Nine curl-budget checks pass; the headless
  reader cancels a media open stalled before body bytes in 0.716 s (prebufferreader unit).
- Read-only 2-second RAM sampler completed successfully (exec session 17545, top -l 600 -s 2), covering the next
  regular full fill around 07:24. Output: ~/Library/Logs/sofa-memguard/detailed-20261109-0717.log.
  Terminal exit 0 verified; do not restart it unless a new observation need is identified.
- Dense sampler captured the 07:24:18-07:24:34 regular 9 MiB YouTube full fill (DzbVuasuyhQ):
  kernel_task ~5528 MiB stable, Sofa ~142 MiB resident + 87 MiB compressed stable; Firefox content
  briefly grows by tens of MiB. Swap around 39.3 GiB does not jump. This short fill does not
  reproduce the historic large-fill incident; it does not exclude size/lifetime-dependent leaks.
- Controlled idle restart audit completed 07:27:45 (restart-audit-20261109-072745.json under
  ~/Library/Logs/sofa-memguard). Normal application quit stopped Sofa PID 16579, its Firefox tree
  and Xvfb; only the remote helper remained. Swap 39294.50 -> 39258.00 MiB. Compressor logical
  pages 12621546 -> 12506308: the overwhelming retained population survived, so normal live
  Sofa/browser heap ownership does not explain it. This is not proof of a particular kernel bug
  or original trigger. Same installed version restarted successfully (Sofa 41671, Firefox 41711)
  and engine ready observed. No running playback/download/build/pipeline was interrupted.
- New local YouTube integration passes (tests/units/ytprebuffer.m in tools/test-units; first log
  ~/Library/Logs/sofa-memguard/youtube-prebuffer-20261109.log). Uses the real SFYTEngine Media,
  Store and Fill categories, media store and libmpv with separated real MP4 audio/video fixtures;
  only browser RPC is replaced. Resume at 70 s prepares partial common store; full fill fetches
  exactly missing bytes; stored-session demux works with browser source removed, no RPC; store
  reopen preserves one complete copy. This does not test the actual Firefox-extension channel.
- Stream origin cancellation implemented using SFCurlStreamWhile liveness checks during idle
  progress; curl-budget regression now has 10 checks including streaming source stalled before
  any chunks. All 28 native unit suites pass using clang-22/10.9 (units-clang22-20261109.log);
  tools/check-arch passes; native all-target build passes.
- Scheduler eligibility wake-ups implemented and deployed: coalesced wake generation, spacing,
  cooldown and provider-pause expiry; network/display/manual-fill completion wake handling.
  Production-coordinator regression passes 13 checks including rapid focus replacement.
- Actual installed Firefox-backed YouTube predictive reads observed: 07:54:22 at resume 52.72 s,
  11.88 s buffered in 2.558 s; further bounded reads after Build 16 at positions 11.5 and 725 s.
  Local same-fixture startup comparison: cold 1.7 s, buffered 0.1 s (one measurement, not a
  general YouTube latency guarantee). Release bundle passes dependency/font/WebGL checks with
  MacPorts reads denied. Consistent database backups and original Build 14 bundle retained at
  ~/Library/Logs/sofa-memguard/deploy-backup-20261109-075037; .prev retains the preceding build.
- Root audit: all 145 process footprints together ~5431 MiB, including ~837 MiB swapped;
  Sofa plus its browser tree ~1047 MiB. Direct recursive VM-region audit likewise finds only
  ~870 MiB swapped across mapped regions. Neither accounts for the historic ~39 GiB swap.
  Kernel zones ~1.24 GiB; tmux's ~1.5 GiB footprint is predominantly kernel-accounted memory,
  not its tiny terminal history. No blanket cache/history purge performed.
- Three private orphan test instances (dltest-b/c/d, PIDs 62582/62661/63020) were confirmed by
  root samples to deadlock in old SFMediaStore open -> bytes -> _opened group wait. Current
  source already uses bytesNow there. Terminating just those dead tests released ~262 MiB of
  logical compressed pages, only ~1 MiB swap: they do not explain the historic stock. See
  orphan-cleanup-20261109-082255.json. Current Sofa and regular jobs were left running.
- **Root cause reproduced, 08:27-08:29:** Darwin 13.4 POSIX shared memory leaks if shm_unlink
  precedes ftruncate. Apple xnu-2422.115.4 bsd/kern/posix_shm.c pshm_truncate assigns
  `pinfo->pshm_flags = PSHM_ALLOCATED`, discarding PSHM_REMOVED; pshm_close then never releases
  the backing memory. Firefox's GTK/POSIX CreateImpl uses precisely that order. Probe creates
  64 objects, 256 KiB each (16 MiB cumulative), touches/unmaps/closes every fd and exits:
  ~64 kernel objects/labels persist. With sizing BEFORE unlink, immediate label count is
  unchanged (135951 -> 135951); compressor-pager count also unchanged. Results saved in
  posix-shm-lifetime-20261109.json and posix-shm-safe-order-20261109.json under the log directory.
  This explains survival after process exit and why current fd/named-object audits missed it.
  ~137k compressor pagers/~136k labels are consistent with accumulated shared-memory objects;
  the precise attribution of every historic byte cannot be reconstructed from available APIs.
- Fix under build: firefox-x11 revision 4 patch-posix-shm-mavericks-lifetime.diff sizes Darwin
  shm before unlink and skips the later duplicate sizing. patch-audioipc-shm-mavericks-lifetime.diff
  fixes the same order in audioipc2 (including the vendored Cargo source checksum). Both patches
  apply cleanly to the saved originals and exactly reproduce the live source. Native safe-order
  probe also verifies readonly handles see the same written bytes. Non-Darwin behavior preserved. MacPorts incremental build reuses the existing configured tree;
  patch/source/state backup: firefox-shm-fix-backup-20261109-082952 under the log directory.
  PortIndex refreshed. Existing orphan kernel objects have no remaining name/fd to release;
  a controlled host restart is expected to be needed to reclaim the old stock, not performed.
- Build cache audit/correction (user request): old configured worktree lacked the C/C++ wrapper;
  Firefox's standalone .sccache path was outside MacPorts' write sandbox. Now use the existing
  embedded-cargo-legacy cache at .ccache/sccache, server 4227, 20 GiB. autoconf.mk confirms
  CCACHE=/opt/local/bin/sccache and MOZ_USING_SCCACHE=1. Small native compile probe cold/hot
  3.611/0.305 s with a confirmed hit; actual build requests include both C/C++ and Rust. First
  configuration populates a cold cache; this is not a measured full-Firefox rebuild speedup.
  Enabling the wrapper in this old worktree triggered a broad rebuild, not just the two changed
  files; no old C/C++ sccache entries existed. Build remains running; do not interrupt it.
  MacPorts' three warning scans over the large retained worktree took ~18 min after configure;
  kept running per host rules. Expected absence probe: pthread_cond_timedwait_monotonic_np.
- Targeted browser optimization prepared in Build 17: one warm preallocated content process
  instead of desktop Firefox's three. Two old spares measured ~37 MiB RSS each; verify actual
  new count after deployment. Fission/active-process limits/WebGL unchanged. HTTP memory cache
  already capped at 32 MiB by Firefox, so no redundant cache preference added.
- Bounded read-only root observer records vm_stat/swap and VM-object, IPC-port, MAC-label and
  compressor-pager counts every 10 s for at most 30 min; output shm-runtime-observation-20261109.jsonl.
- Additional completion audit found mpv's effective time-limit gap (09:14): with cache=yes,
  cache-secs overrides demuxer-readahead-secs and defaults to 10000 hours. Existing player probe
  paused a 60 s file and still buffered 59.1 s / all 1344741 bytes. Fixed both production cores:
  SFPrebufferReader cache-secs=12 (mandatory limit); SFMPVEngine cache-secs=30 and RAM backward
  packet cache=0. The persistent store remains the source for earlier media. Local reader probe
  now reports exactly 12 s at resume 70 s and passes the <=15 s upper-bound check.
- New meaningful part-c regression holds a paused 180 s file for 20 s (long enough to deliver
  the full 4033888 bytes at the fixture server's rate). Passes: 30.000 s decoder forward cache,
  only 1572864/4033888 bytes persisted, no full item fill. Transport/demux look-ahead adds bytes
  beyond the decoder's time window; the old tiny 60 s fixture could fit entirely in those bounded
  extra buffers, so it was unsuitable for the partial-file assertion. A seek 20 -> 5 s reuses
  persistent bytes without another source request, despite zero RAM backward packet cache.
  Cold/buffered local first frame at 30 s: 1.8 / 0.2 s in this run (not a universal guarantee).
- Part-c also exposed own-proxy rewrapping with SOFA_PROXY_LOOPBACK enabled: a completed download
  resolved to its local store URL, then prediction wrapped it again and replaced its manifest
  with a second proxy track. SFMediaProxy.localURLFor is now idempotent for its own HTTP origin,
  even in loopback fixture mode. Regression verifies URL/session identity; full suite now passes
  again including completed download origin, full timeline shade, offline replay, HLS and manual
  reuse. Native proxy lifecycle still verifies 200 released readers and the active neighbor.
  Log: cache-window-player-owned-20261109.log. YouTube-shaped separate audio/video integration
  rerun also passes (youtube-prebuffer-cache-window-20261109.log): partial common store, exact
  missing-byte manual fill, offline session with no RPC and one copy after reopening. Its fake
  browser RPC supplies generous 1 MiB chunks, so its byte fraction is not a real SABR time bound.
- 30-minute pre-deployment root sampler completed exit 0 (180 samples, session 91735). It covers
  the still-old browser plus compiler/test load, NOT post-fix runtime acceptance. Log:
  shm-runtime-observation-20261109.jsonl. Repeat bounded observation after patched-browser deploy.
  Native Build 17 deployed 10:08:58 with these fixes after a full no-MacPorts bundle test.
  /Applications/Sofa.app native binary matches the tested candidate; .prev is Build 16.
  Database snapshot/verification: native-build17-backup-20261109-100803; integrity ok,
  all 291 download rows, 267 progress rows, 135 follows retained; subscriptions 0; tracks 83.
  Firefox restarted due changed prefs and engine ready at 10:09:14. Profile confirms one spare.
  Firefox runtime is still the unchanged old one; shm fixes await the port build.
- 09:42 read-only footprint recheck of live Build 16 (PID 73860): 572.65 MiB total,
  507.75 MiB private dirty including 163.79 MiB swapped/compressed; malloc 408.16 MiB,
  CG raster ~81.98 MiB. SFLayers' decoded-image NSCache has a 350 MiB target cost.
  This snapshot does not prove absence of a native heap leak, but the live app still cannot
  account for the ~39 GiB historic stock. Saved in footprint-sofa-during-build-20261109.txt.
  Do not shrink image-cache budgets or clear caches solely from this snapshot.
- Prepared a controlled real-browser retention gate while the port builds:
  `tools/test-browser-memory <complete-patched-app> --zones --out <private-report.json>`.
  Three fresh private profiles; each transfers 64 x 1 MiB ArrayBuffers to/from a cross-site iframe,
  renders WebGL, opens/closes three muted audio contexts, then ends only its own process groups.
  After all owned children stop, sudo -n zprint records object counts; raw before/after series
  and runtime library SHA256 go into the report. Default maximum aggregate IPC-port growth: 64.
  The actual Firefox source routes serialized structured clones through MessageBufferWriter,
  which uses shared_memory::Create above 64 KiB (ipc_message_utils.h/.cc). Audio covers the separate
  audioipc2 integration. This is stronger runtime evidence than a new app version or idle RSS.
  Python and both embedded JS syntaxes pass; known old runtime is safely
  rejected before starting any browser (required patched-library log marker). Actual rev4/rev5
  runtime results are recorded below. Authenticate sudo first without
  saving credentials; Firefox must run as the normal GUI user, never as root. Sandbox denies
  MacPorts reads, profiles are temporary, no YouTube requests, output gain is zero.
- Runtime checkpoint 12:00: Firefox rev4 finished successfully and was deployed as Sofa Build 18
  at 11:44. The old Build-17 browser/Xvfb were normally stopped first; new production browser
  PID 69013 started 11:44:47, engine ready 11:44:56. Installed native/Firefox hashes exactly match
  the tested candidate; both DBs pass quick_check, all 291 download rows / 267 progress / 135 follows
  / 83 tracks preserved. Rollback snapshot: ~/Library/Logs/sofa-memguard/browser18-backup-20261109-114138.
- New functional memory gate actually passed for rev4 AND rev5: three fresh profiles, 384 MiB
  aggregate cross-process transfers, nine audio contexts, WebGL. Services release some Mach
  rights asynchronously: retain immediate samples and a fixed 30-second post-exit timeline;
  unchanged port-growth limit 64 must hold for the final three samples. Rev5 compressor_pager
  stayed exactly 149514 throughout; final worst port delta -241, MAC.Labels 139680 -> 139595.
  Reports: browser18-memory-test4-20261109.json and browser19-memory-test-20261109.json in the
  private sofa-memguard directory. This is actual runtime evidence, not a syntax-only test.
- The first real fresh-profile playback probe exposed a separate inherited backport mistake:
  GTK-on-Darwin excluded upstream's EMSGSIZE retry despite still using Darwin SCM_RIGHTS.
  Rev5 restores ONLY that handling and sched.h, retaining the separate GTK/Mach-IPC choices.
  Incremental build succeeded with three compiler executions, no cache errors. Rev5 is active
  in MacPorts; full Sofa Build 19 candidate passes the no-MacPorts bundle check and memory gate.
  Real YouTube cold/resume verification subsequently passed; deployed in Build 20 (current checkpoint above).
- Buildcache: 1,472,732 KiB persisted on disk, shared server 4227 / 20 GiB. The first incremental
  build also exposed an inherited private MacPorts pipe held by the idle cache daemon after
  mach exited. Port sample + lsof proved the same pipe endpoints; graceful idle --stop-server
  released EOF and port finished exit 0. start-sccache.py now starts via close_fds=True before
  configure/build. A deliberately inherited-pipe fixture passes. No live compiler was stopped.
  Worktree, source/config and state preserved with timestamp backups; previous port revisions
  remain inactive as rollback. No full configure/clean needed for the IPC follow-up.
- Historical acceptance checkpoint before Build 20: real verification and runtime adoption are
  now proven above; clean-host observation and old-stock reclamation subsequently completed. Native Build 18 footprint at 11:57:
  195.66 MiB, 24 KiB swapped. Global historic swap still ~41.8 GiB; not attributable to current
  native heap. Existing orphan kernel objects likely need a separately approved host restart.




## What the user sees

- Ordinary buffered bytes stay available without a "geladen" tile label. "Heruntergeladen"
  identifies the user's explicit complete, pinned buffer; kept until the user deletes it.
- "Herunterladen" on a video watched (or half watched) fetches only what is missing.
- Usage and already loaded suggestions choose bounded startup windows; following a channel
  never queues complete automatic downloads. Ordinary buffers remain evictable.
- All sources (YouTube and the mediatheks), not one alone.
- The space is computed from the disk: the buffer may use the free space minus a reserve that always
  stays free; downloads count against the disk, never get evicted.

## Where the bytes flow (before the store; now see the phases)

- YouTube: mpv reads `http://127.0.0.1:<port>/s/<sid>/video|audio` from
  Sofa's loopback server (`SFYTEngine+Media.m`), which asks the engine page for 1 MiB pieces; the page
  holds the SABR segments in memory (`res/sofa-yt/lib/session.ts`, capped and evicted).
- Mediatheks: mpv reads the CDN's HLS / MP4 through SFMediaProxy (4a/4b); downloads fill the store.

## The design

### 1. SFMediaStore (src/Library) - bytes on disk, by track

- A **track** is one byte stream with a stable identity: `key` = source-specific. YouTube:
  `yt:<video>:<format key>:<lastModified>:<length>` - named by the engine (open and read answers), so
  the sofa, a lounge video and a download of the same format share one copy; a re-encode (new lmt) is
  a new track. Later: `http:<url-hash>:<length>` (a progressive file), `hls:<playlist-hash>:<segment>`.
- Bytes live in **4 MiB block files** `~/Movies/Sofa/.store/<track>/<block>` (HFS+ has no sparse
  files: one file per track would write zeros up to every seek target); the present ranges are an
  `SFExtentSet` per track, in memory (reads never wait on the database).
- Persisted in the store's **own database** `.store/store.db` (own connection and queue: the user
  database never waits on media writes), schema version 1 (`PRAGMA user_version`):
  - `tracks (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, item TEXT NOT NULL, kind TEXT NOT NULL, total INTEGER NOT NULL DEFAULT 0, used REAL NOT NULL)` + index on `item`
  - `extents (track INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE, start INTEGER NOT NULL, end INTEGER NOT NULL, CHECK (end > start), PRIMARY KEY (track, start)) WITHOUT ROWID`
  - Later (phase 2): what playing a complete entry offline needs (formats, duration, subtitles, end
    screen) without the source.
- Retention lives with the item, in `downloads` (the user-facing record it already is), its kind
  explicit in `downloads.store` (1: the content is the store's tracks, 0: a file). A store download
  and anything a pending download will read are pinned - a snapshot set SFDownloads swaps on every
  record write (the store asks from its own queue). A file download (sources not in the store yet)
  drops the store copy it was read through once its file is installed. A pre-buffered episode gets
  an expiry (phase 3); an item without a record is plain buffer.
- Integrity: on open the store checks its index against the block files (asynchronously); at launch
  store downloads that are no longer complete are queued again and fill only what is missing.

### 2. Read-through at the proxies

- **YouTube**: `serveTrack:` serves each piece from the store when present, otherwise reads it from
  the engine and writes it to the store on the way to mpv. A session for a complete entry needs no
  SABR at all.
- **Mediatheks**: a generic loopback proxy (`SFMediaProxy`, same `SFLocalHTTP`) in front of the CDN:
  progressive MP4 by ranges, HLS by rewriting the media playlist to local segment URLs. mpv plays the
  local URL; every byte passes the store.

### 3. Filling and pinning ("Herunterladen", pre-buffering)

- A filler fetches a track's missing extents through the same path a player uses (YouTube: engine
  reads at human pace - the engine paces SABR already; HTTP: range GETs), one item at a time, after
  manual requests first, under the existing per-source budgets and bot-check pauses.
- Complete + `keep` = Heruntergeladen. No MP4 mux for new YouTube downloads: playback reads the
  tracks; an MP4 export stays possible as an action of its own if ever wanted.

### 4. Eviction

- Budget = free space on the volume minus the reserve (`SFDownloads storageReserve`), re-read on
  every write batch; over it, unpinned tracks go least-recently-used first, partial before complete,
  expired pre-buffers before everything. Pinned tracks are never touched; the storage guard stops
  fillers instead.

### 5. UI

- Tiles: a small mark for "geladen" (the existing download mark for "Heruntergeladen").
- Timeline: the stored ranges as a shade under the played bar (from the extents).
- "Herunterladen" on a buffered item: "noch 340 MB" while it fills.

### 6. Migration

- Existing MP4 downloads stay as they are (pinned files); the store starts empty.

## Phases

Decided with the user 2026-11-08: download and buffer are merged, not bridged - no MP4 for what the
store can hold; existing downloads may be deleted (no migration of old files).

1. Done: store + YouTube read-through + eviction (resume from disk; nothing visible but speed).
2. Done - YouTube merged (SFYTEngine+Store.m, SFYTEngine+Fill.m, SFApp fillItem:, test-downloads 8):
   a. Manifests in the store (schema v2): per item what playing it needs without its source - the
      tracks (video, main audio), subtitles (stored as small tracks), duration, end screen,
      published. Written when a session opens.
   b. Store sessions: an item whose manifest tracks are complete plays from a session Sofa serves
      itself (same answer shape as the engine's, local URLs) - no engine, also offline.
   c. Filler: a download is pin + fill - the missing ranges are read through the same read path
      (engine session, paced like a player), no ffmpeg, no MP4, no verifier/repair.
   d. `downloads` = intent only (state, subscription, keep, online check); size from the store; the
      path/bytes/repair columns and YouTube's ffmpeg path go; existing YouTube downloads deleted.
3. Done for sources that fill the store - pre-buffering replaces subscription downloads: a subscription
   episode filled into the store gets `downloads.expires` (schema step 15) = complete + 14 days, and
   goes 3 days after it was watched at the latest (SFDownloads expirePrebuffers: at start and every
   3 h). Expired = dismissed (not fetched again), its bytes plain buffer (evicted when room is needed).
   "Behalten" keeps it; "Herunterladen" on it makes it a download (no expiry, nothing loaded again).
4. Mediatheks through SFMediaProxy:
   a. Done - progressive files (ZDF, ARD, CCC): src/Library/SFMediaProxy - the player reads a local
      URL, stored ranges come from disk, each gap from the source in one streamed range request
      (SFCurlStream: curl for every host, backpressure from the reader); track key
      "file:<item>:<host+path hash>:<length>", manifest kind "file" (+ subtitles as tracks). A complete
      item plays from the store without its source (SFDownloads localCopyOf:); the download worker fills
      generically (no ffmpeg) when an app has no fillItem: but resolves to a progressive file.
      Loopback sources stay unproxied (local already; tests opt in with SOFA_PROXY_LOOPBACK).
   b. Done - HLS (ORF): SFMediaProxy+HLS.m rewrites the playlists (resources as tracks
      "hls:<item>:<hash>", keys included; VOD only stored); a download takes the best variant <= 1080p
      plus the default audio rendition, manifest kind "hls". SFStreamProxy went. The player gets the
      same one variant (with its audio renditions): lavf probes every variant's first segments before
      playing - 8 ORF variants made a start 13-21 s, one makes it 2 s - and playback keeps what a
      download needs. Resources stream to the reader as they arrive, kept once whole.
   c. Done - one kind of download (schema step 16): the file downloads' files and thumbnails deleted
      (a subscription episode stays dismissed, a manual one leaves), `downloads.path`/`store` dropped;
      ffmpeg (no longer bundled), the verifier, repairs, orphan reaping and the ytdl-sub migration went.
      A source that neither fills (fillItem:) nor resolves to a file/HLS the proxy serves cannot be
      downloaded.
5. UI:
   a. Done - tile mark: "geladen" for bytes on disk without a download the user keeps (buffer, a
      pre-buffered episode); the download marks as before (SFTileStatus; the store's per-item byte sums
      are readable from any thread without its queue).
   b. Done - "Herunterladen" on a partly loaded video says what is missing ("noch 340 MB", exact from
      the manifest's track lengths; SFMediaStore missingBytesOf:, SFDownloads download:told:).
   c. Timeline shade of the stored ranges - exact only, never a proportional guess (user 2026-11-08:
      "exakt, ORF zuerst"). Done for HLS (ORF): SFMediaProxy records each VOD media playlist's segments
      with their #EXTINF times and what each needs (segment, key, init section); the playlists the
      player reads resources of are the active ones (not every variant lavf parsed), a time is stored
      when every active playlist's segment is complete (video and audio rendition). The player asks
      every 3 s while the bar shows, off the main thread (SFPlayerScreen+Stored.m). Done for YouTube:
      the engine hands over its tracks' segment indexes (engine call `index`: WebM Cues / MP4 sidx,
      byte offset -> ms, once their init segments arrived); Sofa keeps them in the manifest ("index",
      by track identity - stored sessions have them offline) and counts a span when its bytes are all
      on disk, video and audio both (SFYTTimeline, SFYTEngine+Timeline.m; app hook storedRangesOf:).
      Done for the mediatheks' progressive MP4 files: SFMP4Index reads the moov's sample tables from
      the store (stco/co64, stsc, stsz, stts, an edit list's start) - every audio/video chunk's byte and
      time span; parsed once per session when the moov is on disk (faststart or at the end).
