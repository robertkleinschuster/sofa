# Sofa — 10-foot Media-Center für den iMac (macOS 10.9.5)

Verbindliche Architektur- und Produktnotizen. **Vor jeder Arbeit an Sofa lesen, nach
jeder Entscheidung aktualisieren** (Abschnitt "Entscheidungslog").

## Ziel
Eigenes, rundes "Smart-TV"-Produkt statt Kodi: native Cocoa-App, mit der Apple Remote
bedient, Bereiche je Quelle mit eigenem Look (YouTube, ZDF, ARD, ORF, media.ccc.de,
Mediathek gesamt), lokale Downloads + Streaming + eigene Abo-Engine in EINEM Programm.
Intuitiv, stabil, ressourcenschonend auf iMac12,2 (i5-2500S Sandy Bridge, kein AVX2,
Radeon HD 6770M, 2560x1440).

## Harte Regeln (User-Vorgaben 2026-11-03)
1. **Neuer, sauberer Monolith.** Keine Abhängigkeit zu altem Code (Kodi-Addons
   `script.ytdlsub`, `script.mobilecast`, `~/ytdl-sub/*.py`, run.sh). Der alte Code
   ist nur Ideen-/Feature-Vorlage.
2. **Eigene Abo-Engine** (ersetzt ytdl-sub), sauber integriert (Abonnieren aus jeder
   Quellen-App, Planung, Download, Aufbewahrung, Fortschritt in der UI).
3. **Eigene Scraper** für die Mediatheken direkt gegen die Quellen-APIs; MediathekView
   (MServer, Open Source) nur als Referenz für Endpunkte — **keine Abhängigkeit zu
   MediathekView-Servern** im Endausbau.
4. **yt-dlp = einzige externe Engine**, nur für YouTube (Signatur/nsig/PO-Token-
   Wettrüsten), gekapselt hinter dem Resolver-Interface, eigener Prozess.
5. Apple Remote **Menu-Taste startet Sofa** (Front-Row-Prinzip) über eigenen Helper.
6. Endzustand als MacPorts-Port im Overlay (`~/backport-toolkit/ports`), Doktrin beachten.
7. Untertitel werden NICHT benötigt.

## Technik
- Objective-C + ARC, AppKit, Core Animation (layer-hosting, nur bei Änderung neu
  zeichnen), AVFoundation (Hardware-H.264, HLS), IOKit HID, SQLite (System-libsqlite3).
- Build: clang-22 (`/opt/local/bin/clang`), kein Xcode/SDK nötig (Header aus /System).
  **Fallen:** (a) 10.9-Header kennen keine Lightweight-Generics → kein `NSArray<X*>`;
  (b) `-fobjc-arc` beim LINKEN verlangt libarclite (fehlt) → nur beim Kompilieren
  `-fobjc-arc`, Link ohne (10.9-Runtime hat ARC nativ); (c) keine 10.10+-APIs
  (NSQualityOfService, NSVisualEffectView usw.).
- Layout in Design-Einheiten 1920x1080, `U()` skaliert (SFScale = Höhe/1080).
- Getestet 2026-11-03: AVFoundation spielt lokal MP4, ZDF/3sat/ARD/BR/ARTE/SRF/ORF
  VOD, Livestreams Das Erste/ZDF/ORF1/3sat (HLS) und media.ccc.de-CDN → TLS von 10.9
  reicht — AUSSER ORF (api-tvthek, *.mdn.ors.at, *.sf.apa.at: nur AES-GCM/TLS1.3).
- **TLS-Brücke (`SFCurl`)**: libcurl aus MacPorts (OpenSSL). `SFNet`/`SFImageCache`
  nehmen für bekannte bzw. bei SSL-Fehler gelernte Hosts curl; der Player geht über
  `SFStreamProxy` (127.0.0.1, schreibt m3u8 um, Segmente gestreamt inkl. Range).
  Der Proxy deckelt `#EXT-X-VERSION` auf 6: CoreMedia 10.9 meldet sonst
  "Unsupported version: 7" → -12642 (ORF-Livestreams sind v7, aber reines TS).
  Diagnose-Werkzeug: `docs/probes/avtest.m` (druckt errorLog des AVPlayerItem).

