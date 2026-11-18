#!/opt/local/bin/python3 -I
# ctxlisten.py OUTFILE - stands in for sofa-fand's hint socket while a fan test runs (sofa-fand
# unloaded): receives Sofa's context datagrams and keeps "epoch ctx vol" of the last one in OUTFILE.
import json, os, socket, sys, time
P = "/var/run/sofa-fand/hint.sock"; out = sys.argv[1]
os.makedirs("/var/run/sofa-fand", exist_ok=True)
try: os.unlink(P)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); s.bind(P); os.chmod(P, 0o666)
while True:
    try:
        m = json.loads(s.recv(600).decode("utf-8", "replace"))
        ctx = str(m.get("ctx", "?"))[:12]; vol = m.get("vol", -1)
        tmp = out + ".tmp"
        with open(tmp, "w") as f: f.write("%d %s %s\n" % (time.time(), ctx, vol))
        os.replace(tmp, out)
    except Exception:
        pass
