# sofa-fand: quiet fans in Sofa's rest mode

A small root daemon for the iMac12,2 (27", Mid 2011, OS X 10.9.5, SMC 1.72f2). While Sofa
is in rest mode (engine off, nothing rendering), sofa-fand lets the fans run **below Apple's
minimum, down to 0 rpm**, as long as everything stays cool. Outside rest mode, and whenever
anything looks doubtful, the SMC regulates the fans as usual (`FS!` = 0).

It is its own program with its own Makefile. It is not linked into Sofa and Sofa's build does
not compile it. Sofa only talks to it over a Unix socket (see "Interface for Sofa").

## Interface for Sofa

Socket: `/var/run/sofa-fand.sock` (stream, mode 0666). One command line per connection; the
daemon answers and closes the connection.

| command        | answer                                  | meaning |
|----------------|-----------------------------------------|---------|
| `QUIET <ttl>\n`| `OK <mode>` / `ERR ...`                 | rest mode for `ttl` seconds (1-120), counted from now |
| `AUTO\n`       | `OK`                                    | end rest mode now |
| `STATUS\n`     | multi-line text, last line `.`          | mode, fans, temperatures, recent log |

- **Heartbeat:** while rest mode is active, Sofa sends `QUIET 30` every 10 s. If Sofa crashes,
  hangs or forgets it, rest mode expires on its own after at most 30 s.
- On leaving rest mode Sofa sends `AUTO`, so the fans come back right away and not when the
  TTL runs out.
- Only root and uid `allow_uid` (501 = `imac`, the uid Sofa runs as) may send `QUIET`/`AUTO`.
  Anyone may send `STATUS`.
- `OK` only means the request was accepted. Whether fans really go slower depends on the
  temperatures (mode `quiet`, `trip`, `auto`, `disabled` in the answer and in `STATUS`).
- If the daemon is missing (connect fails), Sofa ignores it. Nothing changes and the SMC
  regulates.
- Do it off the main thread: 300 ms timeouts, never block the UI.

Minimal client (C/ObjC):

```c
#include <sys/socket.h>
#include <sys/un.h>
// ttl > 0: rest mode for ttl s (heartbeat), ttl == 0: back to normal. Returns 0 if accepted.
static int SFFanRequest(int ttl) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) return -1;
  struct sockaddr_un sa = { .sun_family = AF_UNIX };
  strlcpy(sa.sun_path, "/var/run/sofa-fand.sock", sizeof sa.sun_path);
  struct timeval tv = { 0, 300000 }; int on = 1;
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
  char b[64]; int ok = -1;
  if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0) {
    int n = ttl > 0 ? snprintf(b, sizeof b, "QUIET %d\n", ttl) : snprintf(b, sizeof b, "AUTO\n");
    if (write(fd, b, n) == n && read(fd, b, sizeof b - 1) > 1 && !strncmp(b, "OK", 2)) ok = 0;
  }
  close(fd);
  return ok;
}
```

By hand: `sofa-fand status`, `sofa-fand quiet 60`, `sofa-fand auto`.

## Why a socket and not a flag file

OS X 10.9 has no tmpfs; `/tmp` and `/var/run` are on the boot disk, which has already dropped
out under the running system on this Mac. Once a socket is bound, talking over it needs no
disk at all, both for a new connection (the vnode is cached) and for an existing one. The same
channel carries status queries. `getpeereid` tells who is asking, and the TTL in the message
is the heartbeat, so no separate timestamp file is needed. Shared memory would also work
without the disk, but it has no permission check per writer and no answer channel.

## Safety

Every one of these makes the daemon write `FS!` = 0 at once, which puts all fans back under SMC
control:

| case | reaction |
|---|---|
| no rest mode / TTL expired / `AUTO` | `FS!` = 0 within one loop turn (2 s; `AUTO` at once) |
| a limit reached (`limit KEY MAX`) | trip: SMC for `trip_holdoff` (600 s), even if Sofa keeps sending `QUIET` |
| a sensor unreadable (SMC key or SMART stale > 120 s) | trip |
| a fan told to turn does not turn (< half the target for 20 s) | trip |
| an SMC read or write fails | trip |
| SIGTERM/SIGINT (`launchctl unload`) | controller and guard reset, then exit |
| controller crashes (SEGV/BUS/ABRT/...) | its own handler resets; the guard resets again |
| controller **SIGKILLed** | the guard sees it (waitpid, 0.5 s), resets, forks a new controller |
| controller hangs | the guard misses its heartbeat for 15 s, resets, kills it, forks a new one |
| guard SIGKILLed / both killed | launchd KeepAlive restarts it; the first thing a start does is `FS!` = 0 |
| daemon start | `FS!` = 0 before anything else |
| config missing or invalid | mode `disabled`: runs, never forces a fan |
| `FS!` set although the controller does not force | the guard resets it |

**Two processes.** launchd starts the guard. The guard opens the SMC, resets `FS!`, reads the
config, binds the socket and forks the controller. The controller regulates, and the guard only
watches it (waitpid + heartbeat in an anonymous shared page). Reforking needs no `exec`, so it
works with no disk at all.

**No disk in the loop.** The config is read once at start. Logging goes into a RAM ring
buffer, and a separate thread passes it on to syslog, so a stuck syslogd cannot stall
regulation. `STATUS` returns the last 12 lines. SMART is read in its own thread through
`IOATASMARTInterface`, the same thing `smartctl` uses but in-process, with no exec. If the
drive hangs, only that thread blocks, the reading goes stale, and that trips. `mlockall` does
not exist on Darwin, so both processes wire the segments of all loaded images with `mlock`
instead (~10 MB).

**What remains:** guard and controller killed together (`kill -9` on both) *and* the boot disk
gone at the same moment, so launchd cannot start the binary again. Then the last forced
speeds stay. With the measured values that is acceptable: in rest mode the load is low, the
CPU (0 rpm under playback load: settles at 58 °C) and the drive (+1 °C per 5 min at 0 rpm)
rise slowly, the GPU throttles itself, and a dead boot disk needs a hard reset anyway. If
that is not acceptable, give the fan a `floor` in the config (for example `floor 700` for
fan 0) so it never stops completely.

## Measurements (2026-11-17, room 22-24 °C, fans forced one by one)

Sensors (all 332 SMC keys enumerated): CPU `TC0P` (proximity), `TC0c..TC3c` (cores), `TCXc`
(PECI); GPU `TG0D` (die), `TG0H`; ODD `TO0P`; ambient `TA0P`; PCH `TPCD`; RAM `Tm0P`; power
supply `Tp1P`, `Tp2H` (heatsink). The drive has **no** SMC key (`TH0O`/`TH1O` are a constant 3.0,
probably the status of the OWC in-line sensor). Its temperature comes from SMART
attribute 194.

| fan (Apple min) | forced | result |
|---|---|---|
| F0 ODD (1150) - cools the GPU | 900 | playback: GPU 64 → 68 °C, flattening |
| | 700 | playback: GPU → 73.5 °C, still rising |
| | 500 | playback: GPU 75 °C after 40 s → aborted |
| F2 CPU (940) | 700 | stable |
| | 500 | CPU 51 → 54 °C, PSU heatsink 76 → 82 °C |
| | 0 | playback: CPU 55 → 57.8 °C (settles), cores ~67, PSU heatsink 81-83 |
| F1 HDD (1100) | 900 / 600 | **ignored**: runs at ~1250-1285 regardless, only on or off |
| | 0 | stops; low load: drive 46 → 47 °C in 5 min |
| all three | 0 | idle: GPU +3 °C in 100 s, CPU/drive flat; then a download (ffmpeg 260 %) started: GPU 75 °C after 7.5 min → aborted |

The GPU is the critical path (~2 °C/min without airflow under load). Spin-up from 0 works:
CPU fan 0 → 500, ODD fan 0 → 700 (both with a short kick).

## Curves and limits (`sofa-fand.conf`)

- **F0 ODD** after `TG0D`: < 56 → 0, < 62 → 700, < 66 → 900, above that the SMC; hysteresis 4 °C.
- **F1 HDD** after SMART: off up to 44 °C, back to the SMC from 46 °C (the fan can only run or stop).
- **F2 CPU** after `TC0P`: < 56 → 0, < 60 → 500, < 63 → 700, above that the SMC; hysteresis 3 °C.

Above the last step the daemon only releases that fan. It never sets speeds above Apple's
minimum; the SMC does that.

Limits (trip → SMC for 10 min): GPU `TG0D` 75, CPU `TC0P` 65 (i5-2500S Tcase 69.1), PECI `TCXc`
85, ODD `TO0P` 55, PSU heatsink `Tp2H` 90 (measured 65-83), drive 50 (WD Red WD20EFAX, spec
65; it already runs at 44-47 °C under SMC control, so 45 would trip constantly).

## Operation

```
make && sudo make install     # /usr/local/sbin/sofa-fand, /usr/local/etc/sofa-fand.conf,
                              # /Library/LaunchDaemons/de.sofa.fand.plist (KeepAlive)
sofa-fand status
syslog -k Sender sofa-fand | tail

# switch off
sudo launchctl unload -w /Library/LaunchDaemons/de.sofa.fand.plist
sudo /usr/local/sbin/sofa-fand reset      # or: ~/src/smcfan/smcfan force 0
```

To change the config: edit `sofa-fand.conf` in the repo, then `sudo make install` (it checks
the config and reloads the daemon).
