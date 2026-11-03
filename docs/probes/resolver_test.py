# Prototype of a long-lived resolver: one YoutubeDL instance, many extract_info calls
import time, sys
t0=time.time()
from yt_dlp.extractor.youtube.jsc._builtin import ejs
ejs.EJSBaseJCP._ENABLE_PREPROCESSED_PLAYER_CACHE = True
import yt_dlp
opts={"quiet":True,"no_warnings":True,"skip_download":True,"cachedir":sys.argv[2],"cookiefile":sys.argv[1],
      "js_runtimes":{"quickjs":{"path":"/opt/local/bin/qjs"}},
      "extractor_args":{"youtube":{"player_client":["web_embedded"],"player_skip":["webpage"]},
                        "youtubepot-bgutilscript":{"script_path":["/nonexistent/generate_once.js"]}},
      "format":"best[height<=1080][vcodec^=avc1][acodec!=none][protocol^=m3u8]/best[height<=720][vcodec^=avc1][acodec!=none]/18",
      "check_formats":False}
ydl=yt_dlp.YoutubeDL(opts); print("init %.2fs"%(time.time()-t0))
for v in sys.argv[3:]:
    t=time.time()
    try:
        info=ydl.extract_info("https://www.youtube.com/watch?v="+v,download=False)
        rf=info.get("requested_formats") or [info]
        print("%s %.2fs -> format %s %s %sp live=%s proto=%s"%(v,time.time()-t,info.get("format_id"),info.get("vcodec"),info.get("height"),info.get("is_live"),info.get("protocol")))
    except Exception as e: print(v,"ERR",str(e)[:150],"%.2fs"%(time.time()-t))