## Code-Struktur (`~/src/sofa`)
- `src/SFCore` Basics, `SFTheme` Looks je Bereich, `SFLayers` (SFLabel, SFImageLayer,
  Bildcache), `SFModel` (SFItem/SFShelf/SFPage + Resolver-Registry), `SFStore` (SQLite:
  progress, settings, jcache), `SFScreen` (Screen + Navigator), `SFTile`,
  `SFBrowseScreen` (Shelves/Grid, virtualisiert, Hero), `SFPlayerScreen`.
- Provider (je Quelle eine Datei): Library (lokal `~/TV Shows`), YouTube, ZDF, ARD,
  ORF, CCC, Mediathek.
- `helper/` SofaRemote (LaunchAgent): hält Apple IR exklusiv, Menu startet Sofa,
  leitet Tasten per Mach-Port an die App.
- Daten: `~/Library/Application Support/Sofa/sofa.db`, Cache `~/Library/Caches/Sofa`,
  Log `~/Library/Logs/Sofa.log`.

## Datenquellen
- Lokal: `/Users/imac/TV Shows/<Sendung>/tvshow.nfo` (genre YouTube|ZDF|ARD = Quelle),
  `Season YYYY/sYYYY.eMMDDNN - Titel.{mp4,nfo,-thumb.jpg,info.json}`, poster/fanart.
  Layout bleibt kompatibel (408 GB Bestand, ~1800 Videos, 117 Sendungen).
- Apple IR: AppleIRController, Consumer-Page-Usages: 0x40 Menu, 0x41 Select,
  0x42 Up, 0x43 Down, 0x44 Left, 0x45 Right, 0xCD Play/Pause, 0xB5/0xB6 Next/Prev,
  0xE9/0xEA Vol; GenericDesktop 0x89..0x8D System-Menu*. Exklusiv-Open scheitert
  solange XBMCHelper läuft (0xe00002c5).
- YouTube-Login: Firefox-Profil `cookies.sqlite` (inkl. LOGIN_INFO) nativ lesen.
- Mediatheken: offizielle APIs (ZDF api.zdf.de, ARD api.ardmediathek.de, ORF
  api-tvthek.orf.at) — Endpunkte aus MServer ableiten. MediathekView-Filmliste
  (`liste.mediathekview.de/Filmliste-akt.xz`, 77 MB xz / 477 MB JSON, 717k Einträge,
  Felder: Sender,Thema,Titel,Datum,Zeit,Dauer,Größe,Beschreibung,Url,Website,...,
  leere Felder = wie Vorgänger, "Url Klein/HD" = "offset|suffix") nur als Referenz.
- media.ccc.de: `api.media.ccc.de/public/{conferences,events/recent,events/<guid>}`.

## Feature-Vorlage aus dem alten Kodi-Setup (nur Ideen!)
Home: Übersicht / Neue Folgen / Begonnen / Sendungen / YouTube / Handy-Streams.
YouTube: Suche, Link öffnen, Kanäle+Abos, Verlauf+Weiterschauen, Playlists,
Warteschlange, Downloads, Handy koppeln (Lounge-API "Mit TV-Code verbinden").
Abo-Optionen: Lookback (2w..10y), Aufbewahrung (Zeit / max. Dateien), keine Streams,
Mindestdauer (ARD 900 s), 720p H.264/AAC MP4. Kiosk: Display wach während Wiedergabe,
erster Remote-Druck nach Wake ignorieren, Mitteltaste im Vollbild = Info, keine
Setup-Assistenten über der App. Player: Restzeit + "Endet um", Autoplay nächste Folge.
Gesehen/Fortsetzen einmalig aus Kodi `MyVideos116.db` importieren.

