#!/opt/local/bin/python3 -I
# -*- coding: utf-8 -*-
"""
lounge_probe.py - YouTube Lounge API (Link with TV code) receiver probe for Sofa.

Stdlib only. Acts as a LOUNGE_SCREEN (the TV side) exactly like the open-source
receivers (yt-cast-receiver, plaincast) do, logs every frame, and answers the
phone with a *simulated* player (a clock, no real video), so the YouTube app on
the phone shows a working remote.

Usage (run with `unset DYLD_INSERT_LIBRARIES` first in the Claude shell):

  python3 -I lounge_probe.py                 # pair + wait for a phone forever
  python3 -I lounge_probe.py --duration 120  # just keep the long-poll 2 min
  python3 -I lounge_probe.py --self-test     # + built-in sender (pyytlounge-
                                             #   style REMOTE_CONTROL) that
                                             #   resolves the code, connects
                                             #   and sends setPlaylist/pause/
                                             #   seekTo/play - no phone needed
  --state FILE   where screen_id/device_id are persisted
                 (default ~/Library/Caches/sofa-lounge-probe.json)
  --name NAME    screen name shown on the phone (default "Sofa")
  --new-screen   throw away the stored screen id (forces new pairing)
  --raw          also print raw chunk bytes

Phone test: run without --self-test, on the phone open YouTube -> Settings ->
"Watch on TV" / "Auf TV ansehen" -> "Link with TV code" / "Mit TV-Code
verbinden", enter the 12 digits printed here, then cast a video.
"""
import argparse, json, os, queue, random, string, sys, threading, time, uuid
import http.client, ssl, urllib.parse

HOST = "www.youtube.com"
API = "/api/lounge"
CTX = ssl.create_default_context()
T0 = time.time()
LOG_LOCK = threading.Lock()


def log(tag, msg):
    with LOG_LOCK:
        print("%7.2f %-6s %s" % (time.time() - T0, tag, msg), flush=True)


def zx():
    return "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(12))


def request(method, path, params=None, body=None, timeout=30, stream=False):
    """One HTTPS request on its own connection. Returns (status, reason, headers, body|resp)."""
    if params:
        path = path + "?" + urllib.parse.urlencode(params)
    conn = http.client.HTTPSConnection(HOST, 443, timeout=timeout, context=CTX)
    headers = {}
    data = None
    if body is not None:
        data = urllib.parse.urlencode(body).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    conn.request(method, path, body=data, headers=headers)
    resp = conn.getresponse()
    if stream:
        return resp.status, resp.reason, resp.getheaders(), resp
    raw = resp.read()
    conn.close()
    return resp.status, resp.reason, resp.getheaders(), raw


# --------------------------------------------------------------------------
# Framing:  "<len>\n<json-array>"  repeated; len counts the JSON *including*
# its trailing "\n". We read the length line, then exactly len bytes and
# also report whether len matched bytes or UTF-16 chars.
# --------------------------------------------------------------------------
class Framer:
    def __init__(self, fp, raw=False, tag="frame"):
        self.fp, self.raw, self.tag = fp, raw, tag

    def frames(self):
        while True:
            line = self.fp.readline()
            if not line:
                return
            s = line.strip()
            if not s:
                continue
            n = int(s)
            data = b""
            # Length is in characters of the JSON text. Read bytes until we
            # have n characters (identical for ASCII; differs for UTF-8).
            while True:
                try:
                    txt = data.decode("utf-8")
                except UnicodeDecodeError:
                    txt = None
                if txt is not None and len(txt) >= n:
                    break
                chunk = self.fp.read(1) if txt is None or n - len(txt) <= 0 else self.fp.read(n - len(txt))
                if not chunk:
                    return
                data += chunk
            if self.raw:
                log("raw", "%d %r" % (n, data[:400]))
            if len(data) != n:
                log(self.tag, "note: len=%d chars but %d bytes (UTF-8) - length is in chars" % (n, len(data)))
            yield json.loads(txt)


def parse_chunk_text(text):
    """Parse a complete (non-streamed) bind response body into a list of [aid, [name, *args]]."""
    import io
    out = []
    for arr in Framer(io.BytesIO(text)).frames():
        out.extend(arr)
    return out


