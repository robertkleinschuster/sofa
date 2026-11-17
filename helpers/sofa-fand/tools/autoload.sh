#!/bin/bash
# Loads the installed sofa-fand LaunchDaemon once the overnight series and test 38 are over,
# then checks it: running, no trip, fans follow their targets, Sofa hints arriving.
# On failure: unload and FS!=0. Run as root, detached.
D=/Users/imac/Library/Logs/fan-tuning-2026-11-17; LIVE=$D/live.log
PL=/Library/LaunchDaemons/de.sofa.fand.plist; S=/usr/local/sbin/sofa-fand
SMC=/Users/imac/src/smcfan/smcfan
log() { echo "$(date +%T) Auto-Laden: $*" >> $LIVE; }
fail() { log "FEHLER: $* → unload"; launchctl unload $PL 2>/dev/null; sleep 2; $S reset >/dev/null 2>&1 || $SMC force 0 >/dev/null; log "nach unload FS!=$($SMC read 'FS! ' | cut -d: -f2)"; exit 1; }
until [ -e $D/.done2 ] && ! pgrep -f h1-extra.sh >/dev/null && ! pgrep -f night.sh >/dev/null; do sleep 60; done
pkill -f fand-dry-pause.sh; pkill -f "sofa-fand run -n"; sleep 2
pgrep -f "sofa-fand run" >/dev/null && fail "noch ein sofa-fand-Prozess aktiv"
fs=$($SMC read 'FS! ' | awk '{print $NF}'); [ "$fs" = "00" ] || { $SMC force 0 >/dev/null; log "FS! war nicht 0, zurückgesetzt"; }
log "lade $PL (Binary $(shasum $S | cut -c1-12))"
launchctl load -w $PL || fail "launchctl load fehlgeschlagen"
check() {
  local st; st=$($S status 2>&1) || fail "status nicht erreichbar"
  [ $(pgrep -f "sbin/sofa-fand run" | wc -l) -ge 2 ] || fail "Wächter/Regler laufen nicht"
  local mode; mode=$(echo "$st" | awk '/^mode/{print $2}')
  [ "$mode" = trip ] && fail "Trip: $(echo "$st" | head -1)"
  [ "$mode" = disabled ] && fail "$(echo "$st" | head -1)"
  echo "$st" | awk '/^fan /{a=$5; t=$7; if (t>0 && a < t/2) bad=bad" F"$2"(ist "a", soll "t")"} END{if (bad) {print bad; exit 1}}' > /tmp/fand-bad || fail "Lüfter folgen nicht:$(cat /tmp/fand-bad)"
  log "$1: $(echo "$st" | head -1); $(echo "$st" | awk '/^fan /{printf "%s %s/%s  ", $3, $5, $7}'); $(echo "$st" | grep ^hints_received); FS!=$($SMC read 'FS! ' | awk '{print $NF}')"
}
sleep 60; check "nach 60 s"
sleep 240; check "nach 5 min"
h=$($S status | awk '/^hints_received/{print $2}')
[ "${h:-0}" -gt 0 ] && log "Sofa-Hinweise kommen an ($h)" || log "WARNUNG: keine Sofa-Hinweise empfangen (Sofa aus oder sendet nicht) – Standardprofil, Daemon bleibt geladen"
log "fertig, Daemon läuft"
