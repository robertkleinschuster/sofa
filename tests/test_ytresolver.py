# Offline-Tests der Auswahllogik von res/ytresolver.py (Tonspur, DASH, Untertitel, Ergebnis).
# KEIN Netz, kein yt_dlp: ytresolver.py startet beim Import Pools + stdin-Loop, deshalb werden
# nur die reinen Funktionen per ast aus dem Quelltext geholt und in einem eigenen Namespace
# ausgeführt. Aufruf: tools/test-resolver
import ast, copy, json, os, re, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "res", "ytresolver.py")
FIXTURES = os.path.join(HERE, "fixtures")

PURE = ("expires_of", "summarize", "xtags", "audio_lang", "audio_pref", "audio_rank",
        "audio_tracks", "subtitle_tracks", "dash_pick")

def load_resolver():
    tree = ast.parse(open(SRC, encoding="utf-8").read(), SRC)
    body = []
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in PURE:
            body.append(node)
        elif isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "RESULT_VERSION" for t in node.targets):
            body.append(node)
    found = {n.name for n in body if isinstance(n, ast.FunctionDef)}
    missing = set(PURE) - found
    if missing:
        raise RuntimeError("ytresolver.py: Funktionen fehlen: %s" % ", ".join(sorted(missing)))
    logs = []
    ns = {"re": re, "time": time, "log": logs.append, "__name__": "ytresolver_pure"}
    exec(compile(ast.Module(body=body, type_ignores=[]), SRC, "exec"), ns)
    ns["_logs"] = logs
    return ns

R = load_resolver()

def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return json.load(f)

def aud(fid, acodec="opus", abr=130, xt=None, lang=None, lp=None, proto="https"):
    url = "https://x/videoplayback?itag=%s" % fid + ("&xtags=%s" % xt if xt else "")
    return {"format_id": fid, "vcodec": "none", "acodec": acodec, "abr": abr, "tbr": abr,
            "language": lang, "language_preference": lp, "protocol": proto, "url": url}

def vid(fid, vcodec, h, fps=30, tbr=1000, proto="https"):
    return {"format_id": fid, "vcodec": vcodec, "acodec": "none", "height": h, "fps": fps,
            "tbr": tbr, "protocol": proto, "url": "https://x/videoplayback?itag=%s" % fid}

def strip_lang(formats):
    """Wie eine Player-Antwort ohne audioTrack: yt-dlp kennt weder Sprache noch Original."""
    out = copy.deepcopy(formats)
    for f in out:
        f.pop("language", None); f.pop("language_preference", None)
    return out


class Xtags(unittest.TestCase):
    def test_parse(self):
        f = aud("251", xt="acont=original:lang=de-DE")
        self.assertEqual(R["xtags"](f), {"acont": "original", "lang": "de-DE"})
        self.assertEqual(R["xtags"]({"url": "https://x/videoplayback?itag=1"}), {})
        self.assertEqual(R["xtags"]({}), {})

    def test_audio_lang_fallback(self):
        self.assertEqual(R["audio_lang"](aud("1", xt="acont=dubbed-auto:lang=en-US")), "en-US")
        self.assertEqual(R["audio_lang"](aud("1", lang="fr", xt="lang=en-US")), "fr")

    def test_audio_pref(self):
        p = R["audio_pref"]
        self.assertEqual(p(aud("1", xt="acont=original")), 10)
        self.assertEqual(p(aud("1", xt="acont=dubbed-auto", lp=10)), -1)   # xtags schlägt language_preference
        self.assertEqual(p(aud("1", xt="acont=dubbed")), -1)
        self.assertEqual(p(aud("1", xt="acont=descriptive")), -10)
        self.assertEqual(p(aud("1", lp=5)), 5)
        self.assertEqual(p(aud("1")), 0)


class OriginalAudio(unittest.TestCase):
    """(1) Original-Ton vor KI-Synchronfassung – auch ohne language/language_preference."""
    def setUp(self):
        self.info = fixture("dagi-dubbed.json")

    def test_fixture_with_metadata(self):
        d = R["dash_pick"](self.info["formats"])
        self.assertIn("acont=original", d["audio"])
        self.assertEqual(d["alang"], "de-DE")

    def test_xtags_only(self):
        fm = strip_lang(self.info["formats"])
        d = R["dash_pick"](fm)
        self.assertIn("itag=251&xtags=acont=original", d["audio"])
        self.assertEqual(d["alang"], "de-DE")
        self.assertEqual(d["acodec"], "opus")
        tr = R["audio_tracks"](fm)
        self.assertEqual([t["lang"] for t in tr], ["de-DE", "en-US"])

    def test_dub_wins_nothing_even_with_higher_bitrate(self):
        fm = [vid("248", "vp9", 1080),
              aud("251-0", abr=300, xt="acont=dubbed-auto:lang=en-US"),
              aud("251-1", abr=50, xt="acont=original:lang=de-DE")]
        self.assertEqual(R["dash_pick"](fm)["alang"], "de-DE")


