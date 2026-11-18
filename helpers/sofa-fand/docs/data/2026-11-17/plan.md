# Lüfter-Messreihe über Nacht (iMac12,2), Stand 2026-11-17 22:20:37

Grenzen (Abbruch → FS!=0): GPU 75, CPU 68 (Kerne 90), Platte 50, ODD 55, Netzteil Tp2H 85 °C.
Last: 4:100 = 4 Threads Volllast (nice 15), 4:35 = 4 Threads 35 % (wiedergabe-ähnlich), smart = SMART-Langtest.
Zwang 'a' = SMC regelt diesen Lüfter. Dauer = Höchstdauer, Stopp früher bei Gleichgewicht.
Störquellen: ytdl-sub 04:00, Sofa-Feeds (in night.csv an cpu_pct/gpu_pm4 erkennbar).

| # | Block | Last | F0 ODD | F1 HDD | F2 CPU | max min | Ziel | Status |
|---|---|---|---|---|---|---|---|---|
| 1/37 | C Volllast | 4:100 | a | a | a | 15 | Apple-Referenz unter CPU-Volllast (SMC regelt) | erledigt |
| 2/37 | C Volllast | 4:100 | 1150 | 1100 | 940 | 25 | Basis: alle auf Apple-Minimum | erledigt |
| 3/37 | C Volllast | 4:100 | 1150 | 1100 | 1800 | 20 | Sprung CPU-Lüfter 940→1800 | erledigt |
| 4/37 | C Volllast | 4:100 | 1150 | 1100 | 940 | 20 | zurück auf Basis | erledigt |
| 5/37 | C Volllast | 4:100 | 2000 | 1100 | 940 | 20 | Sprung ODD-Lüfter 1150→2000 | läuft |
| 6/37 | C Volllast | 4:100 | 1150 | 1100 | 940 | 20 | zurück auf Basis | offen |
| 7/37 | C Volllast | 4:100 | 1150 | 2500 | 940 | 20 | Sprung HDD-Lüfter 1280→2500 | offen |
| 8/37 | C Volllast | 4:100 | 1150 | 1100 | 940 | 20 | zurück auf Basis | offen |
| 9/37 | B Wiedergabe-ähnlich | 4:35 | a | a | a | 10 | Apple-Referenz bei wiedergabe-ähnlicher Last | offen |
| 10/37 | B Wiedergabe-ähnlich | 4:35 | 1150 | 1100 | 940 | 25 | Basis | offen |
| 11/37 | B Wiedergabe-ähnlich | 4:35 | 1150 | 1100 | 1800 | 20 | Sprung CPU-Lüfter 940→1800 | offen |
| 12/37 | B Wiedergabe-ähnlich | 4:35 | 1150 | 1100 | 940 | 20 | zurück auf Basis | offen |
| 13/37 | B Wiedergabe-ähnlich | 4:35 | 2000 | 1100 | 940 | 20 | Sprung ODD-Lüfter 1150→2000 | offen |
| 14/37 | B Wiedergabe-ähnlich | 4:35 | 1150 | 1100 | 940 | 20 | zurück auf Basis | offen |
| 15/37 | B Wiedergabe-ähnlich | 4:35 | 1150 | 2500 | 940 | 20 | Sprung HDD-Lüfter 1280→2500 | offen |
| 16/37 | B Wiedergabe-ähnlich | 4:35 | 1150 | 1100 | 940 | 20 | zurück auf Basis | offen |
| 17/37 | B Wiedergabe-ähnlich | 4:35 | 1600 | 0 | 1400 | 30 | HDD-Lüfter aus, ODD/CPU höher: reichen sie für Platte+Netzteil? | offen |
| 18/37 | B Wiedergabe-ähnlich | 4:35 | 0 | 1100 | 0 | 15 | ODD+CPU aus, HDD Minimum (bis Grenze) | offen |
| 19/37 | A Leerlauf | 0 | a | a | a | 15 | Abkühlen unter SMC + Apple-Referenz Leerlauf | offen |
| 20/37 | A Leerlauf | 0 | 1150 | 1100 | 940 | 25 | Basis | offen |
| 21/37 | A Leerlauf | 0 | 1150 | 1100 | 1800 | 20 | Sprung CPU-Lüfter 940→1800 | offen |
| 22/37 | A Leerlauf | 0 | 1150 | 1100 | 940 | 20 | zurück auf Basis | offen |
| 23/37 | A Leerlauf | 0 | 2000 | 1100 | 940 | 20 | Sprung ODD-Lüfter 1150→2000 | offen |
| 24/37 | A Leerlauf | 0 | 1150 | 1100 | 940 | 20 | zurück auf Basis | offen |
| 25/37 | A Leerlauf | 0 | 1150 | 2500 | 940 | 20 | Sprung HDD-Lüfter 1280→2500 | offen |
| 26/37 | A Leerlauf | 0 | 1150 | 1100 | 940 | 20 | zurück auf Basis | offen |
| 27/37 | A Leerlauf | 0 | 1150 | 0 | 940 | 45 | HDD-Lüfter aus (Rest Minimum): wie lange halten Platte/Netzteil? | offen |
| 28/37 | A Leerlauf | 0 | 1300 | 0 | 1100 | 30 | HDD-Lüfter aus, ODD/CPU leicht erhöht | offen |
| 29/37 | A Leerlauf | 0 | 0 | 0 | 0 | 40 | alle aus (Leerlauf) bis Gleichgewicht/Grenze | offen |
| 30/37 | A Leerlauf | 0 | 700 | 0 | 500 | 30 | leise Stufe: ODD 700, CPU 500, HDD aus | offen |
| 31/37 | D Plattenlast | smart | a | a | a | 10 | SMART-Langtest gestartet, SMC regelt | offen |
| 32/37 | D Plattenlast | smart | 1150 | 1100 | 940 | 25 | Basis bei Plattenlast | offen |
| 33/37 | D Plattenlast | smart | 1150 | 0 | 940 | 40 | HDD-Lüfter aus bei Plattenlast (Grenze 50) | offen |
| 34/37 | D Plattenlast | smart | 1150 | 1100 | 940 | 25 | HDD-Lüfter Minimum bei Plattenlast | offen |
| 35/37 | D Plattenlast | smart | 1150 | 2500 | 940 | 20 | HDD-Lüfter 2500 bei Plattenlast | offen |
| 36/37 | D Plattenlast | smart | 1600 | 0 | 1400 | 30 | HDD aus, ODD/CPU höher bei Plattenlast | offen |
| 37/37 | E Ende | 0 | a | a | a | 10 | Abschluss unter SMC | offen |

Geschätzte Restdauer (Obergrenze): 725 min
