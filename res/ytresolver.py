# Sofa YouTube stream resolver = the yt-dlp FALLBACK behind the sofa-yt sidecar (docs/youtube.md).
# Started on demand by SFYTResolver and ended again when idle; one YoutubeDL instance per client,
# protocol = JSON lines over stdin/stdout (see docs/youtube.md §5.3).
#   -> {"rid": 1, "vid": "OzCYsIrrRyw", "live": false, "pot": "http://127.0.0.1:<sidecar port>"}
#   <- {"rid": 1, "url": "...m3u8", "alt": ["...95...", "...18..."], "height": 1080,
#       "live": false, "duration": 2135, "expires": 1762190000}
#   <- {"rid": 1, "error": "..."}
#   <- {"ready": true}     (once, after the start)
# Usage: python ytresolver.py <cachedir>
# Without sign-in/cookies (user 2026-11-04). JS challenges are solved by node (the bundled one):
# ~4 s per video. PO tokens: Sofa's provider plugin (res/yt-dlp-plugins) asks the sidecar given in
# "pot" - one BotGuard identity for both YouTube paths. No warm-up and no preloading: the sidecar
# does both; this process only answers when the sidecar could not (each answer = player requests).
import json, os, sys, threading, time, re

CACHE = sys.argv[-1]   # formerly: <cookies.txt> <cachedir> - the last argument is always cachedir
out_lock = threading.Lock()

def emit(obj):
    with out_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

def log(msg):
    sys.stderr.write("ytresolver: %s\n" % msg)
    sys.stderr.flush()

try:
    # enable the preprocessed player JS cache (saves the preprocessing per player version)
    from yt_dlp.extractor.youtube.jsc._builtin import ejs
    ejs.EJSBaseJCP._ENABLE_PREPROCESSED_PLAYER_CACHE = True
except Exception as e:
    log("preprocessed player cache unavailable: %s" % e)
import yt_dlp

FMT_VOD = ("best[height<=1080][vcodec^=avc1][acodec!=none][protocol^=m3u8]"
           "/best[height<=720][vcodec^=avc1][acodec!=none]/18")

# Version of the results: bump when the selection changes -> on restart Sofa drops saved
# older resolutions (2: original audio track also via xtags, dlaudio for downloads)
RESULT_VERSION = 2

def base_opts():
    return {
        "quiet": True, "no_warnings": True, "skip_download": True, "check_formats": False,
        "noplaylist": True, "cachedir": CACHE,
        # without TLS certificate verification (user decision 2026-11-04: data unverified, code signed)
        "nocheckcertificate": True,
        "js_runtimes": {"node": {"path": os.environ.get("SOFA_NODE", "/opt/local/bin/node")}},
        "format": FMT_VOD,
    }

def make_web(client="mweb"):
    o = base_opts()
    o["extractor_args"] = {
        # ONE client per call - every client is a player request (bot-flagged IP). mweb: DASH up
        # to 1080p with a GVS PO token (from the sidecar) for mpv + itag 18 as the muxed fallback;
        # enough for playback (2026-11-05 measured: 36 formats, no HLS). web_embedded (HLS) is only
        # asked when mweb fails (resolve() chain); before, both were asked in every call.
        "youtube": {"player_client": [client], "player_skip": ["webpage"]},
    }
    return yt_dlp.YoutubeDL(o)

def make_vr():
    # android_vr: no JS, ~2 s; returns HLS for lives, otherwise only format 18
    o = base_opts()
    o["extractor_args"] = {"youtube": {"player_client": ["android_vr"]}}
    return yt_dlp.YoutubeDL(o)

# Two pools with their own YoutubeDL instances (YoutubeDL is not thread-safe -> serial per pool):
#   fg = playback (click), bg = downloads.
# So a click never waits behind a download's resolution.
pools = {"bg": (make_web(), make_vr(), threading.Lock(), make_web("web_embedded")),
         "fg": (make_web(), make_vr(), threading.Lock(), make_web("web_embedded"))}
# Running resolutions per (vid, live): a second request for the same video waits for the
# result instead of resolving again. A playback request overtakes a still WAITING background job.
jobs = {}
jobs_lock = threading.Lock()

class Job:
    def __init__(self, key, pool):
        self.key, self.pool = key, pool
        self.started, self.ev = False, threading.Event()
        self.result, self.error = None, None
        self.superseded_by = None      # playback job that overtook this waiting background job
        self.created = time.time()

