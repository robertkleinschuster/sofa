# sofa-fand: fan control for the iMac12,2

An always-on root daemon for the iMac12,2 (27", Mid 2011, OS X 10.9.5, SMC 1.72f2). It
behaves as if Apple's fan minimum were 0: **quiet when idle, cool under load.** When things
are cool, the fans go down to 0 rpm. When warm, they run faster than Apple's SMC would (the SMC
keeps every fan at its minimum until a sensor reaches Apple's own fan threshold, see below).
The SMC is only the emergency fallback.

It is its own program with its own Makefile. It is not linked into Sofa and Sofa's build does
not compile it. Sofa may send a context hint and reads the thermal level back over a Unix
datagram socket. Without Sofa the daemon works the same with its default profile.

Status: **v2, curves are a draft** until the overnight measurements of 2026-11-17 are
evaluated (`~/Library/Logs/fan-tuning-2026-11-17/` on the iMac).

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
  Apple-minimum guarantee or emergency behaviour.

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
- The daemon only replies to a sender bound directly inside `/Users/imac/Library/Caches/Sofa/`.
  The check (`lstat`) requires a socket owned by uid 501 in a directory owned by 501, with no
  symlinks and no `..`. Sofa binds `~/Library/Caches/Sofa/fand.sock`.
- If Sofa hears nothing for 120 s, it assumes level 0.

**Diagnosis:** `/var/run/sofa-fand/ctl.sock` (stream, one command line): `STATUS`, `STATE`, `HINT
<json>` (root/uid 501 only). Sofa does not need it. CLI:

```
sofa-fand status              # mode, level, profile, fans, temperatures, last 15 log lines
sofa-fand state               # the JSON Sofa gets
sofa-fand hint playback 0.4 60
```

## How it regulates

Every 2 s, for each fan:

1. **Inputs:** each fan has curves (temperature → rpm, linear between points) on the
   sensors it actually cools (coupling measured, see Measurements). The fan runs the
   highest demand of its curves.
2. **Feed-forward:** sensors marked `ff cpu`/`ff gpu` read hotter by CPU or GPU load:
   `+ff_cpu × cpu_load`, `+ff_gpu × gpu_load`. Load comes from `host_processor_info` and from the
   rate of `HWChannel PM4 | Commands Completed` (IOAccelerator `PerformanceStatistics`). Both are
   smoothed (τ 20 s rising, 120 s falling), so a fan turns up before the temperature follows,
   comes back slowly and does not pump on short spikes.
3. **Profile:** curves are read `shift` °C cooler (`+` = quieter, `−` = cooler):
   `default 0`, `ruhe +2`, `idle +1`, `playback −1 − 2×vol`.
4. **Floors** (independent of profile and feed-forward): `floor N KEY T RPM` keeps fan N at
   ≥ RPM while KEY ≥ T. They are set to Apple's minimum well below Apple's own fan thresholds.
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
| controller hangs | no heartbeat for 15 s: the guard resets, kills it, forks a new one |
| guard SIGKILLed / both killed | launchd KeepAlive restarts it (< 1 s measured); the start resets first |
| config missing or invalid | mode `disabled`: runs, SMC regulates, `status` names the error |
| `FS!` set although the controller forces nothing | the guard resets it |
| Sofa crashes, hangs, sends garbage | hint expires (ttl) or is dropped; default profile |

**Two processes.** launchd starts the guard. The guard resets `FS!`, reads the config once,
binds the sockets and forks the controller. The guard only watches it, through waitpid plus a
heartbeat in an anonymous shared page.

**No disk in the control loop.** The controller's loop only does SMC calls, IOKit
statistics and arithmetic. Socket I/O and the `lstat` of Sofa's reply path run in a socket
thread. SMART runs in its own thread: the SMART user client is exclusive, so it is opened,
read and closed every 30 s, and `smartctl` keeps working. Logging goes into a RAM ring that a
log thread hands to syslog. If one of these threads blocks (vanished disk, stuck syslogd),
regulation goes on; a stale SMART value becomes a fault. Both processes wire their code
(`mlock` of all loaded images, ~10 MB), because Darwin has no `mlockall`.

**What remains:** guard and controller SIGKILLed together *and* the boot disk gone at the same
moment, so launchd cannot start the binary again. Then the last commanded speeds stay. If
that was 0 rpm and heavy load followed, the GPU would reach 75 °C after about 7 min (measured:
all fans off, ffmpeg at 260 %); after that the GPU throttles itself and the SMC's own
shutdown thresholds remain. A floor per fan in the config (`curve` with a non-zero first
point) removes even this case at the cost of idle noise. See the report for the
recommendation.

## Measurements

The raw data stays on the iMac under `~/Library/Logs/fan-tuning-2026-11-17/` (`live.log`,
`plan.md`, `night.csv`, `ref-apple-playback.csv`). The tools are in `tools/`:

- `smcenum [PREFIX]`: list all SMC keys with values (`#KEY` + READ_INDEX)
- `smcfan`: status/read/force (first manual tool)
- `smarttemp`: SMART attribute 194 in-process
- `fanlab`: supervised steps (`rec`, `step DUR F0 F1 F2`, `burn N PCT DUR`, `watchdog`) with
  limits, CSV, live log, equilibrium detection, `FS!` = 0 on every exit
- `night.sh`: the overnight series (37 steps: CPU full load, playback-like load, idle,
  disk load with a SMART long test) with an independent watchdog

First results (2026-11-17, before the overnight series):

- The **HDD fan** ignores targets below ≈1280 rpm (lowest duty) and only stops at 0.
- The **ODD fan** cools the GPU: under playback the GPU goes 64 → 68 °C at 900 rpm, still
  rises at 700, and reaches 75 °C after 40 s at 500.
- The **CPU fan** at 0 under playback: the CPU settles at 58 °C, and the power-supply heatsink
  Tp2H stays at 81-83 °C. Under Apple control during playback Tp2H reaches 85 °C.
- **All fans off** at idle: GPU +3 °C in 100 s.

The fan × sensor matrix (ΔT per 100 rpm, τ63) and the tuned curves follow from the overnight
series.

## Operation

```
make && make analyze           # build with -Werror, static analyzer
sudo make install              # /usr/local/sbin/sofa-fand, /usr/local/etc/sofa-fand.conf,
                               # /Library/LaunchDaemons/de.sofa.fand.plist (KeepAlive);
                               # prints the binary hash and the commit it came from
sudo ./sofa-fand run -n -c sofa-fand.conf   # dry run: computes, reports, never writes the SMC
sofa-fand status
syslog -k Sender sofa-fand | tail

# switch off
sudo launchctl unload -w /Library/LaunchDaemons/de.sofa.fand.plist
sudo /usr/local/sbin/sofa-fand reset        # or: tools/smcfan force 0
sudo make uninstall                          # remove everything
```

To change curves or limits: edit `sofa-fand.conf`, commit, `sudo make install` (it checks the
config and reloads the daemon).
