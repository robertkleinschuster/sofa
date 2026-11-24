# sofa-fand: fan control that learns

An always-on root daemon for Intel Macs whose SMC takes forced fan targets, built and tuned on the
iMac12,2 (27", Mid 2011, OS X 10.9.5, SMC 1.72f2). It
behaves as if Apple's fan minimum were 0: **quiet when idle, cool under load.** When things
are cool, the fans go down to 0 rpm. When warm, they run faster than Apple's SMC would (the SMC
keeps every fan at its minimum until a sensor reaches Apple's own fan threshold, see below).
The SMC is only the emergency fallback.

It is its own program with its own Makefile. It is not linked into Sofa and Sofa's build does
not compile it. Sofa may send a context hint and reads the thermal level back over a Unix
datagram socket. Without Sofa the daemon works the same with its default profile.

Status: **v4** (2026-11-23): the hand-made reference curves (measured, `docs/fan-tuning.md`), a
learned layer on top of them, a recorder inside the daemon and a nightly learner that models the
machine from its own data and improves the layer one checked step at a time (issue #2). One
binary; everything machine-specific comes from the SMC or the reference file.

## Interface for Sofa (v1, agreed with the Sofa side)

**Hint, Sofa → daemon:** `SOCK_DGRAM` to `/var/run/sofa-fand/hint.sock` (directory root 0755,
socket 0666). One JSON object per datagram, at most 512 bytes:

```json
{"v":1,"ctx":"playback","vol":0.4,"ttl":90,"pid":1234}
```

- `ctx`: `playback` (sound masks fan noise, run cooler), `idle` (menu, still picture), `ruhe`
  (rest mode, as quiet as possible).
- `vol`: 0..1, or `null` if unknown (then counted as 0.5 for playback).
- `ttl`: seconds the hint stays valid, clamped to 10..300.
- Send on every context change and every 30 s as a heartbeat. Send nonblocking, ignore every
  error, never wait.
- Without a fresh hint the `default` profile applies. Broken JSON, `v` ≠ 1 or an unknown `ctx`
  is dropped silently. Unknown fields are ignored.
- A hint only shifts the curves (profile). It never changes limits, floors, the
  Apple-minimum guarantee or emergency behaviour. The HDD fan ignores profiles
  (`profile_weight 0`), so the loud fan stays sparing during playback too.
- **Authentication:** datagrams carry no credentials. The daemon therefore accepts a hint only
  from a sender bound directly inside `<home>/Library/Caches/Sofa/` of the `allow_uid` user. That directory must
  belong to that uid and be writable by nobody else, and the socket must be owned by it. Only
  that uid or root can create such an address. Unbound or foreign senders are dropped (`status`
  counts them). Context changes are logged at most once per 10 s.
- **Strict JSON:** exactly one flat object, no duplicate keys, no nested values, nothing after
  `}`; `v` must be the number 1.

**State, daemon → Sofa:** sent as a reply datagram (`sendto`, nonblocking, errors ignored) to the
hint's sender address after every hint, and pushed at once to the last valid address on every
level change:

```json
{"v":1,"level":1,"mode":"curve","cpu_c":59.6,"gpu_c":52.2,"hdd_c":47.0,"psu_c":75.5,"amb_c":23.4,
 "fans":[{"name":"ODD","rpm":1148},{"name":"HDD","rpm":1288},{"name":"CPU","rpm":940}]}
```

- `level`: 0 normal, 1 warm (a sensor within 5 °C of its warn point), 2 hot (at warn), 3
  critical (within 2 °C of a trip, or tripped). Hysteresis 2 °C, handled by the daemon.
- `mode`: `curve` (daemon regulates), `trip` (limit or fault), `smc` (SMC regulates: start or
  config error). A temperature of `-1` means unreadable.
- Replies go only to an authenticated sender (see above). Sofa binds
  `~/Library/Caches/Sofa/fand.sock`. The socket thread runs with uid 501's credentials
  (`pthread_setugid_np`), so `lstat` and `sendto` are checked by the kernel with the user's
  rights. A symlink swapped in after the check therefore cannot make root write elsewhere.
- If Sofa hears nothing for 120 s, it assumes level 0.

**Diagnosis:** `/var/run/sofa-fand/ctl.sock` (stream, one command line): `STATUS`, `STATE`, `HINT
<json>` (root/uid 501 only); root only: `IDENT SECS TAG RPM...` (identification step, see
"Learner"), `IDENTSTOP`, `FLUSH` (recorder to disk within ~20 s), `SIMSLEEP`/`SIMWAKE`. Sofa does
not need it. CLI:

```
sofa-fand status              # mode, level, profile, fans, temperatures, last 15 log lines
sofa-fand state               # the JSON Sofa gets
sofa-fand hint playback 0.4 60
```

## How it regulates

Each control step, for each fan (step length: see "Adaptive sampling" below):

1. **Inputs:** each fan has curves (temperature → rpm, linear between points) on the
   sensors it actually cools (coupling measured, see Measurements). The fan runs the
   highest demand of its curves.
2. **Feed-forward:** sensors marked `ff cpu`/`ff gpu` read hotter by CPU or GPU load:
   `+ff_cpu × cpu_load`, `+ff_gpu × gpu_load`. Load comes from `host_processor_info` and from the
   rate of `HWChannel PM4 | Commands Completed` (IOAccelerator `PerformanceStatistics`). Both are
   smoothed (τ 20 s rising, 120 s falling), so a fan turns up before the temperature follows,
   comes back slowly and does not pump on short spikes.
3. **Profile:** curves are read `shift` °C cooler (`+` = quieter, `−` = cooler):
   `default 0`, `ruhe +2`, `idle −2`, `playback −4 − 2×vol` (reference; the learned layer may move
   them, `idle` and `playback` only cooler), weighted per fan
   (`profile_weight`, 0 for the HDD fan). Feed-forward is likewise weighted per fan
   (`ff_weight`).
4. **Floors** (independent of profile and feed-forward): `floor N KEY T RPM` keeps fan N at
   ≥ RPM while KEY ≥ T. They hold in every case: an active floor also overrides `minoff`. The reference sets them to
   Apple's minimum well below Apple's own fan thresholds; on top, the daemon adds a machine floor
   from the SMC for every sensor with an Apple fan-start threshold (`S<ab>F`): there every fan runs
   at least Apple's minimum, whatever the reference or the learned layer say.
   Apple runs exactly its minimum below those thresholds, so the daemon never cools less than
   Apple where it matters.
5. **Hysteresis, ramps, dead band:** falling demand is computed at T + `hyst`. Speeds rise at
   most `up` rpm/s and fall at most `down` rpm/s. Between 0 and `minrun` a fan does not run
   stably, so it is either 0 or ≥ `minrun`. `minon`/`minoff` keep a started fan on and a stopped
   fan off for that long, unless a coupled sensor reaches its warn point. This matters for the
   HDD fan: it is the loudest, it only runs (≈1280 rpm at its lowest duty) or stops, and its
   start is the audible part.
6. **Spin-up check:** a fan commanded to turn must reach half its target within 15 + 20 s.
   Otherwise it is a fault.

### Adaptive sampling (few wakeups)

**Cost:** every SMC transaction makes the AppleSMC driver wait for the SMC in many small steps,
about 25 kernel wakeups per read or write (dtrace, 2026-11-18). Reading 20 sensors every 2 s
cost 540 wakeups/s, so the daemon samples as rarely as is safe.

**Fewer transactions:**
- the key info (size, type) of each key is cached, so a read is one transaction;
- `F<n>Tg` and `FS!` are written only on change. `FS!` is read back every step: if anything
  outside changed it (SMC reset, a tool), every target is written again at once;
- everything is written and verified on full cycles (every 120 s), on wake and after every fault.

**What is read when:** sensors marked `fast 1` every step: GPU die and heatsink, CPU proximity,
PECI, core 0, PSU heatsink. The other sensors (PSU 1/3, PCH, RAM, LCD, ODD, cores 1-3, TS0P,
ambient) every 120 s. Speeds of stopped fans are read every 120 s.

**Step length** (the most demanding fan or sensor wins):

| step | when |
|---|---|
| 2 s | a fan moving or just started; a sensor ≥ warn−2; trip, fault, SMC, start or wake; 60 s after a Sofa context change or a CPU/GPU load jump (> 0.25) |
| 5 s | a stopped fan within 2 °C of its curve start; a sensor ≥ warn−5 |
| 10 s | otherwise (fans stable, everything far from thresholds) |
| 20 s | only if all fans stand, every sensor is ≥ 8 °C below its warn point and below every curve start, and the context is not playback |

**Reaction time:**
- The fastest riser is the GPU under sudden load (measured 64 → 75 °C in 40 s with the ODD fan
  at 500 rpm, ~16 °C/min).
- In 20 s it climbs at most ~5.3 °C, so the 8 °C margin still leaves reserve. From then on the
  daemon samples every 10/5/2 s. The GPU trip (80) is ≥ 14 °C above where the 20 s step is allowed.
- The PSU heatsink rises at most ~1.2 °C/min (measured: all fans off, one core at 100 %).
- The slow sensors rise ≤ 1.2 °C/min, so 120 s means ≤ 2.4 °C delay; their trips are far away.
- The drive is read every 30 s (SMART), as before.

**Event-driven threads:**
- The control loop sleeps until its next step. A signal, a new Sofa hint or a wake wakes it
  early (pipe).
- The socket thread waits without a timeout.
- The guard is woken by the kernel when the controller exits (kqueue `NOTE_EXIT`). Otherwise it
  checks the heartbeat every 5 s. It treats the controller as hung when it misses its own
  announced next step by 10 s (~17 s at 2 s steps, ~35 s at 20 s steps), at most 45 s.

**Result (2026-11-18):** see `docs/fan-tuning.md`, "Wakeups".

### Apple's thresholds (read from the SMC)

| sensor | fan start | warning | throttle | shutdown |
|---|---|---|---|---|
| Tp2H power-supply heatsink (Sp2*) | 96 | 98 | 103 | 108 |
| Tp1P / Tp3H power supply (Sp1*, Sp3*) | 79 | 84 | 89 | |
| TL0P LCD (SL0*) | 58.4 | 60.4 | 66 | 68 |
| TS0P (SS0*) | 50 | 52 | | |

Control targets: GPU `SGTg` 77, CPU `SCTg` 70, PECI `SCXC` 86, ODD `SOTg` 55.

## Safety

| case | reaction |
|---|---|
| daemon start | `FS!` = 0 before anything else; fans take over smoothly from their current speed |
| sensor unreadable (SMC key, or SMART older than 150 s), SMC read/write error | fault: `FS!` = 0 (SMC) for `trip_hold` (300 s) |
| fan does not turn | fault |
| temperature ≥ `trip` | trip: **all fans to their maximum** for 300 s, until everything is 3 °C below its trip point. The sensors are healthy, so this cools more than the SMC would. If the write fails: SMC |
| SIGTERM/SIGINT (`launchctl unload`) | controller and guard reset `FS!` = 0, then exit |
| controller crash (SEGV/BUS/ABRT/ILL/FPE) | its handler resets; the guard resets again |
| controller **SIGKILLed** | the guard sees it within 0.5 s (waitpid), resets, forks a new controller (no exec) |
| controller hangs | misses its own announced next step by 10 s (≤ 45 s): the guard resets, kills it, forks a new one |
| guard SIGKILLed / both killed | launchd KeepAlive restarts it (< 1 s measured); the start resets first |
| config missing or invalid | mode `disabled`: runs, SMC regulates, `status` names the error |
| `FS!` set although the controller forces nothing | the guard resets it |
| system sleep | `kIOMessageSystemWillSleep`: `FS!` = 0 before the sleep is acknowledged, controller pauses. After the wake: SMC until fresh sensor values arrive (monotonic time stood still, so hint and drive reading from before the sleep are dropped). A hang during sleep/wake leaves the fans under SMC control. Tested with `SIMSLEEP`/`SIMWAKE` on the ctl socket (root); the Mac itself is never put to sleep (known disk hang after standby) |
| `FS!` cannot be cleared (3 tries) | every fan forced to its maximum instead: a stuck forced mode is loud, never quiet |
| sleep notifications unavailable | the daemon stays in SMC mode (never forces without sleep handling) |
| guard dies | the controller notices (`getppid`) and stops with `FS!` = 0; launchd starts a new guard |
| trip and controller restart | trip state lives in the guard's shared page; a new controller inherits it |
| Sofa crashes, hangs, sends garbage | hint expires (ttl) or is dropped; default profile |

**Two processes.** launchd starts the guard. Once the controller runs, the guard no longer
calls `syslog` itself: it writes into a ring in the shared page, and the controller's log
thread passes the lines on. The guard resets `FS!`, reads the config once,
binds the sockets and forks the controller. The guard only watches it, through waitpid plus a
heartbeat in an anonymous shared page.

**No disk in the control loop.** The controller's loop only does SMC calls, IOKit
statistics and arithmetic. Socket I/O and the `lstat` of Sofa's reply path run in a socket
thread. SMART runs in its own thread: the SMART user client is exclusive, so it is opened,
read and closed every 30 s, and `smartctl` keeps working. Logging goes into a RAM ring that a
log thread hands to syslog. If one of these threads blocks (vanished disk, stuck syslogd),
regulation goes on; a stale SMART value becomes a fault. Both processes wire only their own binary and their own stacks. They do **not** wire system
libraries: wiring all loaded images, i.e. shared-cache pages, and an `mlockall` attempt
(versions up to v3.1) coincided on 2026-11-17 from 22:19 with a system-wide crash wave in
new processes (jump to 0x0 in CoreServicesInternal; the kernel logged "DYLD shared region
unnest"). Never `mlock` shared-cache or foreign image segments on 10.9.

**Floor 0 (the user's decision):** no fan has an unconditional minimum. When everything is
cool, fans really stop. Floors (Apple minimum) only start at their thresholds.

**What remains:** guard and controller SIGKILLed together *and* the boot disk gone at the same
moment, so launchd cannot start the binary again. A kernel hang is the same case. Then the last commanded speeds stay. If
that was 0 rpm and heavy load followed, the GPU would reach 75 °C after about 7 min (measured:
all fans off, ffmpeg at 260 %); after that the GPU throttles itself and the SMC's own
shutdown thresholds remain. A kernel hang usually stops the load, but a spinning
lock can keep one core at 100 %. Two measurements cover it, with the results in
`docs/fan-tuning.md`: overnight block A, "all fans off at idle, display on", and test 38,
"all fans off + one core at 100 % + display on", each until equilibrium or a limit. A
floor per fan (`curve` with a non-zero first point) would remove the case at the cost of idle
noise. The user chose floor 0.

## Measurements

The reference curves come from the 2026-11-17/18 measurement series (fan × sensor matrix, τ63,
Apple reference), documented in `docs/fan-tuning.md`; the raw data stays on the iMac under
`~/Library/Logs/fan-tuning-2026-11-17/`. The measurement tools of that time (`smcfan`, `smcenum`,
`smarttemp`, `fanlab`, the night scripts) and the first learner stages (`sofa-fanlearn`,
`fanmodel.py`, `ident.sh`) are replaced by the daemon itself (`hw`, `status`, recorder, `ident`)
and `sofa-fand learn`; they remain in the git history up to commit 881f2da.

First results (2026-11-17):

- The **HDD fan** ignores targets below ≈1280 rpm (lowest duty) and only stops at 0.
- The **ODD fan** cools the GPU: under playback the GPU goes 64 → 68 °C at 900 rpm, still
  rises at 700, and reaches 75 °C after 40 s at 500.
- The **CPU fan** at 0 under playback: the CPU settles at 58 °C, and the power-supply heatsink
  Tp2H stays at 81-83 °C. Under Apple control during playback Tp2H reaches 85 °C.
- **All fans off** at idle: GPU +3 °C in 100 s.

## Configuration: reference + learned layer

Two files, read at start and on `sofa-fand reload` (SIGHUP to the guard: the new configuration
reaches the running controller through a shared page, the fans never fall back to the SMC):

- **Reference** `/usr/local/etc/sofa-fand.conf` (root, hand-made, this repository): sensors with
  `trip`/`warn` (default: from Apple's SMC limits) and `target` (what the learner keeps them
  below, default warn − 6), fans (`name`/`max` default to the SMC's; `loud` = how much the
  learner counts its noise), curves, floors, profiles (`learn cooler` = the learned layer may
  only make it cooler; `noise` = how much quiet matters there). The syntax is in the file's header.
- **Learned layer** `/var/db/sofa-fand/learned.conf` (root-only, installed only by
  `sofa-fand apply`, normally by the learner): `shift N KEY DEG` (read fan N's curve on KEY DEG
  °C cooler: + later/quieter, − earlier), `profile NAME BASE [VOL]`, `curve N KEY T:RPM...` (an
  additional curve, only ever adds demand).

The layer is **all or nothing**: a line that is unknown, out of bounds or breaks a rule refuses
the whole layer, the reference applies alone and `status` names the reason. The rules
(`learned_check`, the same function the daemon, `apply` and the learner use):

- |shift| ≤ 8 °C, |profile| ≤ 8 °C; a `learn cooler` profile never gets quieter than the reference;
- at a sensor's warn temperature no reference curve asks for less than the reference does, in the
  worst case over every profile and volume;
- limits, floors (including the machine floors), fan dynamics and the sensor set are out of reach.

`sofa-fand apply FILE` validates, keeps the previous layer as `.prev`, installs and reloads;
`sofa-fand rollback` restores it. `make test` runs the validator cases (`tools/test-config.sh`).

## Recorder

A thread in the daemon writes what the learner learns from: every 20 s (10 s while a fan runs,
under load or during an identification step) one row with time, mode, profile, volume, load,
identification tag, every fan's actual and commanded speed, the machine's power keys (W; total,
CPU package, GPU - picked from the SMC per model) and every configured sensor. Rows wait in RAM
and go to `/var/db/sofa-fand/data/YYYY-MM-DD.csv` every hour, on reload, on `FLUSH` and on exit;
the control loop never touches the disk. A `#` line names the columns before every flush, so the
column set may change at any time. Files older than 180 days are removed. Dry runs (`-n`) record
nothing. `sofa-fand migrate` moved the old collector's data (2026-11-18..23) and its
identification intervals (`tests.csv`) into this directory.

## Learner

`sofa-fand learn`, nightly at 01:30 (LaunchDaemon `de.sofa.fanlearn`, root, nice 10). Report:
`/var/db/sofa-fand/report.md`; decisions: `history.log` next to it; job output: `learn.log`.

1. **Trial.** If a step is on trial, it is judged on measured data, never on the model: after ≥ 2
   days and ≥ 10 h of use minutes (at the latest after 10 days), against the 7 days before, per
   mode. Rolled back on more warn minutes per hour, on a sensor whose 95 % temperature over
   ambient rose by > 1 °C to above its target, and - for a quieter or mixed step - when the
   measured fan noise did not drop by 2 %. A rolled-back step's directions are not tried again for
   14 days. No new step while one is on trial.
2. **Model.** Per sensor, on the last 30 days of one-minute bins:
   `dT/dt = a0 + h_cpu·Pcpu/10 + h_gpu·Pgpu/10 + h_rest·Prest/10 − (k0 + Σ k_f·rpm_f/1000)·(T − Tamb)`
   (non-negative least squares: power heats, fans cool). Validated by free runs over every held-out
   2 h chunk (the model integrates its own temperature from the measured inputs), per mode (rest,
   in use, playback, identification). First fit on the migrated data (2026-11-23): free-run RMSE
   0.4-1.8 °C over all modes, the old `fanmodel.py`'s range.
3. **Scenarios** per use mode with ≥ 2 h of data: mean inputs, high load (top 10 %), warm room
   (+5 °C). Each runs 6 h through `policy_fan` - the controller's own decision function, so what
   is simulated is what runs - from a cold and a hot start.
4. **Cost** = noise (Σ profile noise × loud × (rpm/1000)², starts counted) + temperature penalty
   (5 × (peak − target)² outside the warm room; 200 + 100/°C at warn). Only sensors whose model
   is validated in that mode count: an unreliable model never drives the fans.
5. **Search.** Greedy, the single best move per round, at most 3 parameters (curve shifts,
   profile shifts), curves ±2 °C and profiles ±1 °C per night, inside the layer's rules. Quieter
   moves need every steering sensor validated in every use mode (free-run error ≤ 2 °C, 3 °C for
   load-driven sensors, ≥ 2 h each). A step is applied only if it lowers the cost by ≥ 2 % and the
   gain comes from its own part (a cooler step lowers the penalty, a quieter or mixed one the
   noise) - gains from hysteresis paths in the simulation are not a reason to touch the fans.
   Applied through `apply` and put on trial.
6. **Identification** (afterwards, ~75 min): while Sofa rests, the daemon runs one block of steps
   through its own `IDENT` command - base, each fan alone at 1.6 × Apple's minimum, all fans at
   their lowest stable speed, 15 min each - with every safety rule of the controller (limits,
   floors, ramps; ends at once when Sofa leaves rest, a sensor nears warn or anything faults). No
   artificial load. The recorder tags those rows.

`sofa-fand learn -n [-d DATADIR] [-c CONF]` writes the report to stdout and changes nothing
(any user). `make test` also checks the learner against data from a known law
(`tools/test-learn.sh`: the right fan per sensor group, free-run error < 0.3 °C).

## Another Mac

`sofa-fand hw` shows what the SMC offers (fans with Apple's min/max, every temperature key with
Apple's fan-start, warning, throttle, shutdown and target values, the power and ambient keys).
`sofa-fand init` writes an Apple-equivalent reference from that alone: every fan at Apple's
minimum, ramping to its maximum between fan start (or target) and warn on every sensor family
(`init -o FILE`, checked by the parser). Install it as the reference; the recorder and the
learner run as here. Once the model is validated in every use mode, the learner replaces an
`init` reference with quiet curves of its own (each fan answers the sensors it measurably cools:
off below target − 4, minimum at target − 2, maximum at warn), on trial like every step and rolled
back to the `init` reference if it does worse.

## Architecture

One binary (`src/`), no dependencies beyond IOKit and CoreFoundation:

| module | role |
|---|---|
| `smc.c` | SMC transport: key read/write, temperatures, `FS!`/`F<n>Tg`, return to SMC control |
| `machine.c` | what this Mac has, discovered from the SMC: fans, temperature keys, Apple's limits, power keys |
| `cfg.c` | reference + learned layer, parsed and validated (`learned_check`) |
| `policy.c` | the fan decision as a pure function - used by the controller and the learner's simulator |
| `control.c` | the control step: sensors, trips, faults, identification steps, published state |
| `sock.c`, `sysmon.c`, `log.c`, `record.c` | Sofa's sockets + ctl; SMART, load, sleep/wake; RAM log ring; recorder |
| `daemon.c` | guard + controller processes, reload, CLI |
| `learn*.c` | the learner: data, model, simulation, search, trial, identification, `init` (`learn.h`) |

## Operation

```
make && make analyze && make test   # build with -Werror, static analyzer, validator + learner tests
sudo make install                   # /usr/local/sbin/sofa-fand, /usr/local/etc/sofa-fand.conf,
                                    # de.sofa.fand (KeepAlive) + de.sofa.fanlearn (01:30);
                                    # prints the binary hash and the commit it came from
sudo ./sofa-fand run -n -c sofa-fand.conf   # dry run: computes, reports, never writes the SMC
sofa-fand status                    # mode, profile, learned layer, identification, fans, temperatures, log
sofa-fand learn -n                  # what the learner would do now (report to stdout)
cat /var/db/sofa-fand/report.md /var/db/sofa-fand/history.log
sudo sofa-fand rollback             # back to the previous learned layer
sudo sofa-fand ident 900 id-x 1840 -1 -1    # one identification step by hand (Sofa resting)
syslog -k Sender sofa-fand | tail

# switch off
sudo launchctl unload -w /Library/LaunchDaemons/de.sofa.fanlearn.plist
sudo launchctl unload -w /Library/LaunchDaemons/de.sofa.fand.plist
sudo /usr/local/sbin/sofa-fand reset        # FS! = 0 directly through the SMC
sudo make uninstall                          # remove everything (data and learned state stay)
```

To change curves or limits: edit `sofa-fand.conf`, commit, `sudo make install` (it checks the
config) or install the file and `sudo sofa-fand reload`.