## Ausbaustufen
1. Kern: UI-Engine, Home, lokale Bibliothek, Player, Tastatur + Remote-Helper.
2. Quellen online: ZDF/ARD/ORF/CCC nativ, YouTube via yt-dlp-Resolver.
3. Abo-Engine nativ (ersetzt ytdl-sub + LaunchDaemon com.ytdlsub.run).
4. Handy-Koppeln (Lounge), Kodi-Import, Port, XBMCHelper/Kodi-Autostart ablösen.

## Leitbild „Premium-Erlebnis“ (User-Vorgabe 2026-11-03, VERBINDLICH)
Sofa ist **kein Download-Manager mit Bibliothek** (wie früher Kodi + ytdl-sub), sondern
pro Quelle ein **nativer Client, der streamt UND offline kann – wie YouTube Premium**.
Gilt für ALLE Apps (YouTube, ZDF, ARD, ORF, CCC …); Umsetzung je Quelle darf abweichen.
- Ein Video = ein Objekt mit Zuständen: online · wird geladen (x %) · offline verfügbar.
  Gleiche ID online/lokal (`externalID`), gemeinsamer Fortschritt, lokale Kopie wird
  automatisch bevorzugt (Qualität, sofortiger Start, offline).
- Aktionen direkt am Inhalt (Kontextmenü/Select-lang): „Herunterladen“, „Download
  löschen“; an Kanal/Sendung: „Neue Folgen automatisch laden“ (+ Anzahl behalten).
  = die Abo-Engine (ersetzt ytdl-sub), läuft still im Hintergrund.
- Bereich „Downloads“ je App (+ app-übergreifend auf Home), Speicherplatz-Anzeige,
  „Gesehenes automatisch löschen“ (Smart Downloads).
- Offline (kein Netz): App zeigt ihre Downloads statt Fehlerseite.
- Neue Downloads verwaltet Sofa selbst: eigener Speicherort + DB-Tabelle `downloads`
  (Quell-ID, Item-JSON, Datei, Status). KEINE Kodi-Kompatibilität mehr nötig (User
  2026-11-03: "Kodi brauchen wir bald wirklich nicht mehr berücksichtigen") → keine
  NFOs/~/TV Shows-Struktur für neue Downloads. ~/TV Shows (ytdl-sub-Altbestand) wird
  einmalig übernommen (ID aus NFO, Fortschritt local:… → Quell-ID), danach entfällt
  der Ordner-Scan. Kein extra Library-Konzept in der UI ("Meine Sendungen" verschwindet
  als Sonderwelt → Kanäle/Sendungen mit Offline-Markierung). Kodi bleibt nur noch
  manuelle Rückfallebene, bis der User es freigibt.

## Entscheidungslog
- 2026-11-03: Objective-C/AppKit/CA/AVFoundation gewählt (nativ, kein Runtime-Ballast,
  Hardware-Decoding; Kodi rendert dauernd per GL → CPU/GPU-Last). Name "Sofa".
- 2026-11-03: yt-dlp nur für YouTube; alles andere eigen.
- 2026-11-03: Premium-Leitbild statt Download-Manager (s. Abschnitt oben).
- 2026-11-03: Kodi-Kompatibilität kein Kriterium mehr; Downloads in Sofa-eigenem Speicher.
- 2026-11-03: ORF über libcurl+lokalen HLS-Proxy statt NSURLSession (10.9-TLS zu alt). User-Prio danach: YouTube + Handy-Koppeln.

## Dev-Kreislauf (closed loop, stört Kodi nicht)
- `tools/sofa-dev cycle` = build + unsichtbare Instanz (`--dev`: Offscreen-Fenster,
  ActivationPolicyProhibited, stumm, keine Power-Assertion) + Check.
- `tools/sofa-dev do "key down" "shot name" ...` → PNG in /private/tmp/claude-501/sofa-shots.
  Screenshots via `renderInContext` (Window-Server fotografiert Offscreen-Fenster nicht;
  Video-Ebene, Masken und 3D-Transforms erscheinen darin nicht → Effekte bildbasiert lösen,
  z.B. Backdrop-Verläufe werden ins Bild eingerechnet).
