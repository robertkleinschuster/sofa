# Modern codecs – research (2026-11-03, agent, nothing built)

Status 2026-11-06: outcome went further than recommended here - mpv is the only engine, AVFoundation
is removed (NOTES "Remove AVFoundation"). Kept as the research record.

Legend: [V] verified on the device, [D] docs/web, [W] knowledge/estimate.

## Hardware
- [V] iMac12,2, i5-2500S (Sandy Bridge, 4C/4T, 2.7 GHz, AVX1, no AVX2), 16 GB, AMD Radeon HD 6770M 512 MB, 2560x1440.
- [W] Hardware decode only H.264 (UVD3). VP9/AV1/HEVC software only.
- [W] Estimate: VP9 1080p30 safe, 1080p60 likely (high load), 1440p60 borderline; AV1 (dav1d SSSE3) 1080p30 ok, 1080p60 borderline. → measure before deciding.

## Recommendation: libmpv as a second engine (render API, OpenGL in CAOpenGLLayer), AVFoundation stays for H.264/HLS
- [V] Port `mpv` 0.41 is gated to darwin>=19 (10.15+), Swift/Cocoa, libmpv=false.
- [V] Port `mpv-legacy` 0.36.0 (waf, ffmpeg6, +libmpv) exists – fallback.
- [V] ffmpeg 9.0.2 / ffmpeg8 8.1.3 / ffmpeg7 on darwin with legacysupport; libplacebo 7.387 (C++20, +opengl).
- [V] installed: dav1d, libvpx, aom, svt-av1, x264, x265, opus, libass … – but not ffmpeg/mpv themselves.
- [D] mpv 0.37 removed <10.15 compat, libplacebo mandatory; plain-gl (render API) needs no Cocoa; without Cocoa only hwdec=videotoolbox-copy.
- Clean path: overlay multimedia/mpv (new) with -Dlibmpv=true -Dcocoa=disabled -Dswift-build=disabled -Dplain-gl=enabled -Dcoreaudio=enabled -Dlua=disabled.
- Expected walls: platforms gate/Swift logic; ao_coreaudio new constants (kAudioObjectPropertyElementMain, 12+) → compat define/MLS; libc/C11 threads → MLS; libplacebo C++20; catch ffmpeg VT APIs >10.9 via os.major.
- Gain: YouTube DASH VP9/AV1+Opus up to 1080p60 (maybe 1440p30), ORF/ARD without the HLS cap, fMP4/WebM (CCC), no -12643 on this path.
- Risks: CPU/heat VP9 60 fps, GL context/vsync on 10.9, known AMD GPU hangs, upstream keeps removing Mac compat.
- Effort: ports 1–3 build nights (3–8 patches), Sofa engine abstraction 1–2 days.

## Rejected
- Own decoder (libavcodec + AVSampleBufferDisplayLayer, [V] class present in the 10.9 headers): building A/V sync, audio, seeking, ABR ourselves = weeks. Plan B only.
- ffmpeg transmux→HLS-TS for AVFoundation: only helps with container problems; VP9→H.264 transcode in real time on the i5 is not sensible.

## Selection rule (with mpv)
H.264 ≤1080p → AVFoundation (hardware), otherwise VP9 → mpv, AV1 only if the measurement allows it.

## Open decisions (user)
1. Measurement gate first: build ffmpeg8 via port, `ffmpeg -benchmark` with VP9/AV1 test files?
2. Newest mpv as an overlay (without Cocoa/Swift) vs. mpv-legacy 0.36?
3. ffmpeg base 8.1 or 9.0; gpl variants ok?
4. Long term one engine (mpv for everything) or AVFoundation permanently for H.264?
5. Upper limit 1080p60 VP9 or allow 1440p?
6. Keep the libcurl proxy or TLS directly via ffmpeg/gnutls?

## Decisions (user 2026-11-03)
1. Measure first (measurement gate with the ffmpeg port), then mpv.
2. Newest mpv as an overlay port (libmpv, without Cocoa/Swift).
3. H.264 ≤1080p stays AVFoundation (hardware); mpv only for VP9/AV1/the rest.
4. YouTube upper limit: 1080p60.

## Measurement gate (2026-11-03) — PASSED
ffmpeg8 8.1.3 (+gpl2+vmaf) built via `sudo port -n install ffmpeg8` (MacPorts, all 48 deps were present).
Test material: Big Buck Bunny 60fps (YouTube aqz-KE-bpKQ), 60 s each, pure decoding `-threads 0 -f null`:
| Format | Decoder | fps | Real time |
|---|---|---|---|
| VP9 1080p60 (itag 303) | ffvp9 | 507 | 8.5x |
| VP9 1440p60 (itag 308) | ffvp9 | 271 | 4.5x |
| AV1 1080p60 (itag 399) | libdav1d | 376 | 6.3x |
→ Software decoding is not a bottleneck on the i5-2500S (VP9 1080p60 ≈ 1 core). Even 1440p60 would be feasible;
the user's upper limit stays 1080p60 (can be raised later). Next step: overlay port mpv (libmpv, without Cocoa/Swift).