def redact(s, keep=6):
    s = str(s)
    return s if len(s) <= keep * 2 else "%s...%s(len %d)" % (s[:keep], s[-3:], len(s))


# --------------------------------------------------------------------------
# Receiver (LOUNGE_SCREEN)
# --------------------------------------------------------------------------
class Screen:
    def __init__(self, a):
        self.a = a
        self.state_file = os.path.expanduser(a.state)
        self.screen_id = None
        self.device_id = None
        self.lounge_token = None
        self.token_expiry = 0
        self.token_refresh_ms = 0
        self.sid = None
        self.gsessionid = None
        self.rid = 0
        self.aid = -1          # last incoming array index seen (AID for the GET)
        self.ofs = 0           # number of outgoing maps sent in this SID
        self.lock = threading.Lock()
        self.inbox = queue.Queue()
        self.stop = threading.Event()
        self.code = None
        # simulated player
        self.videos, self.index, self.list_id = [], 0, ""
        self.pstate, self.pos, self.pos_t, self.duration = -1, 0.0, time.time(), 212.0
        self.volume, self.muted = 100, False
        self.remotes = {}
        self.greeted = set()

    # ---- persistence -------------------------------------------------------
    def load(self):
        try:
            d = json.load(open(self.state_file))
            if not self.a.new_screen:
                self.screen_id = d.get("screenId")
            self.device_id = d.get("deviceId")
        except Exception:
            pass
        if not self.device_id:
            self.device_id = str(uuid.uuid4())

    def save(self):
        d = {"screenId": self.screen_id, "deviceId": self.device_id, "name": self.a.name,
             "loungeToken": self.lounge_token, "expiration": self.token_expiry}
        os.makedirs(os.path.dirname(self.state_file), exist_ok=True)
        with open(self.state_file, "w") as f:
            json.dump(d, f, indent=1)

    # ---- pairing endpoints --------------------------------------------------
    def generate_screen_id(self):
        st, rs, _, body = request("GET", API + "/pairing/generate_screen_id")
        log("pair", "generate_screen_id -> %d %s body=%s" % (st, rs, redact(body.decode())))
        if st != 200:
            raise RuntimeError("generate_screen_id failed")
        self.screen_id = body.decode().strip()

    def get_lounge_token(self):
        st, rs, _, body = request("POST", API + "/pairing/get_lounge_token_batch",
                                  body={"screen_ids": self.screen_id})
        if st != 200:
            raise RuntimeError("get_lounge_token_batch %d %s" % (st, rs))
        scr = json.loads(body)["screens"][0]
        shown = dict(scr, loungeToken=redact(scr.get("loungeToken")))
        log("pair", "get_lounge_token_batch -> %d %s" % (st, json.dumps(shown)))
        if not scr.get("loungeToken"):
            raise RuntimeError("no loungeToken (screen id invalid?)")
        self.lounge_token = scr["loungeToken"]
        self.token_expiry = scr.get("expiration", 0)
        self.token_refresh_ms = scr.get("refreshIntervalInMillis") or scr.get("refreshIntervalMs") or 1123200000

    def get_pairing_code(self):
        st, rs, _, body = request("POST", API + "/pairing/get_pairing_code", params={"ctx": "pair"}, body={
            "access_type": "permanent", "app": self.a.app, "lounge_token": self.lounge_token,
            "screen_id": self.screen_id, "screen_name": self.a.name, "device_id": self.device_id})
        code = body.decode().strip()
        log("pair", "get_pairing_code -> %d %s body=%r" % (st, rs, code))
        if st != 200 or not code.isdigit():
            raise RuntimeError("get_pairing_code failed")
        self.code = code
        return code

    # ---- bind channel -------------------------------------------------------
    def common(self):
        return {"device": "LOUNGE_SCREEN", "id": self.device_id, "obfuscatedGaiaId": "",
                "name": self.a.name, "app": self.a.app, "theme": self.a.theme,
                "capabilities": "dsp,mic,dpa,ntb", "cst": "m", "mdxVersion": "2",
                "loungeIdToken": self.lounge_token, "VER": "8", "v": "2", "t": "1"}

    def device_info(self):
        return json.dumps({"brand": "Apple", "model": "iMac", "year": 0, "os": "Mac OS X",
                           "osVersion": "10.9.5", "chipset": "", "clientName": "TVHTML5",
                           "dialAdditionalDataSupportLevel": "unsupported",
                           "mdxDialServerType": "MDX_DIAL_SERVER_TYPE_UNKNOWN"}, separators=(",", ":"))

    def open_session(self):
        with self.lock:
            self.rid = random.randint(10000, 89999)
            self.aid, self.ofs, self.sid, self.gsessionid = -1, 0, None, None
            p = dict(self.common(), deviceInfo=self.device_info(), RID=str(self.rid), CVER="1", zx=zx())
            self.rid += 1
        st, rs, hdr, body = request("POST", API + "/bc/bind", params=p, body={"count": "0"})
        log("bind", "initial POST -> %d %s (%d bytes)" % (st, rs, len(body)))
        if st != 200:
            log("bind", "body: %r" % body[:300])
            return st
        for aid, msg in parse_chunk_text(body):
            self.on_raw(aid, msg, initial=True)
        if not (self.sid and self.gsessionid):
            raise RuntimeError("no SID/gsessionid in bind response")
        return 200

    def long_poll(self):
        """Blocking long-poll GET loop; reconnects per the rules in the doc."""
        failures = 0
        while not self.stop.is_set():
            with self.lock:
                p = dict(self.common(), RID="rpc", SID=self.sid, CI="0", AID=str(self.aid),
                         gsessionid=self.gsessionid, TYPE="xmlhttp", zx=zx())
            t = time.time()
            try:
                st, rs, hdr, resp = request("GET", API + "/bc/bind", params=p, timeout=60, stream=True)
            except Exception as e:
                failures += 1
                log("poll", "connect error %r, retry in %ds" % (e, min(30, failures ** 2)))
                time.sleep(min(30, failures ** 2))
                continue
            if st != 200:
                body = resp.read()
                log("poll", "GET -> %d %s body=%r" % (st, rs, body[:160]))
                if st in (400, 404, 410):     # Unknown SID / Gone -> new session
                    if st == 410 or b"Unknown SID" in body or st == 404:
                        self.restart_session(refresh_token=(st == 410))
                        continue
                if st == 401:                 # token expired
                    self.restart_session(refresh_token=True)
                    continue
                failures += 1
                time.sleep(min(60, failures ** 2))
                continue
            failures = 0
            log("poll", "GET open (AID=%d) chunked=%s" % (self.aid, dict(hdr).get("Transfer-Encoding", dict(hdr).get("transfer-encoding"))))
            try:
                for arr in Framer(resp, raw=self.a.raw, tag="poll").frames():
                    for aid, msg in arr:
                        self.on_raw(aid, msg)
                    if self.stop.is_set():
                        break
                log("poll", "GET closed by server after %.1fs -> reconnect" % (time.time() - t))
            except Exception as e:
                log("poll", "stream error after %.1fs: %r -> reconnect" % (time.time() - t, e))

    def restart_session(self, refresh_token=False):
        log("bind", "restarting session (refresh_token=%s)" % refresh_token)
        if refresh_token:
            self.get_lounge_token()
            self.save()
        st = self.open_session()
        if st != 200:
            raise RuntimeError("could not re-open session: %d" % st)

    def send(self, msgs):
        """msgs: list of (name, dict). One POST, count=len, ofs=running counter."""
        with self.lock:
            body = {"count": str(len(msgs)), "ofs": str(self.ofs)}
            for i, (name, args) in enumerate(msgs):
                body["req%d__sc" % i] = name
                for k, v in args.items():
                    body["req%d_%s" % (i, k)] = v if isinstance(v, str) else json.dumps(v) if isinstance(v, bool) else str(v)
            p = dict(self.common(), deviceInfo=self.device_info(), SID=self.sid, RID=str(self.rid),
                     AID=str(self.aid), gsessionid=self.gsessionid, zx=zx())
            self.rid += 1
            self.ofs += len(msgs)
            ofs = body["ofs"]
        st, rs, _, resp = request("POST", API + "/bc/bind", params=p, body=body)
        log("send", "ofs=%s %s -> %d %s %r" % (ofs, " + ".join("%s%s" % (n, json.dumps(a)) for n, a in msgs),
                                                 st, rs, resp[:80]))
        return st

    # ---- incoming ---------------------------------------------------------
    def on_raw(self, aid, msg, initial=False):
        name, args = msg[0], msg[1:]
        if aid <= self.aid and not initial:
            log("recv", "duplicate/old aid %d %s (last %d) - ignored" % (aid, name, self.aid))
            return
        self.aid = max(self.aid, aid)
        if name == "c":
            self.sid = args[0]
            log("recv", "[%d] c SID=%s extra=%r" % (aid, redact(args[0]), args[1:]))
        elif name == "S":
            self.gsessionid = args[0]
            log("recv", "[%d] S gsessionid=%s" % (aid, redact(args[0])))
        elif name == "noop":
            log("recv", "[%d] noop" % aid)
        else:
            payload = args[0] if args else {}
            log("recv", "[%d] %s %s" % (aid, name, json.dumps(payload, ensure_ascii=False)[:600]))
            self.inbox.put((aid, name, payload))

    # ---- simulated player ---------------------------------------------------
    def cur_pos(self):
        if self.pstate == 1:
            return min(self.duration, self.pos + (time.time() - self.pos_t))
        return self.pos

    def set_state(self, st, pos=None):
        self.pos = self.cur_pos() if pos is None else pos
        self.pos_t = time.time()
        self.pstate = st

    def m_state(self):
        p = "%.3f" % self.cur_pos()
        d = "%.3f" % self.duration
        return ("onStateChange", {"currentTime": p, "duration": d, "state": str(self.pstate),
                                  "loadedTime": d, "seekableStartTime": "0", "seekableEndTime": d,
                                  "cpn": "sofaprobe0000000"})

    def m_now(self):
        if not self.videos:
            return ("nowPlaying", {})
        p = "%.3f" % self.cur_pos()
        d = "%.3f" % self.duration
        a = {"videoId": self.videos[self.index], "currentTime": p, "duration": d, "state": str(self.pstate),
             "loadedTime": d, "seekableStartTime": "0", "seekableEndTime": d, "cpn": "sofaprobe0000000",
             "currentIndex": str(self.index)}
        if self.list_id:
            a["listId"] = self.list_id
        return ("nowPlaying", a)

    def m_nav(self):
        return ("onHasPreviousNextChanged", {"hasPrevious": str(self.index > 0).lower(),
                                             "hasNext": str(self.index + 1 < len(self.videos)).lower()})

    def m_vol(self):
        return ("onVolumeChanged", {"volume": str(self.volume), "muted": str(self.muted).lower()})

    def handle(self, aid, name, p):
        out = []
        if name in ("loungeStatus", "remoteConnected", "remoteDisconnected"):
            if name == "loungeStatus":
                try:
                    devs = json.loads(p.get("devices", "[]"))
                except Exception:
                    devs = []
                self.remotes = {d["id"]: d.get("name") for d in devs if d.get("type") == "REMOTE_CONTROL"}
                log("info", "remotes in lounge: %s" % (self.remotes or "none"))
                # note: may contain stale remotes; greet only ids we have not greeted yet
                if not set(self.remotes) - self.greeted:
                    return
                self.greeted |= set(self.remotes)
            elif name == "remoteConnected":
                self.remotes[p.get("id")] = p.get("name")
                log("info", "REMOTE CONNECTED: %s (user %s, app %s, caps %s)" % (
                    p.get("name"), p.get("user"), p.get("app"), p.get("capabilities")))
                if p.get("id") in self.greeted:
                    return
                self.greeted.add(p.get("id"))
            else:
                self.remotes.pop(p.get("id"), None)
                self.greeted.discard(p.get("id"))
                log("info", "remote disconnected: %s" % p.get("name"))
                return
            out = [self.m_nav(), self.m_now(), self.m_state(), self.m_vol(),
                   ("onAutoplayModeChanged", {"autoplayMode": "UNSUPPORTED"})]
        elif name == "setPlaylist":
            vids = [v for v in p.get("videoIds", p.get("videoId", "")).split(",") if v]
            if p.get("videoId") and p["videoId"] not in vids:
                vids = [p["videoId"]]
            self.videos, self.list_id = vids, p.get("listId", "")
            try:
                self.index = int(p.get("currentIndex", "0"))
            except ValueError:
                self.index = 0
            if self.index < 0 or self.index >= len(vids):
                self.index = vids.index(p["videoId"]) if p.get("videoId") in vids else 0
            try:
                t0 = float(p.get("currentTime") or 0)
            except ValueError:
                t0 = 0.0
            log("info", "PLAY %s (index %d of %d, list %s, t=%.1f) ctt=%s" % (
                self.videos[self.index] if vids else None, self.index, len(vids), self.list_id or "-",
                t0, "yes" if p.get("ctt") else "no"))
            self.set_state(3, t0)                       # buffering first ...
            self.send([self.m_now(), self.m_state(), self.m_nav()])
            time.sleep(0.5)
            self.set_state(1, t0)                       # ... then playing
            out = [self.m_state(), self.m_now()]
        elif name == "updatePlaylist":
            vids = [v for v in p.get("videoIds", "").split(",") if v]
            cur = self.videos[self.index] if self.videos else None
            self.videos, self.list_id = vids, p.get("listId", self.list_id)
            self.index = vids.index(cur) if cur in vids else 0
            out = [self.m_now(), self.m_nav()]
        elif name == "pause":
            self.set_state(2); out = [self.m_state()]
        elif name == "play":
            self.set_state(1); out = [self.m_state()]
        elif name == "seekTo":
            self.set_state(self.pstate if self.pstate in (1, 2) else 2, float(p.get("newTime", 0)))
            out = [self.m_state()]
        elif name == "stopVideo":
            self.videos, self.index = [], 0
            self.set_state(-1, 0); out = [self.m_now()]
        elif name in ("next", "previous"):
            if self.videos:
                self.index = max(0, min(len(self.videos) - 1, self.index + (1 if name == "next" else -1)))
            self.set_state(1, 0); out = [self.m_now(), self.m_state(), self.m_nav()]
        elif name == "getNowPlaying":
            out = [self.m_now()]
        elif name == "getVolume":
            out = [self.m_vol()]
        elif name == "setVolume":
            if "delta" in p:
                self.volume = max(0, min(100, self.volume + int(p["delta"])))
            elif "volume" in p:
                self.volume = int(float(p["volume"]))
            if "muted" in p:
                self.muted = str(p["muted"]).lower() == "true"
            out = [self.m_vol()]
        elif name == "getSubtitlesTrack":
            out = [("onSubtitlesTrackChanged", {"videoId": self.videos[self.index] if self.videos else ""})]
        elif name == "setAutoplayMode":
            out = [("onAutoplayModeChanged", {"autoplayMode": "UNSUPPORTED"})]
        elif name == "loungeScreenDisconnected":
            pass
        else:
            log("info", "unhandled command %s" % name)
        if out:
            self.send(out)

    def worker(self):
        while not self.stop.is_set():
            try:
                aid, name, p = self.inbox.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                self.handle(aid, name, p)
            except Exception as e:
                log("err", "handling %s: %r" % (name, e))

    def code_refresher(self):
        # Codes live ~300 s (measured); yt-cast-receiver refreshes at 300 s, we use 240 s
        # so the displayed code always has >= 1 min left.
        while not self.stop.wait(240):
            try:
                c = self.get_pairing_code()
                log("pair", "NEW CODE: %s" % fmt_code(c))
            except Exception as e:
                log("err", "pairing code refresh: %r" % e)


