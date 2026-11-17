# Fan tuning iMac12,2: findings

Living document, updated after every measurement block. The raw data is on the iMac under
`~/Library/Logs/fan-tuning-2026-11-17/` and is mirrored hourly to the raspi
(`/mnt/data/imac/logs/` → Koofr).

Machine: iMac12,2 (27", Mid 2011), i5-2500S, Radeon HD 6770M, OS X 10.9.5, SMC 1.72f2. Drive:
WD Red WD20EFAX (SMR, 5400 rpm) with an OWC in-line digital thermal sensor. Room 22-24 °C.

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

## Overnight series 2026-11-17/18 (running)

37 steps (`tools/night.sh`): C CPU full load (4 threads, nice 15), B playback-like load
(4×35 %), A idle, D disk load (SMART long test). Each block starts with SMC-only, then a
baseline at all Apple minima, then single-fan step responses up (CPU 940 → 1800, ODD 1150 →
2000, HDD → 2500) with returns to baseline, then the HDD fan off, all fans off, and quiet
levels. Limits: GPU 75, CPU 68 (cores 90), drive 50, ODD 55, Tp2H 85.

Note: overnight the display is off (LCD ~22 °C, GPU cooler), so idle values are lower than in
the menu with the screen on.

### Block C (CPU full load 400 %)

| step | fans F0/F1/F2 | CPU | GPU | Tp2H | ODD | drive |
|---|---|---|---|---|---|---|
| 1 SMC (Apple) | 1149/1287/938 (= minima) | 56 → 60 | 58 → 50 | 80 → 73 | 47 → 43 | 47 |
| 2 baseline minima | 1150/1285/940 | 60 → 57 | 50 → 46.5 | 73 → 70 | 43 → 38 | 47 → 44 |
| 3 CPU 1800 | 1149/1345/1800 | 57 → 45 | 46 → 44 | 70 → **52** | 38 → 35 | 44 → 42 |

Apple stays at all minima even under full CPU load (no sensor near its threshold).

**The CPU fan cools the power supply:** 940 → 1800 rpm, drift-corrected −1.4 °C per 100 rpm on
Tp2H (τ63 ≈ 6 min), −1.05 °C/100 rpm on TC0P (τ ≈ 5.5 min), −1.7 on TCXc, −0.9 on Tp1P/Tp3H.
GPU and drive barely react to the CPU fan.

The fan × sensor matrix follows after the series.

## Open questions

- F0 coupling to GPU/LCD/ODD, and F1 coupling to drive/PSU, quantified (overnight).
- How long drive and PSU manage without F1 at idle and under disk load (blocks A/D).
- Idle equilibrium with all fans off (H1 evaluation: does a hung machine with fans at 0 stay
  safe?).
- Is the GPU activity counter (`HWChannel PM4 | Commands Completed`) monotonic under GPU load
  (overnight it is 0 with the display off)?