class AudioTracks(unittest.TestCase):
    """(2) Auswahl „Ton“: Original zuerst, Synchronfassung markiert, <2 Sprachen -> []."""
    def test_fixture(self):
        tr = R["audio_tracks"](fixture("dagi-dubbed.json")["formats"])
        self.assertEqual(len(tr), 2)
        de, en = tr
        self.assertEqual((de["lang"], de["original"], de["dubbed"]), ("de-DE", True, False))
        self.assertEqual((en["lang"], en["original"], en["dubbed"]), ("en-US", False, True))
        self.assertIn("itag=251", de["url"])   # Opus vor AAC bei gleicher Sprache
        self.assertNotIn("m3u8", de["url"] + en["url"])

    def test_original_first_regardless_of_name(self):
        fm = [aud("a", xt="acont=dubbed-auto:lang=de-DE"), aud("b", xt="acont=original:lang=sv"),
              aud("c", xt="acont=descriptive:lang=sv-x-desc")]
        tr = R["audio_tracks"](fm)
        self.assertEqual([t["lang"] for t in tr], ["sv", "de-DE", "sv-x-desc"])
        self.assertTrue(tr[2]["described"]); self.assertFalse(tr[2]["dubbed"])

    def test_single_language(self):
        fm = [aud("251", xt="acont=original:lang=de"), aud("140", acodec="mp4a.40.2", xt="acont=original:lang=de")]
        self.assertEqual(R["audio_tracks"](fm), [])
        self.assertEqual(R["audio_tracks"]([aud("251"), aud("140", acodec="mp4a.40.2")]), [])

    def test_ignores_hls_and_muxed(self):
        fm = [aud("251", xt="acont=original:lang=de"),
              aud("233", xt="acont=dubbed-auto:lang=en", proto="m3u8_native"),
              dict(vid("18", "avc1.42001E", 360), acodec="mp4a.40.2", language="en")]
        self.assertEqual(R["audio_tracks"](fm), [])


class DashPick(unittest.TestCase):
    """(3) Video: VP9 vor AV1 bei gleicher Auflösung, höchstens 1080p60."""
    A = [aud("251", xt="acont=original:lang=de-DE")]

    def test_vp9_before_av1(self):
        fm = [vid("399", "av01.0.09M.08", 1080, 60, tbr=600), vid("303", "vp9", 1080, 60, tbr=400)] + self.A
        d = R["dash_pick"](fm)
        self.assertIn("itag=303", d["video"])
        self.assertEqual((d["vcodec"], d["height"], d["fps"]), ("vp9", 1080, 60))
        fm[1]["vcodec"] = "vp09.00.41.08"
        self.assertEqual(R["dash_pick"](fm)["vcodec"], "vp09")

    def test_resolution_beats_codec(self):
        fm = [vid("399", "av01.0.09M.08", 1080, 60), vid("247", "vp9", 720, 60)] + self.A
        self.assertEqual(R["dash_pick"](fm)["vcodec"], "av01")

    def test_limits(self):
        fm = [vid("315", "vp9", 2160, 60), vid("308", "vp9", 1440, 60), vid("vp120", "vp9", 1080, 120),
              vid("248", "vp9", 1080, 30), vid("137", "avc1.640028", 1080, 60),
              vid("hls", "vp09.00.40.08", 1080, 60, proto="m3u8_native")] + self.A
        d = R["dash_pick"](fm)
        self.assertIn("itag=248", d["video"])
        self.assertEqual((d["height"], d["fps"]), (1080, 30))
        self.assertEqual(d["alang"], "de-DE")

    def test_fixture(self):
        d = R["dash_pick"](fixture("dagi-dubbed.json")["formats"])
        self.assertIn("itag=399", d["video"])   # nur AV1 in 1080p60, VP9 nur 360p
        self.assertEqual((d["height"], d["fps"], d["acodec"]), (1080, 60, "opus"))

    def test_none(self):
        self.assertIsNone(R["dash_pick"]([vid("137", "avc1.640028", 1080)] + self.A))
        self.assertIsNone(R["dash_pick"]([vid("248", "vp9", 1080)]))
        self.assertIsNone(R["dash_pick"]([]))


