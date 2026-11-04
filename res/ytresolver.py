# Sofa YouTube-Stream-Resolver: langlebiger Prozess, eine YoutubeDL-Instanz pro Client,
# Protokoll = JSON-Zeilen über stdin/stdout (siehe docs/youtube.md §5.3).
#   -> {"rid": 1, "vid": "OzCYsIrrRyw", "live": false}
#   <- {"rid": 1, "url": "...m3u8", "alt": ["...95...", "...18..."], "height": 1080,
#       "live": false, "duration": 2135, "expires": 1762190000}
#   <- {"rid": 1, "error": "..."}
#   <- {"ready": true}     (einmal, nach dem Start)
# Aufruf: python ytresolver.py <cachedir>
# Ohne Anmeldung/Cookies (User 2026-11-04). JS-Challenges löst node (MacPorts nodejs26, ohnehin
# für den PO-Token-Server da): ~4 s je Video; QuickJS brauchte ohne Cookies ~20 s.
import json, os, sys, threading, time, re

CACHE = sys.argv[-1]   # früher: <cookies.txt> <cachedir> – letztes Argument ist immer cachedir
out_lock = threading.Lock()

def emit(obj):
    with out_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

def log(msg):
    sys.stderr.write("ytresolver: %s\n" % msg)
    sys.stderr.flush()

try:
    # Vorverarbeiteten Player-JS-Cache aktivieren (spart je Player-Version die Vorverarbeitung)
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
        # ohne TLS-Zertifikatsprüfung (User-Entscheidung 2026-11-04: Daten ungeprüft, Code signiert)
        "nocheckcertificate": True,
        "js_runtimes": {"node": {"path": os.environ.get("SOFA_NODE", "/opt/local/bin/node")}},
        "format": FMT_VOD,
    }

def make_web():
    o = base_opts()
    o["extractor_args"] = {
        "youtube": {"player_client": ["web_embedded"], "player_skip": ["webpage"]},
        # Script-Provider probt sonst 15 s lang node -> nur HTTP-Provider (127.0.0.1:4416)
        "youtubepot-bgutilscript": {"script_path": ["/nonexistent/generate_once.js"]},
    }
    return yt_dlp.YoutubeDL(o)

def make_vr():
    # android_vr: ohne JS, ~2 s; liefert HLS bei Lives, sonst nur Format 18
    o = base_opts()
    o["extractor_args"] = {
        "youtube": {"player_client": ["android_vr"]},
        "youtubepot-bgutilscript": {"script_path": ["/nonexistent/generate_once.js"]},
    }
    return yt_dlp.YoutubeDL(o)

# Zwei Pools mit eigenen YoutubeDL-Instanzen (YoutubeDL ist nicht threadsicher -> je Pool seriell):
#   fg = Wiedergabe (Klick), bg = Vorwärmen, Vorladen bei Fokus, Downloads.
# So wartet ein Klick nie hinter einem Vorladen (vorher bis 10 s statt 3,5 s).
pools = {"bg": (make_web(), make_vr(), threading.Lock()),
         "fg": (make_web(), make_vr(), threading.Lock())}
# Laufende Auflösungen je (vid, live): eine zweite Anfrage für dasselbe Video wartet auf das
# Ergebnis statt neu aufzulösen. Eine Wiedergabe-Anfrage überholt ein noch WARTENDES Vorladen.
jobs = {}
jobs_lock = threading.Lock()

class Job:
    def __init__(self, key, pool):
        self.key, self.pool = key, pool
        self.started, self.ev = False, threading.Event()
        self.result, self.error = None, None
        self.superseded_by = None      # Wiedergabe-Job, der diesen wartenden Vorlade-Job überholt hat
        self.created = time.time()

BG_MAX_WAIT = 60   # Vorladen, das so lange in der Schlange stand, ist veraltet (Fokus längst weiter)

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
    r = {"url": url, "alt": alt, "height": info.get("height"), "fps": info.get("fps"),
         "format": info.get("format_id"), "live": bool(info.get("is_live")),
         "duration": info.get("duration"), "title": info.get("title"),
         "expires": expires_of(url)}
    d = dash_pick(info.get("formats") or [])
    if d:
        r["dash"] = d
    return r

def dash_pick(formats):
    """Getrennte Video-/Audio-Streams fuer die mpv-Engine (VP9/AV1, max. 1080p60 – User-Vorgabe).
    VP9 vor AV1 (gleiche Aufloesung): weniger CPU (gemessen 8,5x vs 6,3x Echtzeit bei 1080p60)."""
    vids, auds = [], []
    for f in formats:
        if not f.get("url") or (f.get("protocol") or "").startswith("m3u8"):
            continue
        vc, ac = f.get("vcodec") or "none", f.get("acodec") or "none"
        if vc != "none" and ac == "none" and (vc.startswith("vp9") or vc.startswith("vp09") or vc.startswith("av01")):
            h, fps = f.get("height") or 0, f.get("fps") or 30
            if h <= 1080 and fps <= 60:
                vids.append((h, fps, 1 if vc.startswith("vp") else 0, f.get("tbr") or 0, f))
        elif vc == "none" and ac != "none":
            auds.append((1 if ac.startswith("opus") else 0, f.get("abr") or f.get("tbr") or 0, f))
    if not vids or not auds:
        return None
    v = max(vids, key=lambda t: t[:4])[4]
    a = max(auds, key=lambda t: t[:2])[2]
    return {"video": v["url"], "audio": a["url"], "height": v.get("height"), "fps": v.get("fps"),
            "vcodec": (v.get("vcodec") or "").split(".")[0], "acodec": (a.get("acodec") or "").split(".")[0]}

