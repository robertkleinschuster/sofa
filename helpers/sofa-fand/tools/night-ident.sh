#!/bin/bash
# night-ident.sh START_HHMM STEP_S - waits until START, then (only if Sofa is not playing; checked
# every 5 min until 02:30) runs ident.sh with STEP_S. Run as root, detached.
set -u
START=${1:-0015}; STEP=${2:-900}
S=/Users/imac/src/smcfan; LOG=/Users/imac/Library/Logs/fan-ident-night.log
log() { echo "$(date '+%F %T') $*" >> $LOG; chown imac $LOG 2>/dev/null; }
log "geplant: Start $START, Stufe $STEP s"
target=$(date -j -f "%H%M" "$START" +%s); [ $target -lt $(date +%s) ] && target=$((target + 86400))
while [ $(date +%s) -lt $target ]; do sleep 60; done
deadline=$(date -j -f "%H%M" "0230" +%s); [ $deadline -lt $(date +%s) ] && deadline=$((deadline + 86400))
while /usr/local/sbin/sofa-fand status 2>/dev/null | grep -q "^profile playback"; do
  [ $(date +%s) -gt $deadline ] && { log "Sofa spielt bis 02:30 – keine Serie heute"; exit 0; }
  log "Sofa spielt – warte 5 min"; sleep 300
done
log "starte ident.sh $STEP"
exec $S/ident.sh $STEP
