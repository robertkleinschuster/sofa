#!/bin/bash
# ident.sh STEP_S [BLOCKS] - fan/load identification series for the self-optimisation (#2).
# sofa-fanlearn records everything; this script only sets the conditions and writes a phase list.
# Run as root, detached:  sudo nohup /Users/imac/src/smcfan/ident.sh 900 >/dev/null 2>&1 &
# Blocks (display, load): 1 off/idle  2 on/idle  L on/idle brightness 100/50/10 %  3 on/2 cores
#   4 off/4 cores. Fan blocks: 5 steps base (ODD 1000, HDD 0, CPU 1000) - ODD 2500 - CPU 2100 -
#   HDD 2500 - low (ODD 500, CPU 500). Display on = brightness held at 50 % (the ambient-light
#   automatic is overridden every 5 s); the original brightness is restored at the end.
# Between blocks, when warm (or unreadable): cool-down with all fans at max and no load (user rule).
# A temperature limit in a step (fanlab rc 3) ends that block; any other failure ends the series.
# Sofa starting playback ends the series within ~5 s: its context datagrams are received by
# ctxlisten.py while sofa-fand is unloaded; a dead listener also ends the series.
# At the end (also on abort, signal, unexpected exit) the fans go back to sofa-fand.
# If this script is SIGKILLed: fanlab resets FS! after its step; recovery = touch $D/.done (stops
# the watchdog), kill leftovers (fanlab burn, caffeinate, bright hold, ctxlisten), then
# launchctl load -w /Library/LaunchDaemons/de.sofa.fand.plist
set -u
STEP=${1:-1200}; BLOCKS=${2:-12L34}
D=/Users/imac/Library/Logs/fan-ident-$(date +%Y-%m-%d); mkdir -p $D; chown imac $D
S=/Users/imac/src/smcfan; L=$S/fanlab; SMC=$S/smcfan
PL=/Library/LaunchDaemons/de.sofa.fand.plist; HS=/var/run/sofa-fand/hint.sock
R=/var/run/sofa-fand-ident; mkdir -p $R; chmod 700 $R          # root-only: context file
export LIVE=$D/live.log CSV=$D/fanlab.csv HB=$D/.hb
export LIM_GPU=75 LIM_CPU=68 LIM_PECI=88 LIM_PSU=85 LIM_HDD=50 LIM_LCD=50 LIM_CORE=92 LIM_ODD=55
PH=$D/phases.csv; CTX=$R/ctx; DONE=$D/.done
CAFF=""; BURN=""; LIS=""; BH=""; FL=""; UNLOADED=0
BR0=$(sudo -u imac $S/bright get 2>/dev/null)
log() { echo "$(date +%T) $*" >> $LIVE; chown imac $LIVE 2>/dev/null; }
stop_burn() { [ -n "$BURN" ] && kill $BURN 2>/dev/null; BURN=""; pkill -f "fanlab burn" 2>/dev/null; return 0; }
burn() { stop_burn; [ "$1" -gt 0 ] && { nice -n 15 $L burn "$1" 100 $((STEP * 5 + 1200)) & BURN=$!; }; return 0; }
bright() { [ -n "$BH" ] && kill $BH 2>/dev/null; pkill -f "smcfan/bright hold" 2>/dev/null; BH=""
  [ -n "${1:-}" ] && { sudo -u imac $S/bright hold "$1" 36000 & BH=$!; }; return 0; }
