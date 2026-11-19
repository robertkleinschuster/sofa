#!/bin/bash
# ident-nightly.sh - one identification block per night (LaunchDaemon de.sofa.fanident, root, 01:30).
# Blocks rotate by day of year: 1 off/idle, 2 on/idle, L brightness, 3 on/2 cores, 4 off/4 cores
# (see ident.sh). Starts only while Sofa rests (sofa-fand profile ruhe) and no series runs; checks
# every 10 min until 02:30, then skips the night (done well before the 04:00 fanmodel report).
# Env for tests: STEP (s, default 900), BLOCK (force one block), DEADLINE (HHMM).
set -u
S=/Users/imac/src/sofa/helpers/sofa-fand/tools
LOG=/Users/imac/Library/Logs/fan-ident-night.log
log() { echo "$(date '+%F %T') $*" >> $LOG; chown imac $LOG 2>/dev/null; }
STEP=${STEP:-900}
blocks=(1 2 L 3 4); B=${BLOCK:-${blocks[$(( 10#$(date +%j) % 5 ))]}}
deadline=$(date -j -f "%H%M" "${DEADLINE:-0230}" +%s); [ $deadline -lt $(date +%s) ] && deadline=$((deadline + 86400))
log "nachts: Block $B, Stufe $STEP s"
while :; do
  if ps -axo command | grep -Eq '^/bin/bash .*/ident\.sh [0-9]'; then log "eine Serie läuft schon – keine heute"; exit 0; fi
  if /usr/local/sbin/sofa-fand status 2>/dev/null | grep -q "^profile ruhe"; then break; fi
  [ $(date +%s) -ge $deadline ] && { log "Sofa ruht nicht bis Frist – keine Serie heute"; exit 0; }
  log "Sofa ruht nicht – warte 10 min"; sleep 600
done
log "starte Block $B"
exec $S/ident.sh $STEP "$B"
