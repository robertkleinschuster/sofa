# Moderne Codecs – Recherche (2026-11-03, Agent, nichts gebaut)

Legende: [V] auf dem Gerät geprüft, [D] Doku/Web, [W] Wissen/Schätzung.

## Hardware
- [V] iMac12,2, i5-2500S (Sandy Bridge, 4C/4T, 2,7 GHz, AVX1, kein AVX2), 16 GB, AMD Radeon HD 6770M 512 MB, 2560x1440.
- [W] Hardware-Decode nur H.264 (UVD3). VP9/AV1/HEVC nur Software.
- [W] Schätzung: VP9 1080p30 sicher, 1080p60 wahrscheinlich (hohe Last), 1440p60 grenzwertig; AV1 (dav1d SSSE3) 1080p30 ok, 1080p60 grenzwertig. → vor Entscheidung messen.

## Empfehlung: libmpv als zweite Engine (render API, OpenGL in CAOpenGLLayer), AVFoundation bleibt für H.264/HLS
- [V] Port `mpv` 0.41 ist darwin>=19 (10.15+) gegatet, Swift/Cocoa, libmpv=false.
- [V] Port `mpv-legacy` 0.36.0 (waf, ffmpeg6, +libmpv) existiert – Fallback.
- [V] ffmpeg 9.0.2 / ffmpeg8 8.1.3 / ffmpeg7 auf darwin mit legacysupport; libplacebo 7.387 (C++20, +opengl).
- [V] installiert: dav1d, libvpx, aom, svt-av1, x264, x265, opus, libass … – ffmpeg/mpv selbst nicht.
- [D] mpv 0.37 hat <10.15-Kompat entfernt, libplacebo Pflicht; plain-gl (render API) braucht kein Cocoa; ohne Cocoa nur hwdec=videotoolbox-copy.
- Sauberer Weg: Overlay multimedia/mpv (neu) mit -Dlibmpv=true -Dcocoa=disabled -Dswift-build=disabled -Dplain-gl=enabled -Dcoreaudio=enabled -Dlua=disabled.
- Erwartete Wände: platforms-Gate/Swift-Logik; ao_coreaudio neue Konstanten (kAudioObjectPropertyElementMain, 12+) → Compat-Define/MLS; libc/C11-Threads → MLS; libplacebo C++20; ffmpeg VT-APIs >10.9 per os.major abfangen.
- Gewinn: YouTube DASH VP9/AV1+Opus bis 1080p60 (evtl. 1440p30), ORF/ARD ohne HLS-Deckel, fMP4/WebM (CCC), keine -12643 auf diesem Pfad.
- Risiken: CPU/Hitze VP9 60 fps, GL-Kontext/Vsync auf 10.9, bekannte AMD-GPU-Hänger, Upstream entfernt weiter Mac-Kompat.
- Aufwand: Ports 1–3 Bau-Nächte (3–8 Patches), Sofa-Engine-Abstraktion 1–2 Tage.

## Verworfen
- Eigener Decoder (libavcodec + AVSampleBufferDisplayLayer, [V] Klasse in 10.9-Headern): A/V-Sync, Audio, Seeking, ABR selbst bauen = Wochen. Nur Plan B.
- ffmpeg-Transmux→HLS-TS für AVFoundation: hilft nur bei Container-Problemen; VP9→H.264-Transcode in Echtzeit auf dem i5 nicht sinnvoll.

## Auswahlregel (mit mpv)
H.264 ≤1080p → AVFoundation (Hardware), sonst VP9 → mpv, AV1 nur wenn Messung reicht.

## Offene Entscheidungen (User)
1. Mess-Gate zuerst: ffmpeg8 per Port bauen, `ffmpeg -benchmark` mit VP9/AV1-Testdateien?
2. Neuestes mpv als Overlay (ohne Cocoa/Swift) vs. mpv-legacy 0.36?
3. ffmpeg-Basis 8.1 oder 9.0; gpl-Varianten ok?
4. Langfristig eine Engine (mpv für alles) oder AVFoundation dauerhaft für H.264?
5. Obergrenze 1080p60 VP9 oder 1440p zulassen?
6. libcurl-Proxy behalten oder TLS direkt über ffmpeg/gnutls?

## Entscheidungen (User 2026-11-03)
1. Erst messen (Mess-Gate mit ffmpeg-Port), dann mpv.
2. Neuestes mpv als Overlay-Port (libmpv, ohne Cocoa/Swift).
3. H.264 ≤1080p bleibt AVFoundation (Hardware); mpv nur für VP9/AV1/Rest.
4. Obergrenze YouTube: 1080p60.

## Mess-Gate (2026-11-03) — BESTANDEN
ffmpeg8 8.1.3 (+gpl2+vmaf) per `sudo port -n install ffmpeg8` gebaut (MacPorts, alle 48 Deps waren da).
Testmaterial: Big Buck Bunny 60fps (YouTube aqz-KE-bpKQ), je 60 s, reine Dekodierung `-threads 0 -f null`:
| Format | Decoder | fps | Echtzeit |
|---|---|---|---|
| VP9 1080p60 (itag 303) | ffvp9 | 507 | 8,5x |
| VP9 1440p60 (itag 308) | ffvp9 | 271 | 4,5x |
| AV1 1080p60 (itag 399) | libdav1d | 376 | 6,3x |
→ Software-Dekodierung ist auf dem i5-2500S kein Engpass (VP9 1080p60 ≈ 1 Kern). Auch 1440p60 wäre machbar;
User-Obergrenze bleibt 1080p60 (kann später angehoben werden). Nächster Schritt: Overlay-Port mpv (libmpv, ohne Cocoa/Swift).