def fmt_code(c):
    return " ".join(c[i:i + 3] for i in range(0, len(c), 3))


# --------------------------------------------------------------------------
# Self-test sender (REMOTE_CONTROL), same requests as pyytlounge.
# --------------------------------------------------------------------------
class Remote:
    def __init__(self, code, name="Sofa probe remote"):
        self.code, self.name = code, name
        self.id = str(uuid.uuid4())
        self.sid = self.gs = None
        self.aid = None
        self.ofs = 1
        self.events = []

    def common(self):
        return {"name": self.name, "loungeIdToken": self.token, "SID": self.sid, "AID": self.aid,
                "gsessionid": self.gs, "device": "REMOTE_CONTROL", "app": "youtube-desktop", "VER": "8", "v": "2"}

    def run(self, video="dQw4w9WgXcQ"):
        st, rs, _, body = request("POST", API + "/pairing/get_screen", body={"pairing_code": self.code})
        scr = json.loads(body)["screen"]
        shown = dict(scr, loungeToken=redact(scr["loungeToken"]), screenId=redact(scr["screenId"]))
        log("rmt", "get_screen(code) -> %d screen=%s" % (st, json.dumps(shown)))
        self.token = scr["loungeToken"]
        st, rs, _, body = request("POST", API + "/bc/bind",
                                  params={"RID": "1", "VER": "8", "CVER": "1", "auth_failure_option": "send_error"},
                                  body={"app": "web", "mdx-version": "3", "name": self.name, "id": self.id,
                                        "device": "REMOTE_CONTROL", "capabilities": "que,dsdtr,atp,vsp",
                                        "magnaKey": "cloudPairedDevice", "ui": "false", "theme": "cl",
                                        "loungeIdToken": self.token})
        for aid, msg in parse_chunk_text(body):
            if msg[0] == "c":
                self.sid = msg[1]
            elif msg[0] == "S":
                self.gs = msg[1]
            else:
                log("rmt", "initial [%d] %s %s" % (aid, msg[0], json.dumps(msg[1:])[:300]))
            self.aid = aid
        log("rmt", "bound as REMOTE_CONTROL (%d)" % st)
        threading.Thread(target=self.listen, daemon=True).start()
        time.sleep(3)
        for cmd, args, wait in [("setPlaylist", {"videoId": video, "videoIds": video, "currentIndex": "0",
                                                 "currentTime": "0", "listId": ""}, 4),
                                ("pause", {}, 3), ("seekTo", {"newTime": "42"}, 3), ("play", {}, 3),
                                ("getNowPlaying", {}, 3)]:
            self.cmd(cmd, args)
            time.sleep(wait)

    def cmd(self, c, args):
        body = {"count": "1", "ofs": str(self.ofs), "req0__sc": c}
        for k, v in args.items():
            body["req0_" + k] = v
        self.ofs += 1
        p = dict(self.common(), RID=str(self.ofs))
        st, rs, _, resp = request("POST", API + "/bc/bind", params=p, body=body)
        log("rmt", "-> %s %s : %d %s" % (c, json.dumps(args), st, rs))

    def listen(self):
        while True:
            p = dict(self.common(), RID="rpc", CI="0", TYPE="xmlhttp")
            st, rs, _, resp = request("GET", API + "/bc/bind", params=p, timeout=60, stream=True)
            if st != 200:
                log("rmt", "listen %d %s" % (st, rs)); return
            try:
                for arr in Framer(resp, tag="rmt").frames():
                    for aid, msg in arr:
                        self.aid = aid
                        if msg[0] != "noop":
                            log("rmt", "<- [%d] %s %s" % (aid, msg[0], json.dumps(msg[1:], ensure_ascii=False)[:300]))
                            self.events.append(msg[0])
            except Exception as e:
                log("rmt", "listen error %r" % e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", default="~/Library/Caches/sofa-lounge-probe.json")
    ap.add_argument("--name", default="Sofa")
    ap.add_argument("--app", default="sofa")
    ap.add_argument("--theme", default="cl")
    ap.add_argument("--duration", type=float, default=0, help="seconds, 0 = forever")
    ap.add_argument("--new-screen", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--raw", action="store_true")
    a = ap.parse_args()

    s = Screen(a)
    s.load()
    if not s.screen_id:
        s.generate_screen_id()
    else:
        log("pair", "reusing stored screen_id %s" % redact(s.screen_id))
    try:
        s.get_lounge_token()
    except Exception as e:
        log("pair", "stored screen id rejected (%r) -> generating a new one" % e)
        s.generate_screen_id()
        s.get_lounge_token()
    s.save()
    st = s.open_session()
    if st != 200:
        sys.exit("bind failed: %d" % st)
    code = s.get_pairing_code()
    print("\n   ===  TV CODE:  %s   ===   (name '%s')\n" % (fmt_code(code), a.name), flush=True)
    threading.Thread(target=s.long_poll, daemon=True).start()
    threading.Thread(target=s.worker, daemon=True).start()
    threading.Thread(target=s.code_refresher, daemon=True).start()
    if a.self_test:
        r = Remote(code)
        threading.Thread(target=r.run, daemon=True).start()
    try:
        end = time.time() + a.duration if a.duration else None
        while end is None or time.time() < end:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    s.stop.set()
    log("done", "rid=%d ofs=%d last AID=%d" % (s.rid, s.ofs, s.aid))


if __name__ == "__main__":
    main()
