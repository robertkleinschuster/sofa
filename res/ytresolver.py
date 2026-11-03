# Sofa YouTube-Stream-Resolver: langlebiger Prozess, eine YoutubeDL-Instanz pro Client,
# Protokoll = JSON-Zeilen über stdin/stdout (siehe docs/youtube.md §5.3).
#   -> {"rid": 1, "vid": "OzCYsIrrRyw", "live": false}
#   <- {"rid": 1, "url": "...m3u8", "alt": ["...95...", "...18..."], "height": 1080,
#       "live": false, "duration": 2135, "expires": 1762190000}
#   <- {"rid": 1, "error": "..."}
#   <- {"ready": true}     (einmal, nach dem Start)
# Aufruf: python ytresolver.py <cookies.txt> <cachedir>
import json, os, sys, threading, time, re

COOKIES, CACHE = sys.argv[1], sys.argv[2]
out_lock = threading.Lock()

def emit(obj):
    with out_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

def log(msg):
    sys.stderr.write("ytresolver: %s\n" % msg)
    sys.stderr.flush()

try:
    # Vorverarbeiteten Player-JS-Cache aktivieren (spart ~19 s QuickJS pro Player-Version)
    from yt_dlp.extractor.youtube.jsc._builtin import ejs
    ejs.EJSBaseJCP._ENABLE_PREPROCESSED_PLAYER_CACHE = True
except Exception as e:
    log("preprocessed player cache unavailable: %s" % e)
import yt_dlp

FMT_VOD = ("best[height<=1080][vcodec^=avc1][acodec!=none][protocol^=m3u8]"
           "/best[height<=720][vcodec^=avc1][acodec!=none]/18")

def base_opts():
    return {
        "quiet": True, "no_warnings": True, "skip_download": True, "check_formats": False,
        "noplaylist": True, "cachedir": CACHE,
        "js_runtimes": {"quickjs": {"path": "/opt/local/bin/qjs"}},
        "format": FMT_VOD,
    }

def make_web():
    o = base_opts()
    if os.path.exists(COOKIES):
        o["cookiefile"] = COOKIES
    o["extractor_args"] = {
        "youtube": {"player_client": ["web_embedded"], "player_skip": ["webpage"]},
        # Script-Provider probt sonst 15 s lang node -> nur HTTP-Provider (127.0.0.1:4416)
        "youtubepot-bgutilscript": {"script_path": ["/nonexistent/generate_once.js"]},
    }
    return yt_dlp.YoutubeDL(o)

def make_vr():
    # android_vr: ohne Cookies, ohne JS, ~2 s; liefert HLS bei Lives, sonst nur Format 18
    o = base_opts()
    o["extractor_args"] = {
        "youtube": {"player_client": ["android_vr"]},
        "youtubepot-bgutilscript": {"script_path": ["/nonexistent/generate_once.js"]},
    }
    return yt_dlp.YoutubeDL(o)

web = make_web()
vr = make_vr()
lock = threading.Lock()   # YoutubeDL ist nicht threadsicher -> seriell

def expires_of(url):
    m = re.search(r"/expire/(\d+)/", url) or re.search(r"[?&]expire=(\d+)", url)
    return int(m.group(1)) if m else int(time.time()) + 5 * 3600

def summarize(info):
    url = info.get("url")
    if not url:
        raise RuntimeError("kein Stream")
    alt = []
    by_id = {f.get("format_id"): f for f in info.get("formats") or []}
    for fid in ("95", "18"):
        f = by_id.get(fid)
        if f and f.get("url") and f["url"] != url:
            alt.append(f["url"])
    return {"url": url, "alt": alt, "height": info.get("height"),
            "format": info.get("format_id"), "live": bool(info.get("is_live")),
            "duration": info.get("duration"), "title": info.get("title"),
            "expires": expires_of(url)}

def resolve(vid, live):
    u = "https://www.youtube.com/watch?v=" + vid
    chain = [vr, web] if live else [web, vr]
    last = None
    for ydl in chain:
        try:
            info = ydl.extract_info(u, download=False)
            r = summarize(info)
            if not live and ydl is vr and r.get("format") == "18":
                r["lowq"] = True
            return r
        except Exception as e:
            last = e
            log("%s via %s: %s" % (vid, "vr" if ydl is vr else "web", str(e)[:200]))
    raise last or RuntimeError("unbekannter Fehler")

def handle(req):
    rid = req.get("rid")
    vid = req.get("vid", "")
    if not re.match(r"^[A-Za-z0-9_-]{11}$", vid):
        emit({"rid": rid, "error": "ungültige Video-ID"}); return
    t0 = time.time()
    with lock:
        try:
            r = resolve(vid, bool(req.get("live")))
            r["rid"] = rid
            r["secs"] = round(time.time() - t0, 2)
            emit(r)
        except Exception as e:
            msg = str(e)
            m = re.search(r"ERROR: \[youtube\] [^:]+: (.*)", msg)
            emit({"rid": rid, "error": (m.group(1) if m else msg)[:300]})

def warmup():
    # Erster Lauf nach einem YouTube-Player-Rollout dauert ~20 s (JS-Vorverarbeitung):
    # im Hintergrund vorziehen, damit der erste echte Klick schnell ist.
    with lock:
        t0 = time.time()
        try:
            web.extract_info("https://www.youtube.com/watch?v=jNQXAC9IVRw", download=False)
            log("warm in %.1fs" % (time.time() - t0))
        except Exception as e:
            log("warmup failed: %s" % str(e)[:200])

def prune_cache():
    d = os.path.join(CACHE, "challenge-solver")
    cutoff = time.time() - 14 * 86400
    try:
        for root, _, files in os.walk(d):
            for f in files:
                p = os.path.join(root, f)
                if os.path.getmtime(p) < cutoff:
                    os.remove(p)
    except Exception:
        pass

prune_cache()
emit({"ready": True})
threading.Thread(target=warmup, daemon=True).start()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except Exception:
        continue
    threading.Thread(target=handle, args=(req,), daemon=True).start()
