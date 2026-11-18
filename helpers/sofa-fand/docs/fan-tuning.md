# Fan tuning iMac12,2: findings

Living document, updated after every measurement block. The raw data is on the iMac under
`~/Library/Logs/fan-tuning-2026-11-17/` and is mirrored hourly to the raspi
(`/mnt/data/imac/logs/` → Koofr).

Machine: iMac12,2 (27", Mid 2011), i5-2500S, Radeon HD 6770M, OS X 10.9.5, SMC 1.72f2. Drive:
WD Red WD20EFAX (SMR, 5400 rpm) with an OWC in-line digital thermal sensor. Room 22-24 °C.

## Status 2026-11-18

- **Installed and running:** LaunchDaemon `de.sofa.fand`, binary `9705b918a1a8`, built from the
  daemon code of `cffe706`, which wires only its own binary. Config from `1dd0d82`, loaded
  2026-11-18 09:01. Self-check after loading:
  - crash canary: 10/10 clean, 0 "crashed" lines;
  - mode `curve`, level 0;
  - ODD fan steady at 500 rpm (actual 491-510), HDD and CPU fans off (drive 42 °C, Tp2H 55 °C);
  - no pumping.
- **Sofa:** Build 27 sends v1 hints, and they arrive.
- **Incident 2026-11-17 22:19-22:38:**
  - wiring all loaded images (shared-cache pages) plus an `mlockall` attempt coincided with a
    system-wide crash wave of new processes (NSFileManager creating new directories → jump to
    0x0 in CoreServicesInternal; kernel: "DYLD shared region unnest");
  - the reboot fixed it, and since `cffe706` only the daemon's own binary is wired;
  - dry run, installation and self-check each passed the crash canary (`tools/crashcheck.sh`, a
    new directory every 30 s) with 0 crashes.

## Fans

| fan | `F<n>ID` | Apple min | max | remarks |
|---|---|---|---|---|
| F0 | ODD | 1150 | 2500 | follows targets from 500 rpm; starts from 0 → 700 with a short kick |
| F1 | HDD | 1100 | 5500 | **ignores targets below ≈1280 rpm** (lowest PWM duty): it either runs ≥ ~1280 or stops (target 0). Even at Apple's target 1100 it turns ~1280. User by ear: the annoying fan |
| F2 | CPU | 940 | 2100 | follows from 500 rpm; starts from 0 → 500 |

Control: `F<n>Mn` = 0 is accepted but ignored (internal floor). Only the forced mode works:
`FS! ` (ui16 bitmask, bit n = fan n) + `F<n>Tg` (fpe2). `FS!` = 0 → SMC regulates again at
once.

## Sensors (all 332 SMC keys enumerated with `tools/smcenum`)

| key | meaning | typical (idle … playback) |
|---|---|---|
| TC0P / TC0H | CPU proximity / heatsink | 48 … 58 |
| TC0c…TC3c, TCXc | CPU cores, PECI (hottest) | 45 … 75 |
| TG0D / TG0H | GPU die / heatsink | 50 … 65 |
| TO0P | optical drive | 44 … 47 |
| Tp1P | power supply proximity | 58 … 64 |
| Tp2H | **power supply heatsink** | 65 … 85 (85 under Apple control during playback) |
| Tp3H | power supply 3 heatsink | 62 … 68 |
| TPCD | PCH die | 59 … 63 |
| Tm0P | memory | 53 … 57 |
| TL0P | LCD proximity (drops to ~22 with display off) | 41 … 47 |
| TS0P, TS2P | (skin?) | 38 … 45 |
| TA0P | ambient | 22 … 24 |
| TH0O / TH1O | constant 3.0 (probably status of the OWC drive sensor), **no drive temperature in the SMC** | |
| HDD | SMART attribute 194 via `IOATASMARTInterface`, in-process | 44 … 48 |

**SMART is exclusive:** while a process holds the SMART user client, `smartctl` fails. So it
is opened, read and closed every time (daemon and `fanlab`).

## Apple's thresholds (SMC keys)

Below these thresholds Apple runs every fan at its minimum. So "cooler than Apple" means more
than the minimum below Apple's fan-start threshold.

| keys | sensor | fan start F | warning W | throttle P | shutdown S |
|---|---|---|---|---|---|
| Sp2F/W/P/S | Tp2H | 96 | 98 | 103 | 108 |
| Sp1F/P/S | Tp1P | 79 | | 84 | 89 |
| Sp3F/P/S | Tp3H | 79 | | 84 | 89 |
| SL0F/W/P/S | TL0P | 58.4 | 60.4 | 66 | 68 |
| SS0F/W | TS0P | 50 | 52 | | |

Targets: GPU `SGTg` 77, `SGTT` 82; CPU `SCTg` 70, PECI `SCXC` 86; ODD `SOTg` 55 (`SOT0..4`
55/53/53/50/48); HDD `SHTg` 6 (meaning unknown).

Whether the S thresholds (shutdown) also take effect in forced mode cannot be read from the
keys; it was not provoked. They are hardware protection in the SMC firmware, independent of
the fan mode.

## Measurements 2026-11-17 (evening, supervised)

Forced one fan at a time, the others under SMC control; load = Sofa playback (engine + mpv,
CPU ≈ 150 %).

| fan | rpm | result |
|---|---|---|
| F0 ODD | 900 (4 min) | GPU 64 → 68, flattening |
| F0 ODD | 700 (4 min) | GPU → 73.5, still rising |
| F0 ODD | 500 | GPU 75 after 40 s → aborted |
| F2 CPU | 700 | stable |
| F2 CPU | 500 | CPU 51 → 54, Tp2H 76 → 82 |
| F2 CPU | 0 (4 min) | CPU 55 → 57.8 (settles), cores ~67, Tp2H 81-83 |
| F1 HDD | 900 / 600 | ignored (~1280) |
| F1 HDD | 0 (5 min, low load) | drive 46 → 47 |
| all | 0, idle | GPU +3 °C in 100 s, CPU and drive flat; then ffmpeg 260 % → GPU 75 after 7.5 min → aborted |

**GPU is the critical path** (~2 °C/min without airflow under load).

## Overnight series 2026-11-17 (aborted after block C)

The series (`tools/night.sh`, 37 steps) started at 21:00. It was stopped at 22:30 during step
5/37, during the crash incident (see README "No disk in the control loop": wiring shared-cache
pages). Usable from it: the Apple reference under CPU full load and the CPU fan step response.

| step (CPU 4 threads 100 %) | fans F0/F1/F2 | CPU | GPU | Tp2H | ODD | drive |
|---|---|---|---|---|---|---|
| Apple (SMC) | 1149/1287/938 (= minima) | 56 → 60 | 58 → 50 | 80 → 73 | 47 → 43 | 47 |
| baseline minima | 1150/1285/940 | 60 → 57 | 50 → 46.5 | 73 → 70 | 43 → 38 | 47 → 44 |
| CPU 1800 (20 min) | 1149/1345/1800 | 57 → 45 | 46 → 44 | 70 → **52** | 38 → 35 | 44 → 42 |

Apple stays at all minima even under full CPU load. Drift-corrected step response CPU fan
940 → 1800 (°C per 100 rpm, τ63): Tp2H −1.43 (6 min), TCXc −1.74 (2.7 min), Tp3H −1.49, TC0P −1.05
(5.5 min), Tp1P −0.93, Tm0P −0.81, TL0P −0.40, TPCD −0.36; GPU, ODD and drive ≈ 0.

Apple reference during real playback (2026-11-17 evening, 5 min): all fans at minimum, Tp2H
83.6 °C on average, max 84.9.

## Short series 2026-11-18 (`tools/short.sh`, `tools/short2.sh`)

Morning, room 17 → 21 °C, Sofa idle/resting, display on (`caffeinate -u`) during H1 and the
matrix. Cool-downs: all fans at max, no load. Limits: GPU 75, CPU 65, PECI 85, Tp2H 85, drive 50,
LCD 50. Raw data in `docs/data/2026-11-18/`, analysis `tools/ashort.py`.

### H1: all fans off (worst case for floor 0)

| sensor | H1a idle, display on, 15 min (cold start) | H1b + one core at 100 %, 10 min |
|---|---|---|
| GPU TG0D | 36 → 48.3 (+0.54 °C/min at the end) | 48.5 → 52.2 (+0.39) |
| PSU heatsink Tp2H | 38 → 57.1 (+0.75) | 57.3 → 70.2 (+1.23) |
| LCD TL0P | 12 → 24.8 (+0.60) | 25.1 → 33.1 (+0.98) |
| drive | 32 → 34.7 (+0.18) | 35 → 36.7 (+0.07) |
| CPU PECI TCXc | 34 → 42 | 45.5 → 74.8 (+2.1) |
| PCH TPCD | 45 → 53 | 53 → 58 |

No limit reached, but no equilibrium either: every sensor was still rising at the end. Tp2H is
the critical one. Idle with all fans off it climbs at about 0.75 °C/min. With one core spinning
(a hung kernel lock) it climbs at about 1.2 °C/min and would pass 85 °C after another ~12 min.
Apple's own fan start for Tp2H is 96, shutdown 108. **Assessment:** fans at 0 are safe while the
daemon runs, because the CPU fan starts at Tp2H 62 (rest profile 64). In the "daemon dead + disk
gone + one core spinning" case, Tp2H would go well above 85 within ~30 min. Whether the SMC's
shutdown threshold (108) still acts in forced mode cannot be read from the keys; it was not
provoked. The user decided on floor 0; this is the documented residual risk.

### Effect matrix (each fan alone at max, 2-core load, 6 min, vs the surrounding baselines)

°C per 100 rpm (negative = cools). 6 min is not equilibrium (τ63 of the PSU and CPU paths 3-6
min, of the drive > 15 min), so the values are lower bounds. For F2 the 20-min step from the
night (CPU full load, 940 → 1800) is listed in brackets.

| sensor | F0 ODD 1150→2500 | F1 HDD 1290→4900 | F2 CPU 1500→2100 (night 940→1800) |
|---|---|---|---|
| TC0P CPU proximity | −0.04 | −0.01 | −0.13 (−1.05) |
| TCXc CPU PECI | (+0.23, drift) | +0.03 | −0.58 (−1.74) |
| TC0c..3c cores | (drift) | ≈0 | −0.14..−0.61 |
| TG0D GPU die | **−0.19** | +0.03 | (+0.22 drift) (−0.01) |
| TG0H GPU heatsink | **−0.18** | +0.01 | (+0.16) (−0.01) |
| TO0P ODD | −0.01 | 0 | +0.06 (−0.13) |
| Tp1P PSU proximity | −0.09 | +0.01 | **−0.30 (−0.93)** |
| Tp2H PSU heatsink | +0.05 | +0.05 | **−0.72 (−1.43)** |
| Tp3H PSU 3 | +0.08 | +0.04 | **−0.42 (−1.49)** |
| TPCD PCH | **−0.21** | −0.06 | −0.03 (−0.36) |
| Tm0P RAM | −0.12 | 0 | −0.09 (−0.81) |
| TL0P LCD | −0.11 | 0 | −0.13 (−0.40) |
| TS0P / TS2P | −0.02 / −0.13 | **−0.07 / −0.08** | +0.12 / +0.10 |
| TA0P ambient | −0.15 | +0.04 | −0.26 (−0.24) |
| HDD drive | −0.04 | **−0.04** (−1.5 °C at max) | +0.17 (−0.03) |

Reading: **F2 CPU cools the CPU and the whole power supply** (the only fan that cools Tp2H).
**F0 ODD cools GPU, PCH, RAM and LCD.** **F1 HDD cools almost nothing measurably**, the drive
only weakly (−1.5 °C at 4900 rpm). The LCD is cooled about equally by ODD and CPU fan (−0.11 /
−0.13). With the CPU fan at max the drive went +3 °C within the step (drift plus less HDD-bay
airflow?). The HDD curve covers it (on at 49 °C, floor 1100 from 50). RAM: the CPU fan's effect
on Tm0P is uncertain (−0.81 under full load overnight, −0.09 in the short step), so the Tm0P
curves are cautious assumptions.

Apple reference under 2-core load at all minima: Tp2H rises without end (73 → 82 in 10 min, 85
after another 5 min); ODD max does not stop it (+5.6). With the CPU fan at 1500 Tp2H settles near
72.

### Cool-downs (all fans max, no load) = maximum cooling power

| sensor | rate in the first 2 min | τ (exp fit) | rest equilibrium |
|---|---|---|---|
| Tp2H | −3.1 … −3.9 °C/min | 270-400 s | 48-54 |
| TCXc PECI | −8 … −10 °C/min | 40-80 s | 39-40 |
| TC0P | −1.7 … −3.3 °C/min | ~6 min | ~30 |
| TG0D GPU | −1.3 … −1.5 °C/min | 110-140 s | 40-42 |
| TPCD | −1.5 … −2.0 °C/min | 280-360 s | ~41 |
| Tm0P | −1.4 … −2.8 °C/min | ~5 min | ~36 |

So after a load spike the PSU comes down by about 3-4 °C per minute at the very best.
Overshoot has to be prevented early (feed-forward, early curve start), not corrected later.
Manual phase 2026-11-18 08:05 (all max **under** 2-core load, only ~100 s): Tp2H flat
(+0.07 °C/min) around 78, CPU −0.5 °C/min. All-max roughly holds the 2-core load, but the phase
was too short for an equilibrium.

### SMART

Short self-test 2026-11-18 09:07: before 5 log entries and status "completed", during "in
progress, 80 % remaining", after "completed without error" and 6 entries. The new entry #1 has
LifeTime 2105 h (= Power_On_Hours; older entries show 0). Result: **completed without error**.
The long test did not run (the overnight series was stopped before block D).

## Sensor → fan → curve → limits

| sensor | meaning | fan(s) / curve (°C:rpm) | floor | warn / trip | source |
|---|---|---|---|---|---|
| TG0D | GPU die | F0 52:0 56:600 62:1150 68:1800 72:2500 | F0 ≥1150 from 67 | 72 / 80 | matrix F0 −0.19; Apple target 77 |
| TG0H | GPU heatsink | F0 50:0 … 70:2500 (backup of TG0D) | | 74 / 82 | matrix F0 −0.18; review N6 |
| TC0P | CPU proximity | F2 50:0 54:500 58:900 63:1500 67:2100 | F2 ≥940 from 62 | 65 / 72 | night F2 −1.05; Tcase 69.1, Apple 70 |
| TCXc | CPU PECI | F2 72:0 78:800 84:1500 88:2100 | | 85 / 92 | F2 −0.58..−1.74; Apple SCXC 86 |
| TC0c..3c | cores | (limits only, backup) | | 88 / 95 | review N6 |
| Tp2H | PSU heatsink | F2 62:0 65:600 70:1500 76:2000 80:2100 | F2 ≥940 from 70 | 85 / 92 | F2 −0.72..−1.43, F0/F1 ≈ 0; Apple 96/98/103/108 |
| Tp1P | PSU proximity | F2 56:0 62:900 68:1600 74:2100 | F2 ≥940 from 72 | 74 / 80 | F2 −0.30..−0.93; Apple 79/84/89 |
| Tp3H | PSU 3 heatsink | F2 62:0 68:900 74:1600 78:2100 | | 76 / 82 | F2 −0.42..−1.49; Apple 79/84/89 |
| TPCD | PCH die | F0 62:0 66:900 70:1600 74:2500 | F0 ≥1150 from 68 | 70 / 78 | F0 −0.21 |
| Tm0P | RAM | F0 56:0 62:1000 68:2000; F2 54:0 60:900 66:1800 | | 66 / 76 | F0 −0.12, F2 uncertain (assumption) |
| TO0P | optical drive | F0 44:0 48:800 52:1600 55:2500 | F0 ≥1150 from 50 | 52 / 58 | Apple SOTg 55 |
| TL0P | LCD | F0 46:0 50:800 54:1600 57:2500; F2 48:0 52:900 56:2100 | F0 ≥1150 from 52 | 54 / 58 | F0 −0.11, F2 −0.13; Apple 58.4/60.4/66/68 |
| TS0P | (skin, near drive) | F1 48.5:0 49:1100 51:2200 | | 48 / 52 | F1 −0.07; Apple SS0F 50 / SS0W 52 |
| HDD | drive (SMART 194) | F1 48.5:0 49:1100 52:2200 54:3500 (off ≤46, minon/minoff 15 min) | F1 ≥1100 from 50 | 49 / 53 | F1 −0.04; WD Red spec 65 |
| TA0P | ambient | monitored only | | 33 / 40 | its effect shows in every sensor |

Not used, deliberately: TC0H (CPU heatsink, duplicates TC0P/TCXc), TS2P (no Apple threshold,
follows TS0P), TL0V/TL1P/TL1V/TL2V and the other TL*/TS*V variants (duplicate LCD/skin
readings), lower-case `T..p`/`T..c` raw variants, TH0O/TH1O (constant 3.0). Ambient as a
curve offset: not used; with 17-24 °C measured, its effect already shows in every sensor, and
the data does not support an extra offset.

**Feed-forward** (`feedforward 4 3`): it stays at the draft values. The short series has no
load-step-with-fixed-fans test that isolates it. Physically it helps the Tp2H path (τ 4-6 min,
cooling at most ~3.5 °C/min). Evaluation open.

## Apple vs own curve

| situation | Apple (measured) | sofa-fand (curves) |
|---|---|---|
| idle, cool (Tp2H < 62, GPU < 52) | 1150 / ~1280 / 940 | 0 / 0 / 0 |
| idle, display on, GPU ~52 | minima | ODD 500, rest 0 (measured 09:01-09:06) |
| playback (Tp2H 81-85) | minima, Tp2H up to 85 | CPU fan 2000-2100 from Tp2H 76-80 → Tp2H aims at ~70-75 |
| 2 cores (Tp2H rising) | minima, Tp2H > 85 | CPU 1500 from Tp2H 70 (equilibrium ~72) |
| above Apple's own fan thresholds | ramps from 96 (Tp2H), 58.4 (LCD), 77 (GPU) | already at max before that; trip → all max |

## Open questions

- Feed-forward benefit (needs load steps with fixed fans).
- Long SMART test.
- Equilibrium with all fans off (H1) beyond 15 min, the GPU activity counter under GPU load.