BG_MAX_WAIT = 60

# --- Bot-check circuit breaker -------------------------------------------------------------
# YouTube answers player requests from a flagged IP with "Sign in to confirm you're not a bot".
# Every further request while flagged prolongs the flag, so after a bot check the background
# (downloads) sends nothing until the pause is over: 5 min, doubling up to
# 1 h, reset by the first success. Playback the user starts still tries (the flag is often
# intermittent). Persisted: shared with the sidecar, and this process comes and goes.
BLOCK_FILE = os.path.join(CACHE, "youtube-block.json")
BLOCK_MIN, BLOCK_MAX = 300, 3600
block_lock = threading.Lock()
block = {"until": 0, "backoff": 0}

def sync_block():
    """Merge the shared file into `block` (caller holds block_lock). The SABR sidecar writes the same
    file: without re-reading, a stale 5-min state here overwrote its 1-h pause (review 2026-11-05)."""
    try:
        with open(BLOCK_FILE) as f:
            b = json.load(f)
        block["until"] = max(block["until"], float(b.get("until", 0)))
        if float(b.get("until", 0)) > time.time():
            block["backoff"] = max(block["backoff"], float(b.get("backoff", 0)))
        elif block["until"] <= time.time():
            block["backoff"] = float(b.get("backoff", 0))
    except Exception:
        pass

def is_bot_check(e):
    m = str(e).lower()
    return "not a bot" in m or "sign in to confirm" in m

def blocked_until():
    with block_lock:
        sync_block()
        return block["until"] if block["until"] > time.time() else 0