class Drc(unittest.TestCase):
    """(6) DRC-Spuren (Dynamikkompression) nur nachrangig."""
    def test_drc_by_format_id(self):
        fm = [vid("248", "vp9", 1080), aud("251-drc", abr=200, xt="acont=original:lang=de"),
              aud("251", abr=120, xt="acont=original:lang=de")]
        self.assertTrue(R["dash_pick"](fm)["audio"].endswith("itag=251&xtags=acont=original:lang=de"))

    def test_drc_by_xtags(self):
        fm = [vid("248", "vp9", 1080), aud("251a", abr=200, xt="acont=original:drc=1:lang=de"),
              aud("251b", abr=120, xt="acont=original:lang=de")]
        self.assertIn("itag=251b", R["dash_pick"](fm)["audio"])

    def test_original_drc_before_dub(self):
        fm = [vid("248", "vp9", 1080), aud("251-drc", xt="acont=original:lang=de"),
              aud("251", xt="acont=dubbed-auto:lang=en")]
        self.assertEqual(R["dash_pick"](fm)["alang"], "de")

    def test_audio_tracks_prefers_non_drc(self):
        fm = [aud("251-drc", abr=200, xt="acont=original:lang=de"), aud("251", abr=120, xt="acont=original:lang=de"),
              aud("250", xt="acont=dubbed-auto:lang=en")]
        de = R["audio_tracks"](fm)[0]
        self.assertTrue(de["url"].endswith("itag=251&xtags=acont=original:lang=de"))


class Summarize(unittest.TestCase):
    """(4) Ergebnis: Version, dash, dlaudio nur bei mehreren Tonspuren und nur AAC-Original/Standard."""
    def setUp(self):
        R["_logs"].clear()

    def info(self, formats, **kw):
        i = {"id": "abcdefghijk", "url": "https://x/hls/itag/301-1/index.m3u8", "format_id": "301-1",
             "height": 1080, "fps": 60, "duration": 100, "title": "t", "language": "de",
             "formats": formats}
        i.update(kw)
        return i

    def test_fixture(self):
        fx = fixture("dagi-dubbed.json")
        r = R["summarize"](self.info(fx["formats"], language=fx["language"],
                                     subtitles=fx["subtitles"], automatic_captions=fx["automatic_captions"]))
        self.assertEqual(r["v"], R["RESULT_VERSION"])
        self.assertEqual(r["alt"], ["https://x/videoplayback?itag=18"])
        self.assertEqual(r["dash"]["alang"], "de-DE")
        self.assertEqual(len(r["dash"]["audios"]), 2)
        self.assertEqual(r["dlaudio"], "https://x/videoplayback?itag=140&xtags=acont=original:lang=de-DE")
        self.assertFalse(r["live"])
        self.assertTrue(any("audio abcdefghijk" in m for m in R["_logs"]))

    def test_dlaudio_xtags_only(self):
        r = R["summarize"](self.info(strip_lang(fixture("dagi-dubbed.json")["formats"])))
        self.assertIn("acont=original", r["dlaudio"])

    def test_no_dlaudio_single_language(self):
        fm = [vid("248", "vp9", 1080), aud("251", xt="acont=original:lang=de"),
              aud("140", acodec="mp4a.40.2", xt="acont=original:lang=de")]
        r = R["summarize"](self.info(fm))
        self.assertEqual(r["v"], R["RESULT_VERSION"])
        self.assertEqual(r["dash"]["audios"], [])
        self.assertNotIn("dlaudio", r)

    def test_no_dlaudio_without_aac(self):
        fm = [vid("248", "vp9", 1080), aud("251", xt="acont=original:lang=de"),
              aud("250", xt="acont=dubbed-auto:lang=en")]
        self.assertNotIn("dlaudio", R["summarize"](self.info(fm)))

    def test_no_dlaudio_if_best_aac_is_dub(self):
        # Original nur als Opus, AAC nur synchronisiert -> lieber nichts ändern
        fm = [vid("248", "vp9", 1080), aud("251", xt="acont=original:lang=de"),
              aud("140", acodec="mp4a.40.2", xt="acont=dubbed-auto:lang=en")]
        self.assertNotIn("dlaudio", R["summarize"](self.info(fm)))

    def test_no_dlaudio_if_unknown(self):
        # zwei Sprachen, aber keine Kennzeichnung (pref 0) -> unsicher, kein dlaudio
        fm = [vid("248", "vp9", 1080), aud("140a", acodec="mp4a.40.2", lang="de"),
              aud("140b", acodec="mp4a.40.2", lang="en")]
        r = R["summarize"](self.info(fm))
        self.assertEqual(len(r["dash"]["audios"]), 2)
        self.assertNotIn("dlaudio", r)

    def test_dlaudio_standard_track(self):
        # yt-dlp language_preference 5 = Standardspur ohne Original-Kennzeichnung
        fm = [vid("248", "vp9", 1080), aud("140a", acodec="mp4a.40.2", lang="de", lp=5),
              aud("140b", acodec="mp4a.40.2", lang="en", lp=-1)]
        self.assertTrue(R["summarize"](self.info(fm))["dlaudio"].endswith("itag=140a"))

    def test_dlaudio_skips_hls_audio(self):
        fm = [vid("248", "vp9", 1080), aud("251", xt="acont=original:lang=de"), aud("250", xt="acont=dubbed-auto:lang=en"),
              aud("233", acodec="mp4a.40.5", xt="acont=original:lang=de", proto="m3u8_native")]
        self.assertNotIn("dlaudio", R["summarize"](self.info(fm)))

    def test_no_dash(self):
        fm = [dict(vid("18", "avc1.42001E", 360), acodec="mp4a.40.2"),
              dict(vid("95", "avc1.4d401f", 720, proto="m3u8_native"), acodec="mp4a.40.2",
                   url="https://x/hls/itag/95/index.m3u8")]
        r = R["summarize"](self.info(fm, url="https://x/hls/itag/95/index.m3u8"))
        self.assertNotIn("dash", r); self.assertNotIn("dlaudio", r)
        self.assertEqual(r["alt"], ["https://x/videoplayback?itag=18"])   # gleiche URL nicht doppelt
        self.assertEqual(r["v"], R["RESULT_VERSION"])

    def test_expires(self):
        r = R["summarize"](self.info([], url="https://x/videoplayback?expire=1762190000&itag=18"))
        self.assertEqual(r["expires"], 1762190000)
        r = R["summarize"](self.info([], url="https://x/api/manifest/hls_playlist/expire/1762190001/ei/x/index.m3u8"))
        self.assertEqual(r["expires"], 1762190001)

    def test_no_url(self):
        with self.assertRaises(RuntimeError):
            R["summarize"](self.info([], url=None))


