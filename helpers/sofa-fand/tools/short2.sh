#!/bin/bash
# short2.sh COMMIT - second part of the short series (2026-11-18): HDD-max re-measurement,
# SMART short self-test result, sofa-fand dry run + install. Run as root, detached:
#   sudo nohup /Users/imac/src/smcfan/short2.sh <commit> >/dev/null 2>&1 &
# 1 crash check baseline, 2 H1 (all fans off idle / + 1 core), 3 effect matrix (each fan alone
# at max under 2-core load), 4 SMART short self-test, 5 sofa-fand dry run with crash check, then
# install + load + self-checks. FS!=0 at the end (trap) unless sofa-fand took over in step 5.
set -u
D=/Users/imac/Library/Logs/fan-tuning-2026-11-18; mkdir -p $D; chown imac $D
S=/Users/imac/src/smcfan; L=$S/fanlab; SMC=$S/smcfan
W=/Users/imac/src/sofa-fand-wt/helpers/sofa-fand
PL=/Library/LaunchDaemons/de.sofa.fand.plist; PLD=/Library/LaunchDaemons.disabled/de.sofa.fand.plist
export LIVE=$D/live.log CSV=$D/short.csv HB=$D/.hb
export LIM_GPU=75 LIM_CPU=65 LIM_PECI=85 LIM_PSU=85 LIM_HDD=50 LIM_LCD=50 LIM_CORE=90 LIM_ODD=55
COMMIT=${1:-}
TAKEN=0; CAFF=""; BURN=""
log() { echo "$(date +%T) $*" >> $LIVE; chown imac $LIVE 2>/dev/null; }
stop_burn() { [ -n "$BURN" ] && kill $BURN 2>/dev/null; BURN=""; pkill -f "fanlab burn" 2>/dev/null; }
burn() { stop_burn; nice -n 15 $L burn "$1" 100 86400 & BURN=$!; }
display_on() { [ -n "$CAFF" ] && return; sudo -u imac caffeinate -u -t 7200 & CAFF=$!; log "Bildschirm an (caffeinate -u)"; }
display_off() { [ -z "$CAFF" ] && return; kill $CAFF 2>/dev/null; CAFF=""; pmset displaysleepnow; log "Bildschirm aus"; }
crash() { NSFM=$S/nsfm sudo -u imac -E $S/crashcheck.sh "$1" "$2" >> $D/crashcheck.log 2>&1; }
finish() {
  stop_burn; display_off; pkill -f "sofa-fand run -n" 2>/dev/null
  if [ $TAKEN = 0 ]; then $SMC force 0 >/dev/null; log "Ende: FS!=$($SMC read 'FS! ' | awk '{print $NF}') (SMC regelt)"
  else log "Ende: sofa-fand regelt"; fi
  touch $D/.done; chown imac $D/* 2>/dev/null
}
abort_install() {
  log "FEHLER: $* → sofa-fand entladen, plist deaktiviert, FS!=0"
  launchctl unload $PL 2>/dev/null; mkdir -p /Library/LaunchDaemons.disabled
  [ -e $PL ] && mv $PL $PLD
  /usr/local/sbin/sofa-fand reset >/dev/null 2>&1 || $SMC force 0 >/dev/null
  TAKEN=0
}
trap 'log "ABBRUCH (Signal)"; finish; exit 1' INT TERM HUP
rm -f $D/.done; touch $HB
$L watchdog $HB 240 $D/.done >/dev/null 2>&1 &
step() { touch $HB; TEST="$1" LOADLBL="$2" MINEQ=0 $L step "$3" "$4" "$5" "$6"; local rc=$?; $SMC force 0 >/dev/null; return $rc; }
cool() { stop_burn; touch $HB; STOP_TP2H=55 STOP_GPU=45 TEST="$1" LOADLBL="ohne Last, alle Lüfter max" MINEQ=0 $L step 240 2500 5500 2100; $SMC force 0 >/dev/null; }
hot() { local b; b=$($SMC read Tp2H | awk '{print $5}'); [ -z "$b" ] && return 0; [ $((16#$b)) -gt 70 ]; }   # Tp2H > 70 C (sp78 high byte)
rec() { touch $HB; TEST="$1" LOADLBL="$2" MINEQ=0 $L rec "$3"; }

log "=== Kurzserie Teil 2 (Commit $COMMIT): HDD-Max neu, SMART, sofa-fand ==="
# 3b HDD fan alone at max, measured again: in part 1 the power-supply heatsink ran into its
# limit under 2-core load at Apple minimum. Same load, but the baseline holds the CPU fan at
# 1500 (it cools Tp2H), so the HDD step starts from a steady, cooler state. Part 1 was stopped
# before its CPU-max step, so that step follows here (1500 -> 2100).
display_on
log "Schritt 3b: HDD-Max und CPU-Max neu, unter 2 Kernen Last mit CPU-Lüfter-Basis 1500; Abkühlen jeweils mit allen Lüftern auf Max ohne Last (bis Tp2H<55 und GPU<45, max 4 min)"
cool "M2-Abkühlen"
burn 2
step "M2-Basis" "2 Kerne, CPU 1500" 360 1150 1100 1500
step "M2-HDD-max" "2 Kerne, CPU 1500" 360 1150 5500 1500
step "M2-Basis2" "2 Kerne, CPU 1500" 240 1150 1100 1500
if hot; then cool "M2-Abkühlen2"; burn 2; step "M2-Basis2b" "2 Kerne, CPU 1500" 240 1150 1100 1500; fi
step "M2-CPU-max" "2 Kerne" 360 1150 1100 2100
step "M2-Basis3" "2 Kerne, CPU 1500" 240 1150 1100 1500
stop_burn; display_off
log "Schritt 3b: fertig"
# 4 SMART short self-test (part 1 never started it): start it unless one is running, read result
log "Schritt 4/6: SMART-Kurztest auslesen"
/opt/local/sbin/smartctl -l selftest disk0 > $D/smart-short.txt 2>&1
if ! grep -q "^# 1  Short offline" $D/smart-short.txt; then
  if /opt/local/sbin/smartctl -c disk0 | grep -A1 "Self-test execution status" | grep -q "in progress"; then
    log "Schritt 4/6: es läuft bereits ein Selbsttest – warte"; fi
  for i in $(seq 1 60); do /opt/local/sbin/smartctl -c disk0 | grep -A1 "Self-test execution status" | grep -q "in progress" || break; touch $HB; sleep 10; done
  /opt/local/sbin/smartctl -t short disk0 >> $D/smart-short.txt 2>&1
  for i in $(seq 1 18); do touch $HB; sleep 10; done
  /opt/local/sbin/smartctl -l selftest disk0 >> $D/smart-short.txt 2>&1
fi
log "Schritt 4/6: $(grep -m1 -E '^# 1' $D/smart-short.txt | cut -c1-90)"

# 5 sofa-fand: dry run + crash check, then install + load + checks
log "Schritt 5/6: sofa-fand Trockenlauf 10 min mit crashcheck"
c=$(git -C $W rev-parse --short HEAD)
if [ -z "$COMMIT" ] || [ "$c" != "$COMMIT" ] || ! git -C $W diff --quiet HEAD -- .; then
  log "Schritt 5/6: Worktree steht auf $c statt $COMMIT oder hat Änderungen – nichts installiert"; finish; exit 1
fi
( cd $W && make sofa-fand >> $D/install.log 2>&1 ) || { log "Schritt 5/6: Build fehlgeschlagen"; finish; exit 1; }
$SMC force 0 >/dev/null
$W/sofa-fand run -n -c $W/sofa-fand.conf >/dev/null 2>&1 &
sleep 5
ok=1; for i in 1 2 3 4 5; do touch $HB; crash 120 "Trockenlauf" || { ok=0; break; }; done
pkill -f "sofa-fand run -n"; sleep 2
if [ $ok = 0 ]; then log "Schritt 5/6: ABSTURZ im Trockenlauf – nichts installiert"; finish; exit 1; fi
log "Schritt 5/6: Trockenlauf sauber, installiere $COMMIT"
rm -f $PLD
( cd $W && make install-files >> $D/install.log 2>&1 ) || { log "Schritt 5/6: install-files fehlgeschlagen"; finish; exit 1; }
log "Schritt 5/6: $(tail -1 $D/install.log)"
launchctl load -w $PL || { abort_install "launchctl load"; finish; exit 1; }
TAKEN=1; sleep 30
check() {
  local st; st=$(/usr/local/sbin/sofa-fand status 2>&1) || { abort_install "status nicht erreichbar"; return 1; }
  [ $(pgrep -f "sbin/sofa-fand run" | wc -l) -ge 2 ] || { abort_install "Wächter/Regler laufen nicht"; return 1; }
  local m; m=$(echo "$st" | awk '/^mode/{print $2}')
  case $m in trip|disabled) abort_install "$(echo "$st" | head -1)"; return 1;; esac
  local bad; bad=$(echo "$st" | awk '/^fan /{a=$5; t=$7; if (t>0 && a<t/2) printf " F%s(ist %s soll %s)", $2, a, t}')
  [ -n "$bad" ] && { abort_install "Lüfter folgen nicht:$bad"; return 1; }
  log "Schritt 5/6 $1: $(echo "$st" | head -1); $(echo "$st" | awk '/^fan /{printf "%s %s/%s  ", $3, $5, $7}'); $(echo "$st" | grep ^hints_received)"
}
check "nach 30 s" || { finish; exit 1; }
touch $HB; crash 150 "Daemon" || { abort_install "Absturz mit geladenem Daemon"; finish; exit 1; }
touch $HB; crash 150 "Daemon" || { abort_install "Absturz mit geladenem Daemon"; finish; exit 1; }
check "nach 5 min" || { finish; exit 1; }
log "Schritt 5/6: sofa-fand installiert, geladen, sauber"
finish
