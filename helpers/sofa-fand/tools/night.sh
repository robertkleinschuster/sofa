#!/bin/bash
# Unattended overnight fan measurement series (iMac12,2). Run as root, detached:
#   sudo nohup /Users/imac/src/smcfan/night.sh >/dev/null 2>&1 &
# Every step goes through fanlab (limits, FS!=0 on every exit). A separate fanlab watchdog
# resets FS!=0 if this script shows no heartbeat for 180 s. At the end: FS!=0 and a final note.
set -u
D=/Users/imac/Library/Logs/fan-tuning-2026-11-17
L=/Users/imac/src/smcfan/fanlab
LIVE=$D/live.log; PLAN=$D/plan.md; CSV=$D/night.csv; HB=$D/.hb; DONE=$D/.done
export LIVE CSV HB
rm -f "$DONE"; touch "$HB"; chown imac "$D" 2>/dev/null
log() { echo "$(date +%T) $*" >> "$LIVE"; }
reset_fans() { /Users/imac/src/smcfan/smcfan force 0 >/dev/null 2>&1; }
BURN=""
stop_burn() { [ -n "$BURN" ] && kill "$BURN" 2>/dev/null; BURN=""; pkill -f "fanlab burn" 2>/dev/null; }
start_burn() { stop_burn; [ "$1" = 0 ] && return; nice -n 15 "$L" burn "$1" "$2" 86400 & BURN=$!; }
finish() { stop_burn; reset_fans; touch "$DONE"; log "Ende der Messreihe, FS!=$(/Users/imac/src/smcfan/smcfan read 'FS! ' | cut -d: -f2)"; chown imac "$D"/* 2>/dev/null; }
trap 'log "ABBRUCH der Messreihe (Signal)"; finish; exit 1' INT TERM HUP

# watchdog (independent process)
"$L" watchdog "$HB" 180 "$DONE" >/dev/null 2>&1 &

# test table: id|block|load(threads:pct or 0 or smart)|mode|F0|F1|F2|max_s|mineq_s|goal
T=(
"1|C Volllast|4:100|rec|a|a|a|900|0|Apple-Referenz unter CPU-Volllast (SMC regelt)"
"2|C Volllast|4:100|step|1150|1100|940|1500|600|Basis: alle auf Apple-Minimum"
"3|C Volllast|4:100|step|1150|1100|1800|1200|480|Sprung CPU-Lüfter 940→1800"
"4|C Volllast|4:100|step|1150|1100|940|1200|480|zurück auf Basis"
"5|C Volllast|4:100|step|2000|1100|940|1200|480|Sprung ODD-Lüfter 1150→2000"
"6|C Volllast|4:100|step|1150|1100|940|1200|480|zurück auf Basis"
"7|C Volllast|4:100|step|1150|2500|940|1200|480|Sprung HDD-Lüfter 1280→2500"
"8|C Volllast|4:100|step|1150|1100|940|1200|480|zurück auf Basis"
"9|B Wiedergabe-ähnlich|4:35|rec|a|a|a|600|0|Apple-Referenz bei wiedergabe-ähnlicher Last"
"10|B Wiedergabe-ähnlich|4:35|step|1150|1100|940|1500|600|Basis"
"11|B Wiedergabe-ähnlich|4:35|step|1150|1100|1800|1200|480|Sprung CPU-Lüfter 940→1800"
"12|B Wiedergabe-ähnlich|4:35|step|1150|1100|940|1200|480|zurück auf Basis"
"13|B Wiedergabe-ähnlich|4:35|step|2000|1100|940|1200|480|Sprung ODD-Lüfter 1150→2000"
"14|B Wiedergabe-ähnlich|4:35|step|1150|1100|940|1200|480|zurück auf Basis"
"15|B Wiedergabe-ähnlich|4:35|step|1150|2500|940|1200|480|Sprung HDD-Lüfter 1280→2500"
"16|B Wiedergabe-ähnlich|4:35|step|1150|1100|940|1200|480|zurück auf Basis"
"17|B Wiedergabe-ähnlich|4:35|step|1600|0|1400|1800|900|HDD-Lüfter aus, ODD/CPU höher: reichen sie für Platte+Netzteil?"
"18|B Wiedergabe-ähnlich|4:35|step|0|1100|0|900|0|ODD+CPU aus, HDD Minimum (bis Grenze)"
"19|A Leerlauf|0|rec|a|a|a|900|0|Abkühlen unter SMC + Apple-Referenz Leerlauf"
"20|A Leerlauf|0|step|1150|1100|940|1500|600|Basis"
"21|A Leerlauf|0|step|1150|1100|1800|1200|480|Sprung CPU-Lüfter 940→1800"
"22|A Leerlauf|0|step|1150|1100|940|1200|480|zurück auf Basis"
"23|A Leerlauf|0|step|2000|1100|940|1200|480|Sprung ODD-Lüfter 1150→2000"
"24|A Leerlauf|0|step|1150|1100|940|1200|480|zurück auf Basis"
"25|A Leerlauf|0|step|1150|2500|940|1200|480|Sprung HDD-Lüfter 1280→2500"
"26|A Leerlauf|0|step|1150|1100|940|1200|480|zurück auf Basis"
"27|A Leerlauf|0|step|1150|0|940|2700|1200|HDD-Lüfter aus (Rest Minimum): wie lange halten Platte/Netzteil?"
"28|A Leerlauf|0|step|1300|0|1100|1800|900|HDD-Lüfter aus, ODD/CPU leicht erhöht"
"29|A Leerlauf|0|step|0|0|0|2400|1200|alle aus (Leerlauf) bis Gleichgewicht/Grenze"
"30|A Leerlauf|0|step|700|0|500|1800|900|leise Stufe: ODD 700, CPU 500, HDD aus"
"31|D Plattenlast|smart|rec|a|a|a|600|0|SMART-Langtest gestartet, SMC regelt"
"32|D Plattenlast|smart|step|1150|1100|940|1500|600|Basis bei Plattenlast"
"33|D Plattenlast|smart|step|1150|0|940|2400|1200|HDD-Lüfter aus bei Plattenlast (Grenze 50)"
"34|D Plattenlast|smart|step|1150|1100|940|1500|600|HDD-Lüfter Minimum bei Plattenlast"
"35|D Plattenlast|smart|step|1150|2500|940|1200|600|HDD-Lüfter 2500 bei Plattenlast"
"36|D Plattenlast|smart|step|1600|0|1400|1800|900|HDD aus, ODD/CPU höher bei Plattenlast"
"37|E Ende|0|rec|a|a|a|600|0|Abschluss unter SMC"
)
N=${#T[@]}
declare -a ST
for ((i=0;i<N;i++)); do ST[$i]="offen"; done

write_plan() {
  local rest=0 i id blk ld md f0 f1 f2 mx mq goal
  for ((i=0;i<N;i++)); do IFS='|' read -r id blk ld md f0 f1 f2 mx mq goal <<< "${T[$i]}"; [ "${ST[$i]}" = "offen" ] && rest=$((rest+mx)); done
  {
    echo "# Lüfter-Messreihe über Nacht (iMac12,2), Stand $(date '+%F %T')"
    echo
    echo "Grenzen (Abbruch → FS!=0): GPU 75, CPU 68 (Kerne 90), Platte 50, ODD 55, Netzteil Tp2H 85 °C."
    echo "Last: 4:100 = 4 Threads Volllast (nice 15), 4:35 = 4 Threads 35 % (wiedergabe-ähnlich), smart = SMART-Langtest."
    echo "Zwang 'a' = SMC regelt diesen Lüfter. Dauer = Höchstdauer, Stopp früher bei Gleichgewicht."
    echo "Störquellen: ytdl-sub 04:00, Sofa-Feeds (in night.csv an cpu_pct/gpu_pm4 erkennbar)."
    echo
    echo "| # | Block | Last | F0 ODD | F1 HDD | F2 CPU | max min | Ziel | Status |"
    echo "|---|---|---|---|---|---|---|---|---|"
    for ((i=0;i<N;i++)); do IFS='|' read -r id blk ld md f0 f1 f2 mx mq goal <<< "${T[$i]}"
      echo "| $id/$N | $blk | $ld | $f0 | $f1 | $f2 | $((mx/60)) | $goal | ${ST[$i]} |"; done
    echo
    echo "Geschätzte Restdauer (Obergrenze): $((rest/60)) min"
  } > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
  chown imac "$PLAN" "$LIVE" 2>/dev/null
}

log "Messreihe startet: $N Tests, Plan in plan.md, Wächter aktiv (180 s)"
SMART_STARTED=0; BURN_LD=""
for ((i=0;i<N;i++)); do
  IFS='|' read -r id blk ld md f0 f1 f2 mx mq goal <<< "${T[$i]}"
  touch "$HB"
  if [ "$ld" = smart ]; then
    stop_burn
    if [ $SMART_STARTED = 0 ]; then /opt/local/sbin/smartctl -t long disk0 >> "$D/smart-selftest.txt" 2>&1; SMART_STARTED=1; log "Test $id/$N: SMART-Langtest gestartet (ca. 150 min)"; fi
    lbl="Plattenlast (SMART-Langtest)"
  elif [ "$ld" = 0 ]; then stop_burn; lbl="Leerlauf (keine Zusatzlast)"
  else
    th=${ld%%:*}; pc=${ld##*:}; lbl="CPU $th Threads ${pc}%"
    case "$BURN_LD" in "$ld") ;; *) start_burn "$th" "$pc";; esac 2>/dev/null
  fi
  BURN_LD=$ld
  ST[$i]="läuft"; write_plan
  export TEST="Test $id/$N" LOADLBL="$lbl" MINEQ=$mq
  if [ "$md" = rec ]; then "$L" rec "$mx"; rc=$?
  else "$L" step "$mx" "$f0" "$f1" "$f2"; rc=$?; fi
  reset_fans
  case $rc in 0) ST[$i]="erledigt";; 3) ST[$i]="erledigt (Abbruch an Grenze)";; *) ST[$i]="Fehler rc=$rc";; esac
  write_plan
  # after an abort: cool down under SMC before the next forced step
  if [ $rc = 3 ]; then log "Test $id/$N: Abkühlen unter SMC (5 min)"; MINEQ=0 TEST="Test $id/$N Abkühlen" "$L" rec 300; fi
done
stop_burn
/opt/local/sbin/smartctl -l selftest disk0 >> "$D/smart-selftest.txt" 2>&1
finish