display() {
  if [ "$1" = on ]; then [ -z "$CAFF" ] && { sudo -u imac caffeinate -d -u -t 36000 & CAFF=$!; sleep 2; }; bright ${2:-0.5}
  else bright; [ -n "$BR0" ] && sudo -u imac $S/bright set $BR0; [ -n "$CAFF" ] && kill $CAFF 2>/dev/null; CAFF=""
    pkill -u imac -f "caffeinate -d -u -t 36000" 2>/dev/null; pmset displaysleepnow; fi
}
playing() { [ -s $CTX ] || return 1; local t c v; read t c v < $CTX; [ "$c" = playback ] && [ $(( $(date +%s) - ${t:-0} )) -lt 120 ]; }
listener_ok() { [ -n "$LIS" ] && kill -0 $LIS 2>/dev/null && [ -S $HS ]; }
FINISHED=0
finish() {
  trap '' INT TERM HUP                   # nothing may cut the clean-up short
  [ $FINISHED = 1 ] && return; FINISHED=1
  [ -n "$FL" ] && { kill -TERM $FL 2>/dev/null; wait $FL 2>/dev/null; FL=""; }   # fanlab resets FS! on TERM
  stop_burn; $SMC force 0 >/dev/null
  touch $DONE
  [ -n "$LIS" ] && { kill $LIS 2>/dev/null; rm -f $HS; }
  rm -f $CTX $CTX.tmp
  [ $UNLOADED = 1 ] && { launchctl load -w $PL 2>/dev/null; sleep 20; }
  log "Ende: sofa-fand $(/usr/local/sbin/sofa-fand status 2>&1 | head -1)"
  bright; [ -n "$BR0" ] && sudo -u imac $S/bright set $BR0
  if [ -n "$CAFF" ]; then kill $CAFF 2>/dev/null; CAFF=""; pkill -u imac -f "caffeinate -d -u -t 36000" 2>/dev/null; playing || pmset displaysleepnow; fi
  chown -R imac $D 2>/dev/null
}
trap 'log "ABBRUCH (Signal)"; finish; exit 1' INT TERM HUP
trap 'if [ $FINISHED = 0 ]; then log "unerwartetes Ende (Zeile $LINENO)"; finish; fi' EXIT
# fanlab in the background, polled every 5 s: playback / dead listener end the series at once,
# signals are handled at once (wait is interruptible), a hung fanlab is stopped after its time + 120 s
runfl() {  # MAXS env... fanlab args...
  local maxs=$1; shift; local t0=$(date +%s)
  env "$@" & FL=$!
  while kill -0 $FL 2>/dev/null; do
    if playing; then log "Sofa spielt ab – Serie beendet"; finish; exit 0; fi
    if ! listener_ok; then log "Kontext-Empfänger fehlt – Serie beendet"; finish; exit 1; fi
    if [ $(( $(date +%s) - t0 )) -gt $((maxs + 120)) ]; then log "fanlab hängt – beendet"; kill -TERM $FL; fi
    sleep 5 & wait $!
  done
  wait $FL; local r=$?; FL=""; return $r
}
rm -f $DONE; touch $HB
[ -e $PH ] || echo "start,end,block,step,display,load_cores,odd,hdd,cpu,rc" > $PH
log "Helligkeit vorher: ${BR0:-?}"
$L watchdog $HB 240 $DONE >/dev/null 2>&1 &
log "=== Identifikation: Stufe $STEP s, Blöcke $BLOCKS ==="
launchctl unload $PL; UNLOADED=1
for i in $(seq 1 30); do pgrep -x sofa-fand >/dev/null || break; sleep 1; done   # guard unlinks its sockets on exit
pgrep -x sofa-fand >/dev/null && { log "sofa-fand beendet sich nicht – Serie abgebrochen"; finish; exit 1; }
rm -f $CTX
/opt/local/bin/python3 -I $S/ctxlisten.py $CTX >/dev/null 2>&1 & LIS=$!
sleep 2; listener_ok || { log "Kontext-Empfänger startet nicht – Serie abgebrochen"; finish; exit 1; }
BLOCK_RC=0
step() {  # block step display cores odd hdd cpu ; rc 3 (limit) ends the block, others the series
  [ $BLOCK_RC = 0 ] || return 0
  local t0=$(date +%s); touch $HB
  runfl $STEP TEST="$1-$2" LOADLBL="Bildschirm $3, $4 Kerne" MINEQ=0 $L step $STEP $5 $6 $7; local rc=$?
  echo "$t0,$(date +%s),$1,$2,$3,$4,$5,$6,$7,$rc" >> $PH
  if [ $rc = 3 ]; then log "Stufe $1-$2: Grenze erreicht – Rest des Blocks übersprungen"; BLOCK_RC=3
  elif [ $rc != 0 ]; then log "Stufe $1-$2 abgebrochen (rc $rc) – Serie beendet"; finish; exit 1; fi
  return 0
}
hexbyte() { local v; v=$($SMC read $1 2>/dev/null | awk '{print $5}'); [[ $v =~ ^[0-9a-f]{2}$ ]] && echo $((16#$v)) || echo 255; }
cool() {  # when warm or unreadable: all fans max, no load
  local p g; p=$(hexbyte Tp2H); g=$(hexbyte TG0D)
  if [ $p -ge ${COOL_PSU:-65} ] || [ $g -ge ${COOL_GPU:-60} ]; then   # env override only for tests
    stop_burn; local t0=$(date +%s); touch $HB
    runfl 600 STOP_TP2H=55 STOP_GPU=50 TEST="$1-Abkühlen" LOADLBL="ohne Last, alle Lüfter max" MINEQ=0 $L step 600 2500 5500 2100; local rc=$?
    echo "$t0,$(date +%s),$1,cool,-,0,2500,5500,2100,$rc" >> $PH
    [ $rc = 0 ] || { log "Abkühlen abgebrochen (rc $rc) – Serie beendet"; finish; exit 1; }
  fi
  return 0
}
block() {  # name display cores
  log "Block $1: Bildschirm $2, $3 Kerne"; BLOCK_RC=0
  stop_burn; cool "$1"; display $2; burn $3
  step $1 base  $2 $3 1000 0    1000
  step $1 odd   $2 $3 2500 0    1000
  step $1 cpu   $2 $3 1000 0    2100
  step $1 hdd   $2 $3 1000 2500 1000
  step $1 low   $2 $3 500  0    500
  stop_burn
}
case $BLOCKS in *1*) block B1 off 0;; esac
case $BLOCKS in *2*) block B2 on 0;; esac
case $BLOCKS in *L*)
  log "Block BL: Bildschirm an, Leerlauf, Helligkeit 100/50/10 %"; BLOCK_RC=0; stop_burn; cool BL
  for b in 1.0 0.5 0.1; do display on $b; step BL "hell$b" on 0 1000 0 1000; done;; esac
case $BLOCKS in *3*) block B3 on 2;; esac
case $BLOCKS in *4*) block B4 off 4;; esac
log "Serie fertig"
finish