- Live-Viewer: http://<tailscale-host>:8765/ (nur Tailscale-IP + localhost),
  MJPEG 1280x720 @6fps + Fernbedienung im Browser (`SFDevServer`).
- Log `~/Library/Logs/Sofa.log`, stderr `~/Library/Caches/Sofa/dev.stderr`, Crashreports
  werden von `sofa-dev check` gemeldet.
- CA-Falle: `actionForKey:` muss nil (nicht NSNull) liefern.

## Hardware-Vorgabe: Apple Remote Aluminium (2011), 7 Tasten
Hoch, Runter, Links, Rechts, Mitte, MENU, Play/Pause — KEINE Home-Taste. Alles muss
damit vollständig bedienbar sein. Belegung: MENU = zurück, MENU lang = Home;
Mitte = OK, Mitte lang = Kontextmenü; Links/Rechts lang = spulen (Player);
Im Player: Hoch/Runter (+/-) = Systemlautstärke (CoreAudio VirtualMasterVolume,
1/16-Schritte, HUD), Halten wiederholt. Play/Pause = Wiedergabe. Lang-Erkennung im Helper
(Timing), Web-Viewer bildet exakt diese Tasten ab. Kein Feature darf Tastatur/Maus brauchen
(Texteingabe für Suche → eigene Bildschirmtastatur).

## Backlog (User-Einwürfe — Warteschlange, abhaken wenn erledigt)
- [x] Offizielle Logos (YouTube, ZDF, ARD, ORF, media.ccc.de, 3sat, ARTE ...) als PNG
      (Wikimedia-Renderings, 10.9 kann kein SVG) in `res/logos/`, in App-Kacheln + Header.
      Home use → erlaubt (User 2026-11-03).
- [x] Kodi ablösen (User: aktuell nutzt niemand Kodi, Kodi bleibt Rückfall):
      Plists + /Applications/Sofa.app liegen bereit; Rest via `tools/switch-to-sofa.sh`
      (User muss ausführen/freigeben). Danach: Remote-Kalibrierung (jede Taste kurz+lang,
      `~/Library/Logs/SofaRemote.log`), Video auf echtem Bildschirm prüfen.
- [x] media.ccc.de-App (eigene App, API api.media.ccc.de).
- [~] ZDF / ARD / ORF nativ nach `docs/mediathek-apis.md` (Geo-/DRM-Sperren kennzeichnen). ARD+ZDF fertig (Geo-Check vor Start), ORF fertig 2026-11-03 (TLS-Brücke, Highlights `_embedded.video_item._embedded.item`, nur QXA-Streams; Einzelqualitäten → 403). Ggf. noch 3sat/ARTE.
- [x] Update ohne Störung (sofa-deploy, sofort auch während Wiedergabe, Position bleibt).
- [~] YouTube online (InnerTube nativ + yt-dlp-Resolver) nach `docs/youtube.md`. FERTIG 2026-11-03: `SFYouTube` (Firefox-Cookies → SAPISIDHASH, Abos/Später ansehen/Kanäle/Kanalseite UULF ohne Shorts/Playlists), `SFYTResolver` + `res/ytresolver.py` (eigenes venv `~/Library/Application Support/Sofa/ytdlp`, yt-dlp 2026.10.21, ~3,5 s/Video, 1080p HLS), Player-Retry -12643 + Ausweich-URLs (95 → 18). Lokale Kopie wird bevorzugt (`externalID`). OFFEN: Suche (braucht Bildschirmtastatur), Kanal-Banner als Hero, Live-Tab.
- [ ] Eigene Abo-Engine (ersetzt ytdl-sub + com.ytdlsub.run), Abonnieren aus jeder App. → jetzt als Premium-Offline-Schicht (siehe Leitbild): `SFDownloads` generisch (ffmpeg -c copy aus HLS/MP4, ORF über Proxy), Downloads in Sofa-eigenen Speicher (DB `downloads`), ~/TV Shows nur Migration, Identität = Quell-ID (yt:…), Progress-Migration von local:…, Kontextmenü Herunterladen/Automatisch laden, Kachel-Status.
- [x] Handy-Koppeln (YouTube "Mit TV verbinden", Lounge-API) nativ — 2026-11-03: `SFLounge` (libcurl-Long-Poll, NSURLSession puffert auf 10.9!), `SFPairScreen` (YouTube → Mehr → „Mit Handy verbinden“), Befehle in main.m (`loungeCommand:`), weckt Display + holt Sofa nach vorne. Getestet mit `tools/lounge-remote.py <code>` (simuliertes Handy): setPlaylist/pause/seek/play/getNowPlaying ok. Dev-Instanz nur mit SOFA_LOUNGE=1 (eigene screenId `lounge.dev.*`). OFFEN: Test mit echtem Android/iPhone (getDiscoveryDeviceId unbeantwortet).
- [ ] Bildschirmtastatur für Suche (nur 7 Remote-Tasten).
- [ ] Periodisch Background-Review-Agents (User-Wunsch) — nach jedem größeren Baustein.
- [ ] Video-Frames im Dev-Stream (AVPlayerItemVideoOutput), sonst schwarz.
- [ ] MacPorts-Port im Overlay (Endzustand), /Applications-Kopie ist Übergang.
- [x] Systemlautstärke per Remote (Player: +/-), keine App-interne Lautstärke.
- [x] Dev-Viewer im Browser (Tailscale), getrennte view/test-Instanzen.

