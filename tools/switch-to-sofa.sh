#!/bin/bash
# Umstellung Kodi -> Sofa (umkehrbar mit switch-to-kodi.sh).
#  1. Sofa nach /Applications installieren (Übergang bis zum MacPorts-Port)
#  2. Kodi beenden; XBMCHelper + Focusguard entladen, plists nach
#     ~/Library/LaunchAgents/disabled-kodi/ verschieben (Kodi selbst bleibt installiert)
#  3. LaunchAgents de.sofa.remote (Apple Remote) + de.sofa.app (Autostart) laden
set -eu
unset DYLD_INSERT_LIBRARIES
SRC="$(cd "$(dirname "$0")/.." && pwd)"
LA="$HOME/Library/LaunchAgents"
OFF="$LA/disabled-kodi"

echo "== Build + Installation"
make -C "$SRC" >/dev/null
rm -rf /Applications/Sofa.app
cp -R "$SRC/build/Sofa.app" /Applications/

echo "== Kodi beenden"
osascript -e 'tell application "Kodi" to quit' 2>/dev/null || true
for i in $(seq 1 20); do pgrep -x Kodi >/dev/null || break; sleep 0.5; done
pgrep -x Kodi >/dev/null && { echo "   Kodi reagiert nicht, sende TERM"; pkill -TERM -x Kodi || true; sleep 2; }

echo "== XBMCHelper + Focusguard deaktivieren"
mkdir -p "$OFF"
for p in org.xbmc.helper com.kodi.focusguard; do
  if [ -f "$LA/$p.plist" ]; then
    launchctl unload "$LA/$p.plist" 2>/dev/null || true
    mv "$LA/$p.plist" "$OFF/"
    echo "   $p -> disabled-kodi/"
  fi
done
pkill -f XBMCHelper 2>/dev/null || true

echo "== Sofa-Agents laden"
for p in de.sofa.remote de.sofa.app; do
  cp "$SRC/res/launchd/$p.plist" "$LA/"
  launchctl unload "$LA/$p.plist" 2>/dev/null || true
  launchctl load "$LA/$p.plist"
done
sleep 2
launchctl list | grep -E 'de\.sofa' || true
tail -3 "$HOME/Library/Logs/SofaRemote.log" 2>/dev/null || true
echo "Fertig. Rückweg: $SRC/tools/switch-to-kodi.sh"
