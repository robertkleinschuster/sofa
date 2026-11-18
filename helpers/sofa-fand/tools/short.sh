#!/bin/bash
# short.sh COMMIT - short fan test series (~90 min), run as root, detached:
#   sudo nohup /Users/imac/src/smcfan/short.sh <commit> >/dev/null 2>&1 &
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
rec() { touch $HB; TEST="$1" LOADLBL="$2" MINEQ=0 $L rec "$3"; }

log "=== Kurzserie startet (Commit $COMMIT) ==="
# 1 baseline crash check
log "Schritt 1/6: crashcheck Basis 3 min"
if ! crash 180 "Basis"; then log "Schritt 1/6: ABSTURZ in der Basis – Serie beendet"; finish; exit 1; fi
log "Schritt 1/6: sauber"

# 2 H1
display_on; stop_burn
log "Schritt 2/6: H1a alle Lüfter aus, Leerlauf, Bildschirm an (max 15 min)"
step "H1a" "Leerlauf, Bildschirm an" 900 0 0 0; rc=$?
[ $rc = 3 ] && { log "H1a an Grenze – 3 min Abkühlen unter SMC"; rec "H1a-Abkühlen" "Leerlauf" 180; }
burn 1
log "Schritt 2/6: H1b alle aus + 1 Kern 100 % (max 10 min)"
step "H1b" "1 Kern 100 %, Bildschirm an" 600 0 0 0
stop_burn
rec "H1-Abkühlen" "Leerlauf" 180
log "Schritt 2/6: fertig"

# 3 effect matrix under 2-core load
burn 2
log "Schritt 3/6: Matrix unter 2 Kernen Last: Basis 5 min, dann je Lüfter allein auf Max 6 min + 4 min Basis"
step "M-Basis" "2 Kerne" 300 1150 1100 940
step "M-ODD-max" "2 Kerne" 360 2500 1100 940
step "M-Basis2" "2 Kerne" 240 1150 1100 940
step "M-HDD-max" "2 Kerne" 360 1150 5500 940
step "M-Basis3" "2 Kerne" 240 1150 1100 940
step "M-CPU-max" "2 Kerne" 360 1150 1100 2100
step "M-Basis4" "2 Kerne" 240 1150 1100 940
stop_burn; display_off
log "Schritt 3/6: fertig"

# 4 SMART short self-test (no fanlab running: the SMART client is exclusive)
log "Schritt 4/6: SMART-Kurztest"
/opt/local/sbin/smartctl -t short disk0 > $D/smart-short.txt 2>&1
for i in $(seq 1 18); do touch $HB; sleep 10; done
/opt/local/sbin/smartctl -l selftest disk0 >> $D/smart-short.txt 2>&1
log "Schritt 4/6: $(grep -m1 -E '^# 1' $D/smart-short.txt | cut -c1-80)"

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
