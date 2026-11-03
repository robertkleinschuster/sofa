#!/bin/bash
# Rückfall Sofa -> Kodi: Sofa-Agents entladen, Kodi-Agents wiederherstellen, Kodi starten.
# Sofa bleibt installiert (Kachel/Neustart jederzeit möglich).
set -u
LA="$HOME/Library/LaunchAgents"
OFF="$LA/disabled-kodi"

for p in de.sofa.app de.sofa.remote; do
  [ -f "$LA/$p.plist" ] && { launchctl unload "$LA/$p.plist" 2>/dev/null; rm -f "$LA/$p.plist"; echo "$p entfernt"; }
done
osascript -e 'tell application "Sofa" to quit' 2>/dev/null || pkill -x Sofa
for p in org.xbmc.helper com.kodi.focusguard; do
  if [ -f "$OFF/$p.plist" ]; then
    mv "$OFF/$p.plist" "$LA/"
    launchctl load "$LA/$p.plist"
    echo "$p wiederhergestellt"
  fi
done
open -a Kodi
echo "Kodi aktiv."
