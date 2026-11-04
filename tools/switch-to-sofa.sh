#!/bin/bash
# Switch Kodi -> Sofa (reversible with switch-to-kodi.sh).
#  1. install Sofa into /Applications (transitional until the MacPorts port)
#  2. quit Kodi; unload XBMCHelper + Focusguard, move the plists to
#     ~/Library/LaunchAgents/disabled-kodi/ (Kodi itself stays installed)
#  3. load the LaunchAgents de.sofa.remote (Apple Remote) + de.sofa.app (autostart)
set -eu
unset DYLD_INSERT_LIBRARIES
SRC="$(cd "$(dirname "$0")/.." && pwd)"
LA="$HOME/Library/LaunchAgents"
OFF="$LA/disabled-kodi"

echo "== Build + install"
make -C "$SRC" >/dev/null
rm -rf /Applications/Sofa.app
cp -R "$SRC/build/Sofa.app" /Applications/

echo "== Quitting Kodi"
osascript -e 'tell application "Kodi" to quit' 2>/dev/null || true
for i in $(seq 1 20); do pgrep -x Kodi >/dev/null || break; sleep 0.5; done
pgrep -x Kodi >/dev/null && { echo "   Kodi not responding, sending TERM"; pkill -TERM -x Kodi || true; sleep 2; }

echo "== Disabling XBMCHelper + Focusguard"
mkdir -p "$OFF"
for p in org.xbmc.helper com.kodi.focusguard; do
  if [ -f "$LA/$p.plist" ]; then
    launchctl unload "$LA/$p.plist" 2>/dev/null || true
    mv "$LA/$p.plist" "$OFF/"
    echo "   $p -> disabled-kodi/"
  fi
done
pkill -f XBMCHelper 2>/dev/null || true

echo "== Loading the Sofa agents"
for p in de.sofa.remote de.sofa.app; do
  cp "$SRC/res/launchd/$p.plist" "$LA/"
  launchctl unload "$LA/$p.plist" 2>/dev/null || true
  launchctl load "$LA/$p.plist"
done
sleep 2
launchctl list | grep -E 'de\.sofa' || true
tail -3 "$HOME/Library/Logs/SofaRemote.log" 2>/dev/null || true
echo "Done. Way back: $SRC/tools/switch-to-kodi.sh"