def note_result(bot_check):
    with block_lock:
        sync_block()
        if bot_check:
            block["backoff"] = min(BLOCK_MAX, max(BLOCK_MIN, block["backoff"] * 2))
            block["until"] = time.time() + block["backoff"]
            log("bot check - background requests paused for %d min" % (block["backoff"] // 60))
        elif block["backoff"] or block["until"]:
            block["until"], block["backoff"] = 0, 0
            log("requests succeed again - pause lifted")
        else:
            return
        try:
            with open(BLOCK_FILE + ".tmp", "w") as f:
                json.dump(block, f)
            os.rename(BLOCK_FILE + ".tmp", BLOCK_FILE)
        except Exception:
            pass   # best effort: the in-memory state still applies

def expires_of(url):
    m = re.search(r"/expire/(\d+)/", url) or re.search(r"[?&]expire=(\d+)", url)
    return int(m.group(1)) if m else int(time.time()) + 5 * 3600

def summarize(info):
    url = info.get("url")
    if not url:
        raise RuntimeError("no stream")
    alt = []
    by_id = {f.get("format_id"): f for f in info.get("formats") or []}
    for fid in ("95", "18"):
        f = by_id.get(fid)
        if f and f.get("url") and f["url"] != url:
            alt.append(f["url"])
    r = {"url": url, "alt": alt, "height": info.get("height"), "fps": info.get("fps"),
         "format": info.get("format_id"), "live": bool(info.get("is_live")),
         "duration": info.get("duration"), "title": info.get("title"),
         "expires": expires_of(url),
         "published": info.get("timestamp") or info.get("release_timestamp"),
         "v": RESULT_VERSION}
    d = dash_pick(info.get("formats") or [])
    if d:
        d["audios"] = audio_tracks(info.get("formats") or [])
        r["dash"] = d
    # download (muxed HLS stream = default track, possibly dubbed): with several audio tracks pass
    # the original audio track as AAC (fits into MP4) separately -> the downloader lays it over it
    if d and d["audios"]:
        aac = [f for f in info.get("formats") or [] if f.get("url") and (f.get("vcodec") or "none") == "none"
               and (f.get("acodec") or "").startswith("mp4a") and not (f.get("protocol") or "").startswith("m3u8")]
        if aac:
            best = max(aac, key=audio_rank)
            if audio_pref(best) >= 5:   # only if surely original/default - otherwise better change nothing
                r["dlaudio"] = best["url"]
    # diagnosis "wrong audio track": which audio tracks did YouTube deliver (language/rank per track)?
    # Without audioTrack the language is missing (yt-dlp: language None) -> "audio ?" in the player log.
    tracks = sorted({"%s:%s:%s" % (audio_lang(f) or "?", f.get("language_preference"), xtags(f).get("acont", "-"))
                     for f in info.get("formats") or []
                     if (f.get("vcodec") or "none") == "none" and (f.get("acodec") or "none") != "none"})
    log("audio %s: %s -> %s (video language %s, format %s)" % (info.get("id"), " ".join(tracks) or "muxed only",
        (d or {}).get("alang"), info.get("language"), info.get("format_id")))
    r["subs"] = subtitle_tracks(info)
    return r

def xtags(f):
    """Stream tags from the googlevideo URL (xtags=acont=original:lang=de-DE ...).
    Independent of audioTrack in the player response, which YouTube does not always include
    (then yt-dlp knows neither language nor original -> wrong dubbed track, Dagi report 2026-11-04)."""
    from urllib.parse import urlparse, parse_qs
    try:
        v = (parse_qs(urlparse(f.get("url") or "").query).get("xtags") or [""])[0]
    except Exception:
        return {}
    out = {}
    for part in re.split(r"[:;&]", v):
        if "=" in part:
            k, _, val = part.partition("=")
            out[k] = val
    return out

def audio_lang(f):
    return f.get("language") or xtags(f).get("lang")

def audio_pref(f):
    """10 original, 5 default, 0 unknown, -1 dubbed, -10 audio description."""
    lp = f.get("language_preference")
    acont = xtags(f).get("acont", "")
    if acont == "original":
        return 10
    if acont.startswith("dubbed"):
        return -1
    if acont == "descriptive":
        return -10
    return lp if isinstance(lp, int) else 0

def audio_rank(f):
    """Ranking of audio tracks: original first, without DRC, Opus, bitrate."""
    drc = "drc" in (f.get("format_id") or "").lower() or xtags(f).get("drc") == "1"
    return (audio_pref(f), 0 if drc else 1,
            1 if (f.get("acodec") or "").startswith("opus") else 0, f.get("abr") or f.get("tbr") or 0)

def audio_tracks(formats):
    """Best audio track per language (for the "Ton" choice), original first."""
    best = {}
    for f in formats:
        if not f.get("url") or (f.get("protocol") or "").startswith("m3u8"):
            continue
        if (f.get("vcodec") or "none") != "none" or (f.get("acodec") or "none") == "none":
            continue
        lang = audio_lang(f) or "und"
        if lang not in best or audio_rank(f) > audio_rank(best[lang]):
            best[lang] = f
    if len(best) < 2:
        return []   # only one language: nothing to choose
    out = []
    for lang, f in best.items():
        lp = audio_pref(f)
        # "dubbed" only when tagged (acont=dubbed* / yt-dlp -1), not when unknown (0)
        out.append({"lang": lang, "url": f["url"], "original": lp == 10,
                    "dubbed": -10 < lp < 0, "described": lp == -10})
    out.sort(key=lambda t: (not t["original"], t["described"], t["lang"]))
    return out

def subtitle_tracks(info):
    """Subtitles as WebVTT: real ones first, plus the automatic ones in the original language
    ("<lang>-orig") and the automatic translation into German if there are no real German ones."""
    def vtt(fmts):
        for f in fmts or []:
            if f.get("ext") == "vtt" and f.get("url"):
                return f["url"]
        return None
    out, have = [], set()
    for lang, fmts in (info.get("subtitles") or {}).items():
        u = vtt(fmts)
        if u and lang != "live_chat":
            out.append({"lang": lang, "url": u, "kind": "manual"}); have.add(lang.split("-")[0])
    auto = info.get("automatic_captions") or {}
    for lang, fmts in auto.items():
        if lang.endswith("-orig"):
            u = vtt(fmts)
            if u:
                out.append({"lang": lang[:-5], "url": u, "kind": "auto"})
    # translation into German only for a foreign-language video: with German audio "de" would only be
    # a worse copy of the automatic German subtitles (Kurzgesagt report 2026-11-04)
    spoken = (info.get("language") or "").split("-")[0]
    if any(t["lang"].split("-")[0] == "de" for t in out):
        have.add("de")
    if "de" not in have and spoken != "de" and auto.get("de"):
        u = vtt(auto["de"])
        if u:
            out.append({"lang": "de", "url": u, "kind": "translated"})
    return out

def dash_pick(formats):
    """Separate video/audio streams for the mpv engine (VP9/AV1, max. 1080p60 - user requirement).
    VP9 before AV1 (same resolution): less CPU (measured 8.5x vs 6.3x real time at 1080p60)."""
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
            # original audio first (user requirement 2026-11-04: never auto-translated audio tracks)
            auds.append(audio_rank(f) + (f,))
    if not vids or not auds:
        return None
    v = max(vids, key=lambda t: t[:4])[4]
    a = max(auds, key=lambda t: t[:4])[4]
    return {"video": v["url"], "audio": a["url"], "height": v.get("height"), "fps": v.get("fps"),
            "vcodec": (v.get("vcodec") or "").split(".")[0], "acodec": (a.get("acodec") or "").split(".")[0],
            "alang": audio_lang(a)}

def resolve(vid, live, pool):
    web, vr, _, emb = pools[pool]
    u = "https://www.youtube.com/watch?v=" + vid
    # one player request per step; the next only if the previous failed (never after a bot check)
    chain = [vr, web] if live else [web, emb, vr]
    last = None
    for ydl in chain:
        try:
            t0 = time.time()
            info = ydl.extract_info(u, download=False)
            dt = time.time() - t0
            if dt > 6:   # make slow resolutions traceable (client, format count, duration)
                log("slow %s via %s: %.1fs, %d formats, live=%s" % (vid, {vr: "vr", emb: "web_embedded"}.get(ydl, "mweb"), dt,
                    len(info.get("formats") or []), bool(info.get("is_live"))))
            r = summarize(info)
            note_result(False)
            if not live and ydl is vr and r.get("format") == "18":
                r["lowq"] = True
            return r
        except Exception as e:
            last = e
            log("%s via %s: %s" % (vid, {vr: "vr", emb: "web_embedded"}.get(ydl, "mweb"), str(e)[:200]))
            if is_bot_check(e):   # the IP is flagged: the next client would only add a request
                note_result(True)
                break
    raise last or RuntimeError("unknown error")

def run(job):
    """Run the job in its own pool. If, while it waited, a playback request overtook it,
    take over that result instead of resolving twice -
    even if that job is already done and removed from `jobs` (superseded_by)."""
    try:
        other = None
        with pools[job.pool][2]:
            with jobs_lock:
                job.started = True
                cur = jobs.get(job.key)
                other = job.superseded_by or (cur if cur is not None and cur is not job else None)
            if other is None:
                if job.pool == "bg" and time.time() - job.created > BG_MAX_WAIT:
                    job.error = RuntimeError("background job dropped (waited too long)")
                elif job.pool == "bg" and blocked_until():
                    job.error = RuntimeError("Sign in to confirm you're not a bot (paused, no request sent)")
                else:
                    try:
                        job.result = resolve(job.key[0], job.key[1], job.pool)
                    except Exception as e:
                        job.error = e
        if other is not None:
            other.ev.wait(120)
            job.result, job.error = other.result, other.error
    except BaseException as e:   # never leave a job hanging without a result
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
    # the sidecar's address for PO tokens (its port changes with every sidecar start); read by
    # the provider plugin at token time. Empty = sidecar down: yt-dlp goes on without a token.
    os.environ["SOFA_POT_URL"] = req.get("pot") or ""
    if not re.match(r"^[A-Za-z0-9_-]{11}$", vid):
        emit({"rid": rid, "error": "invalid video ID"}); return
    t0 = time.time()
    key, pool = (vid, bool(req.get("live"))), ("fg" if req.get("prio", True) else "bg")
    with jobs_lock:
        job = jobs.get(key)
        mine = job is None or (pool == "fg" and job.pool == "bg" and not job.started)
        if mine:
            new = Job(key, pool)
            if job is not None:
                job.superseded_by = new   # the waiting background job later takes over this result
            job = jobs[key] = new
    if mine:
        run(job)
    else:
        job.ev.wait(120)
    if job.result is not None:
        r = dict(job.result)
        r["rid"], r["secs"], r["pool"] = rid, round(time.time() - t0, 2), pool + ("" if mine else "+shared")
        r["blocked_until"] = blocked_until()
        emit(r)
    else:
        msg = str(job.error or "timeout")
        m = re.search(r"ERROR: \[youtube\] [^:]+: (.*)", msg)
        emit({"rid": rid, "error": (m.group(1) if m else msg)[:300], "blocked_until": blocked_until()})

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
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except Exception:
        continue
    threading.Thread(target=handle, args=(req,), daemon=True).start()