def caps(*langs):
    return {l: [{"ext": "json3", "url": "https://x/j?lang=" + l}, {"ext": "vtt", "url": "https://x/v?lang=" + l}]
            for l in langs}

class Subtitles(unittest.TestCase):
    """(5) Untertitel: manuelle zuerst, Übersetzung ins Deutsche nur bei fremdsprachigem Video."""
    def kinds(self, info):
        return [(t["lang"], t["kind"]) for t in R["subtitle_tracks"](info)]

    def test_fixture_german_video(self):
        fx = fixture("dagi-dubbed.json")
        self.assertEqual(self.kinds(fx), [("de", "auto")])

    def test_german_video_no_orig_caption(self):
        info = {"language": "de-DE", "automatic_captions": caps("de", "en")}
        self.assertEqual(self.kinds(info), [])

    def test_english_video_translated(self):
        info = {"language": "en", "automatic_captions": caps("en-orig", "en", "de", "fr")}
        tr = R["subtitle_tracks"](info)
        self.assertEqual([(t["lang"], t["kind"]) for t in tr], [("en", "auto"), ("de", "translated")])
        self.assertEqual(tr[1]["url"], "https://x/v?lang=de")

    def test_unknown_language_translated(self):
        info = {"automatic_captions": caps("fr-orig", "de")}
        self.assertEqual(self.kinds(info), [("fr", "auto"), ("de", "translated")])

    def test_manual_first_and_no_translation_with_manual_de(self):
        info = {"language": "en", "subtitles": caps("de-DE", "en"), "automatic_captions": caps("en-orig", "de")}
        self.assertEqual(self.kinds(info), [("de-DE", "manual"), ("en", "manual"), ("en", "auto")])

    def test_manual_other_language_keeps_translation(self):
        info = {"language": "en", "subtitles": caps("en"), "automatic_captions": caps("en-orig", "de")}
        self.assertEqual(self.kinds(info), [("en", "manual"), ("en", "auto"), ("de", "translated")])

    def test_live_chat_ignored(self):
        info = {"language": "en",
                "subtitles": {"live_chat": [{"ext": "vtt", "url": "https://x/chat"}], **caps("en")}}
        self.assertEqual(self.kinds(info), [("en", "manual")])

    def test_only_vtt(self):
        info = {"language": "en", "subtitles": {"en": [{"ext": "json3", "url": "https://x/j"}]},
                "automatic_captions": {"de": [{"ext": "srv3", "url": "https://x/s"}]}}
        self.assertEqual(self.kinds(info), [])

    def test_empty(self):
        self.assertEqual(R["subtitle_tracks"]({}), [])
        self.assertEqual(R["subtitle_tracks"]({"subtitles": None, "automatic_captions": None}), [])


if __name__ == "__main__":
    unittest.main()