def resolve(vid, live, pool):
    web, vr, _ = pools[pool]
    u = "https://www.youtube.com/watch?v=" + vid
    chain = [vr, web] if live else [web, vr]
    last = None
    for ydl in chain:
        try:
            t0 = time.time()
            info = ydl.extract_info(u, download=False)
            dt = time.time() - t0
            if dt > 6:   # langsame Auflösungen nachvollziehbar machen (Client, Formatanzahl, Laufzeit)
                log("slow %s via %s: %.1fs, %d Formate, live=%s" % (vid, "vr" if ydl is vr else "web", dt,
                    len(info.get("formats") or []), bool(info.get("is_live"))))
            r = summarize(info)
            if not live and ydl is vr and r.get("format") == "18":
                r["lowq"] = True
            return r
        except Exception as e:
            last = e
            log("%s via %s: %s" % (vid, "vr" if ydl is vr else "web", str(e)[:200]))
    raise last or RuntimeError("unbekannter Fehler")

def run(job):
    """Job im eigenen Pool ausführen. Wurde er, solange er wartete, von einer
    Wiedergabe-Anfrage überholt, deren Ergebnis übernehmen statt doppelt aufzulösen –
    auch wenn jener Job schon fertig und aus `jobs` entfernt ist (superseded_by)."""
    try:
        other = None
        with pools[job.pool][2]:
            with jobs_lock:
                job.started = True
                cur = jobs.get(job.key)
                other = job.superseded_by or (cur if cur is not None and cur is not job else None)
            if other is None:
                if job.pool == "bg" and time.time() - job.created > BG_MAX_WAIT:
                    job.error = RuntimeError("Vorladen verworfen (veraltet)")
                else:
                    try:
                        job.result = resolve(job.key[0], job.key[1], job.pool)
                    except Exception as e:
                        job.error = e
        if other is not None:
            other.ev.wait(120)
            job.result, job.error = other.result, other.error
    except BaseException as e:   # nie einen Job ohne Ergebnis hängen lassen
        if job.result is None and job.error is None:
            job.error = e
    finally:
        with jobs_lock:
            if jobs.get(job.key) is job:
                del jobs[job.key]
        job.ev.set()

def handle(req):
    rid = req.get("rid")
    vid = req.get("vid", "")
    if not re.match(r"^[A-Za-z0-9_-]{11}$", vid):
        emit({"rid": rid, "error": "ungültige Video-ID"}); return
    t0 = time.time()
    key, pool = (vid, bool(req.get("live"))), ("fg" if req.get("prio", True) else "bg")
    with jobs_lock:
        job = jobs.get(key)
        mine = job is None or (pool == "fg" and job.pool == "bg" and not job.started)
        if mine:
            new = Job(key, pool)
            if job is not None:
                job.superseded_by = new   # der wartende Vorlade-Job übernimmt später dieses Ergebnis
            job = jobs[key] = new
    if mine:
        run(job)
    else:
        job.ev.wait(120)
    if job.result is not None:
        r = dict(job.result)
        r["rid"], r["secs"], r["pool"] = rid, round(time.time() - t0, 2), pool + ("" if mine else "+shared")
        emit(r)
    else:
        msg = str(job.error or "Zeitüberschreitung")
        m = re.search(r"ERROR: \[youtube\] [^:]+: (.*)", msg)
        emit({"rid": rid, "error": (m.group(1) if m else msg)[:300]})

def warmup():
    # Erster Lauf nach einem YouTube-Player-Rollout dauert ~20 s (JS-Vorverarbeitung):
    # im Hintergrund vorziehen, damit der erste echte Klick schnell ist. Erst bg (füllt den
    # Platten-Cache), dann fg – aber nur, solange keine Wiedergabe den fg-Pool braucht.
    for name in ("bg", "fg"):
        web, _, lk = pools[name]
        if not lk.acquire(blocking=(name == "bg")):
            continue
        try:
            t0 = time.time()
            web.extract_info("https://www.youtube.com/watch?v=jNQXAC9IVRw", download=False)
            log("warm %s in %.1fs" % (name, time.time() - t0))
        except Exception as e:
            log("warmup %s failed: %s" % (name, str(e)[:200]))
        finally:
            lk.release()

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