## Display-Sleep/Wake (aus Kodi-Erfahrung, siehe ~/kodi-setup-NOTES.md "Sleep/Wake-Modell")
- macOS verwaltet Timeouts (pmset displaysleep 5, sleep 0); Sofa hat KEINE eigene
  Energieverwaltung.
- SofaRemote: JEDER IR-Druck → `IOPMAssertionDeclareUserActivity` (IR ist exklusiv
  gegriffen, macOS sieht die Tasten sonst nicht → Display ginge beim Navigieren aus).
  Display aus (IODisplayWrangler CurrentPowerState<3 oder CGDisplayIsAsleep) → erster
  Druck weckt nur (wird geschluckt).
- Player: während Wiedergabe NoDisplaySleep + NoIdleSleep-Assertion, bei Pause/Ende
  freigeben. Kein dauerhaft aktives Audiogerät (blockierte bei Kodi den Sleep).
- Aus echtem System-Sleep weckt die Remote per Firmware; aus DarkWake nicht zuverlässig.

## Update-Mechanismus (User-Vorgabe: sofort, auch während Wiedergabe)
`tools/sofa-deploy` → Build nach /Applications/Sofa.app.staged. SofaRemote prüft alle 3 s,
schickt der App msg 1000 (SF_MSG_PREPARE_UPDATE): App sichert resume.json (Screens via
restoreKey "app:<quelle>", laufendes Item + Position), zeigt "Sofa wird aktualisiert …",
flush, exit. Helper tauscht Bundles (alt → Sofa.app.prev), `launchctl start de.sofa.app`,
beendet sich (KeepAlive startet neuen Helper). Neue App stellt Bereich + Video an der
Position −2 s wieder her. Getestet 2026-11-03: ~1 s Unterbrechung.
Rollback: /Applications/Sofa.app.prev zurückbenennen.
Details: App beendet sich mit `_exit(0)` (exit() hing in Framework-Handlern). de.sofa.app hat
KeepAlive{SuccessfulExit=false} (Absturz → Neustart). Helper prüft Prozessende per kill(pid,0),
startet Sofa nur neu, wenn es VORNE war (sonst würde es z.B. Kodi überdecken), verifiziert den
Start (bis 6 Versuche), ignoriert Tasten während des Tauschs.
Kodi-Rückweg: Sofa im Hintergrund + andere App vorne → MENU zweimal schnell (<0,7 s) holt Sofa.
Fernshell-Hinweis: launchctl/open aus der Tailscale-SSH-Session (Background-Session) wirken
nicht in Aqua → `sudo launchctl bsexec <loginwindow-pid> sudo -u imac launchctl ...`.
