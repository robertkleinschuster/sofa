#!/opt/local/bin/python3 -I
# Test-Fernbedienung für Sofas Handy-Koppeln: verhält sich wie eine Web-Remote
# (pyytlounge-Requests), koppelt per TV-Code und schickt setPlaylist/pause/seek/play.
#   unset DYLD_INSERT_LIBRARIES; tools/lounge-remote.py <12-stelliger Code> [videoId]
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "probes"))
import lounge_probe as lp
code = sys.argv[1].replace(" ", "")
r = lp.Remote(code, name="Sofa Test-Handy")
r.run(sys.argv[2] if len(sys.argv) > 2 else "jNQXAC9IVRw")
import time; time.sleep(5)
print("events:", r.events)
