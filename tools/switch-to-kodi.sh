#!/bin/bash
# Fallback Sofa -> Kodi: unload the Sofa agents, restore the Kodi agents, start Kodi.
# Sofa stays installed (tile/restart possible at any time).
set -u
LA="$HOME/Library/LaunchAgents"
OFF="$LA/disabled-kodi"

for p in de.sofa.app de.sofa.remote; do
  [ -f "$LA/$p.plist" ] && { launchctl unload "$LA/$p.plist" 2>/dev/null; rm -f "$LA/$p.plist"; echo "$p removed"; }
done
osascript -e 'tell application "Sofa" to quit' 2>/dev/null || pkill -x Sofa
for p in org.xbmc.helper com.kodi.focusguard; do
  if [ -f "$OFF/$p.plist" ]; then
    mv "$OFF/$p.plist" "$LA/"
    launchctl load "$LA/$p.plist"
    echo "$p restored"
  fi
done
open -a Kodi
echo "Kodi active."
