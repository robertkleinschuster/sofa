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
- Provider (je Quelle eine Datei): YouTube, ZDF, ARD,
  ORF, CCC, Mediathek.
- `helper/` SofaRemote (LaunchAgent): hält Apple IR exklusiv, Menu startet Sofa,
  leitet Tasten per Mach-Port an die App.
- Daten: `~/Library/Application Support/Sofa/sofa.db`, Cache `~/Library/Caches/Sofa`,
  Log `~/Library/Logs/Sofa.log`.

## Datenquellen
- Offline-Bestand: `~/Movies/Sofa/<quelle>/<Sendung>/<Titel> [<id>].mp4` + `.jpg`,
  poster.jpg/fanart.jpg je Sendung; Metadaten nur in der DB (`downloads`, `subscriptions`).
  `SFLibrary` ist nur noch eine Sicht darauf (gruppiert nach Quelle + Sendung).
- MIGRIERT 2026-11-03 (`SFMigration`, einmalig, Setting `migration.tvshows`): aus
  `~/TV Shows` (ytdl-sub/Kodi) 1787 Videos / 427 GB verschoben (Umbenennen, 0 Fehler),
  141 Fortschritte local:… → yt:/zdf:/ard:, 127 Abos aus `~/ytdl-sub/subscriptions-kodi.yaml`
  (+ Jay Foreman manuell: Kanal heißt jetzt „Map Men“, UCbbQalJ4OaC0oQ0AqRaOJ9g).
  Altbestand ohne Abo-Bindung (wird nie automatisch gelöscht), neue Abo-Folgen 90 Tage.
  Rest (NFO + info.json, 10 GB) im Papierkorb. ytdl-sub-Daemon `com.ytdlsub.run`
  per `launchctl unload -w` deaktiviert; `com.bgutil.potserver` bleibt (yt-dlp-Resolver).
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

## Leitbild „Exzellente UX“ (User-Vorgabe 2026-11-03, VERBINDLICH, oberste Priorität)
„UX ist super wichtig, exzellente professionelle UX soll unbedingt gewährleistet werden.
Alles selbsterklärend und intuitiv.“ Daraus folgt für jede Funktion:
- Ohne Anleitung auffindbar: versteckte Gesten sichtbar machen (Kopfzeile zeigt
  „OK halten: Optionen“, sobald der Fokus auf etwas mit Optionen steht).
- Smart-TV-Menüführung, immer mit der 7-Tasten-Apple-Remote gedacht (Menu = zurück,
  Play/Pause spielt direkt, OK halten = Optionen, MENU auf Home = Energie).
- Beschriftungen in Nutzersprache („Energie“, „Neue Folgen automatisch laden“), keine Technik.
- Wichtigstes zuerst (Optionen: Abspielen → Download → Gesehen …).
- Destruktives nur mit Bestätigung, die die Folge nennt („Ja, 7 Folgen löschen“).
- Leere Zustände erklären den nächsten Schritt; jede Aktion bekommt sichtbares Feedback (Toast).
- Vor „fertig“: UI per Dev-Screenshot prüfen.

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
- 2026-11-03: Migration durchgeführt, ytdl-sub aus; Kodi-Import (SFKodiImport) entfernt.
- 2026-11-03: Folgen statt Download-Abos (User): „Folgen“ ist der Kern (Neue Folgen gestreamt, Meine Sendungen/Kanäle, eine gemeinsame Sofa-Liste, YouTube-Konto-Kanäle einmalig übernommen); „Automatisch herunterladen“ nur Zusatz je gefolgter Sendung (die 128 übernommenen bleiben an). Downloads = Zustand eines Videos (schneller Start, offline), kein eigener Bereich mehr im Vordergrund.
- 2026-11-03: Kein Mehrbenutzer-Konzept (User): Gerät wird geteilt, alles ist gemeinsam (Verlauf, Weiterschauen, Abos). Keine Anmelde-/Firefox-Hinweise in der Oberfläche.
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
- [~] YouTube online (InnerTube nativ + yt-dlp-Resolver) nach `docs/youtube.md`. FERTIG 2026-11-03: `SFYouTube` (Firefox-Cookies → SAPISIDHASH, Abos/Später ansehen/Kanäle/Kanalseite UULF ohne Shorts/Playlists), `SFYTResolver` + `res/ytresolver.py` (eigenes venv `~/Library/Application Support/Sofa/ytdlp`, yt-dlp 2026.10.21, ~3,5 s/Video, 1080p HLS), Player-Retry -12643 + Ausweich-URLs (95 → 18). Lokale Kopie wird bevorzugt (`externalID`). Suche fertig. Kanalkopf (Banner als TV-Motiv, @Handle, Abonnenten, Beschreibung) + Kachel „Automatisch laden: An/Aus“ fertig. OFFEN: Live-Tab.
- [x] Eigene Abo-Engine (ersetzt ytdl-sub + com.ytdlsub.run; live seit 2026-11-03, Feeds yt/zdf/ard/orf), Abonnieren aus jeder App. → jetzt als Premium-Offline-Schicht (siehe Leitbild): `SFDownloads` generisch (ffmpeg -c copy aus HLS/MP4, ORF über Proxy), Downloads in Sofa-eigenen Speicher (DB `downloads`), ~/TV Shows nur Migration, Identität = Quell-ID (yt:…), Progress-Migration von local:…, Kontextmenü Herunterladen/Automatisch laden, Kachel-Status.
- [x] Handy-Koppeln (YouTube "Mit TV verbinden", Lounge-API) nativ — 2026-11-03: `SFLounge` (libcurl-Long-Poll, NSURLSession puffert auf 10.9!), `SFPairScreen` (YouTube → Mehr → „Mit Handy verbinden“), Befehle in main.m (`loungeCommand:`), weckt Display + holt Sofa nach vorne. Getestet mit `tools/lounge-remote.py <code>` (simuliertes Handy): setPlaylist/pause/seek/play/getNowPlaying ok. Dev-Instanz nur mit SOFA_LOUNGE=1 (eigene screenId `lounge.dev.*`). Mit echtem Handy getestet: funktioniert (User 2026-11-03). Offen nur: getDiscoveryDeviceId unbeantwortet (Auto-Erkennung ohne Code).
- [x] Bildschirmtastatur für Suche (nur 7 Remote-Tasten) + Suche in allen Apps.
- [x] Downloads (2026-11-03): Kachel auf Home + Regal „Downloads“ je App (nach Weiterschauen/erstem Regal, Kachel mit Download-Symbol in App-Farben) → Seite „Downloads · X GB belegt · Y GB frei“ mit Wird geladen / Zuletzt geladen / Sendungen und Kanäle; Sendung: „Automatisch laden An/Aus“, „Alle Downloads löschen“ mit Bestätigung (Fokus auf Abbrechen); Kontextmenü Abspielen → Download → Gesehen; Kopfzeile „OK halten: Optionen“. Offline-Seiten laden bei Bestandsänderung live neu.
- [x] Smart Downloads: gesehene ABO-Folgen 1 Tag nach dem Ansehen löschen (Standard an; manuelle + Altbestand nie), Schalter „Gesehenes löschen An/Aus“ in den Optionen der Downloads-Kachel. Dev hat eigenen Settings-Key (Settings-Tabelle ist geteilt!).
- [x] Offline (2026-11-03): SystemConfiguration-Reachability (`SFNet isOnline`), Kopfzeile „Keine Internetverbindung – Downloads sind verfügbar“, Download-Warteschlange + Abo-Prüfung pausieren offline (keine verbrauchten Versuche). Gecachte Online-Seiten bleiben sichtbar (bis 30 Tage). Dev-Test: `SOFA_OFFLINE=1 tools/sofa-dev start`.
- [x] Review-Agent 2026-11-03 (Offline-Schicht): 7 Befunde behoben — Abbrechen des laufenden Downloads blockierte Queue; ARD/ZDF-Dateinamen kollidierten (lange IDs jetzt FNV-Hash); neue Abos luden Backkatalog nach (since nach Erst-Check); abbestellte Abos kamen zurück; Folgen nach Abbestellen später gelöscht; Library-Meldung verschluckt; Sendung nur per Name (jetzt Name+Quelle, „Einzelne Videos“).
- [x] Mauszeiger (2026-11-03, User: war noch sichtbar): 3 Schichten — transparenter Cursor via Cursor-Rects (SFNavigator), Wächter 1 s (CGCursorIsVisible → CGDisplayHideCursor, Log „cursor: war sichtbar“), sauberes Einblenden bei App-Wechsel. Alte Lösung zählte Hide/Show und merkte nicht, wenn das System den Zeiger wieder zeigte.
- [x] 2026-11-03 Nachmittag (User-Feedback): Dev-Isolation Fortschritt (`dev_progress`, Tests hatten „Weiterschauen“/„gesehen“ der echten App verändert – Creepfan-Video repariert, 141 Migrations-Einträge ohne Bild repariert); Kontraste helles ORF-Theme (Kacheln ohne Bild dunkle Schrift, textDim 0.74, Kopfband-Verlauf hinter Uhr/Hinweis, Menü-Labels volle Breite); ZDF-Markenseiten (MetaCollection per canonical → interne ID auflösen, „Bares für Rares“ war leer); ZDF-Staffeln mit echtem Namen („2026“) + Bild der Sendung; YouTube-Kanalkacheln migrierter Kanäle → echte Kanalseite (online + lokal); Verlauf (Home-Kachel, nach Tagen); Handy: Status in jeder Kopfzeile, auf „Mit Handy verbinden“ OK = Optionen: Verbindung pausieren (Kopplung bleibt) ≠ Alle Handys trennen (neue screenId, Code nötig), „Am Handy anzeigen“ Standard = nur vom Handy gestartete Wiedergabe. Dev: `sofa-dev open pair|history`.
- [x] Statuszeile oben rechts (2026-11-03): eine Mittellinie, rechts→links Uhr · Handy-Pille (nur Home + YouTube) · [OK]-Tastenkappe „halten: Optionen“. Home-Kachel „Handy“ → Einstellungen (pausieren, Am Handy anzeigen, Neues Handy verbinden, Alle trennen). Kodi-Kachel entfernt (Dev-Test hatte darüber Kodi gestartet!). YouTube-Kanäle alphabetisch.
- [x] 2026-11-03 Abend: Folgen-Konzept (SFFollows, siehe Entscheidungslog), Downloads gedrosselt (-readrate 3), Spulen ohne Rücksprünge, YouTube-Vorladen bei Fokus, Autoplay „Als Nächstes“ (YouTube /next, Karte mit Vorschaubild), Tastatur ABC/QWERTZ (gemerkt) + Live-Vorschläge in allen Apps, „Suchen“-Taste nur Umriss; Helper startet Sofa nach jedem Update; ZDF-Markenseiten-Absturz (Endlosschleife) behoben; Dev-Isolation jetzt vollständig: Fortschritt (dev_progress), Folgen/Downloads (dev_*-Tabellen), ALLE Einstellungen (SFStore-Präfix „dev.“).
- [ ] OFFEN (User 2026-11-03, Reihenfolge): (1) YouTube-Kanalseite näher an YouTube (Abo-Schalter dezent statt großer Kachel, Bereiche Videos/Beliebt/Playlists/Live), (2) Autoplay „Als Nächstes“ mit YouTube-Empfehlungen, (3) Playlists, (4) Tastatur: QWERTZ-Umschalter (gespeichert) + Live-Vorschläge während der Eingabe in allen Apps, (5) Spulen: Sprünge/Race beim schnellen Vor/Zurück, (6) YouTube-Start beschleunigen (Resolver-Timing, Vorladen bei Fokus; Creepfan 22 s), (7) mpv-Bild am echten Bildschirm prüfen.
- [x] 2026-11-03 Abend: (1) Kanalseite: Knöpfe [✓ Gefolgt] · [Automatisch laden] statt Kachel, „Neueste Videos“ (12) + Playlists-Regal (ohne Mixe) + Raster „Alle Videos“; Entfolgen nur mit Rückfrage (Knopf hat beim Öffnen den Fokus). (2) Autoplay-Karte. (3) Playlists: Autoplay folgt der Playlist („Nächstes in der Playlist“). (4) Tastatur + Vorschläge; „Rechts halten“ = zu den Vorschlägen, Links = zurück zur Absprung-Taste. NEU: Knopf „Suche“ in der Kopfzeile jeder App (Hoch aus der ersten Reihe; auch auf leeren/Offline-Seiten). Player-Hinweise (Fortgesetzt bei …) über der Zeitleiste, textbreit, zeigen echten Startpunkt. Review-Agent 21:15: keine Absturzklassen; Fokus-Fehler behoben. OFFEN: Kanal-Bereiche Beliebt/Live, (5)–(7).
- [x] 2026-11-03 22:30 „Später ansehen“ (User: Lücke, man konnte nichts hinzufügen): eigene gemeinsame Merkliste `SFWatchLater` (Tabelle watch_later, Dev: dev_watch_later) für ALLE Apps; OK halten auf Video → „Später ansehen“ / „Aus ‚Später ansehen‘ entfernen“; Regal je App nach „Weiterschauen“ (`SFWithWatchLater`) + Home (alle Apps); Gesehenes fällt automatisch heraus; YouTube-Konto-Liste (VLWL) wird einmalig übernommen (Setting watchlater.import.youtube) – gleiche Logik wie Folgen. Fokus bleibt nach Entfernen in der Reihe an derselben Stelle. Kanal: Live-Tab („Jetzt live“ + „Livestreams“), „Beliebt“. mpv-Bild verifiziert.
- [x] 2026-11-03 23:30 (6) YouTube-Start: Resolver zwei Pools (fg = Wiedergabe, bg = Vorwärmen/Vorladen/Downloads; vorher wartete ein Klick hinter dem Vorladen: 10,6 s statt 3,5 s), Job-Sharing je Video (Klick während Vorladen: 2,8 s), ObjC-Dedupe + `prefetch:`. AVFoundation-Neuversuch 0,1 s statt 0,3 s – Messung aus 46 echten Starts: 23 sofort, 13 nach 1., 8 nach 2. Neuversuch, 2 → mpv; Ursache immer CoreMedia -12643 auf googlevideo-HLS, Neuversuche bleiben (H.264-Hardware). Kanal: Live-/Playlists-Regal nur, wenn der ausgewählte Tab wirklich /streams bzw. /playlists ist (sonst liefert YouTube still „Übersicht“ → Kurzgesagt zeigte normale Videos als „Livestreams“). Review-Agent „Später ansehen“: keine Absturz-/Thread-/Dev-Lecks; 2 Fokus-Fehler im Raster behoben.
- [x] 2026-11-04 00:15 Explorativ ZDF/ARD/ORF: Kontextmenü „Zur Sendung „X““ / „Zum Kanal „X““ für Folgen aller Quellen (`SFItem.showRef`: YouTube Kanal-ID aus Lockup/Renderer, ZDF `smartCollection.canonical`, ARD `show.id` (89/89 Teaser), ORF `_links.profile` – nur mit profile_title, nicht bei Genre „Film“); ältere gespeicherte YouTube-Einträge (Merkliste/Weiterschauen/Downloads) per `SFRegisterShowRefLookup` → InnerTube `player` → `videoDetails.channelId` beim Auswählen. Nicht auf der eigenen Sendungs-/Kanalseite (`folderIdentifier`). „Später ansehen“-Import des YouTube-Kontos beim Start. Sendungsseiten: `SFPage.focusShelf` – Fokus startet auf den Folgen, „Weitere Staffeln“ bleibt oben sichtbar (kein Scrollen, solange die Zeile passt). Raster-Zeilenabstand 40→58 (Titel der vergrößerten Fokus-Kachel lagen auf der nächsten Reihe).
- [ ] Periodisch Background-Review-Agents (User-Wunsch) — nach jedem größeren Baustein.
- [ ] Video-Frames im Dev-Stream (AVPlayerItemVideoOutput), sonst schwarz.
- [ ] MacPorts-Port im Overlay (Endzustand), /Applications-Kopie ist Übergang.
- [x] Systemlautstärke per Remote (Player: +/-), keine App-interne Lautstärke.
- [x] Dev-Viewer im Browser (Tailscale), getrennte view/test-Instanzen.

- [ ] **Moderne Codecs nachrüsten** (User 2026-11-03) — RECHERCHE + MESS-GATE FERTIG: `docs/codecs-research.md` (libmpv als 2. Engine; VP9 1080p60 8,5x, AV1 6,3x Echtzeit; User: neuestes mpv, H.264 bleibt AVFoundation, max 1080p60). mpv-PORT FERTIG (2026-11-03): Overlay `~/backport-toolkit/ports/multimedia/mpv` (0.41.0, platforms darwin>=13, ohne Cocoa/Swift, plain-gl, MLS statisch, Patch `patch-10.9-coreaudio.diff` = dispatch_block-Ersatz per Abbruch-Token + CoreAudioTypes-Pfad; bewusst nicht in MLS). Installiert: `mpv +libmpv +opengl +python314 -bundle -osd -bluray -dvd -audiocd -libarchive -rubberband -network_ytdlp` (+ ffmpeg 9.0.2, libplacebo +opengl, libsixel). Verifiziert: keine MLS-dylib-Abhängigkeit, `mpv` läuft nativ, VP9 1080p60 dekodiert. SOFA: Engine-Abstraktion `SFEngine` (SFAVEngine = bisheriger AVPlayer-Code, SFMPVEngine = libmpv render API in CAOpenGLLayer, schwach gelinkt `-weak-lmpv`). Wahl: H.264 → AVFoundation; mpv bei besserem DASH (VP9/AV1 mehr Auflösung/fps), WebM/MKV, oder wenn AVFoundation scheitert; mpv scheitert → AVFoundation; alles abgelehnt (YouTube 403/-1102) → einmal frisch auflösen. Resolver liefert `dash` (VP9 vor AV1, ≤1080p60, Opus). Dev-Test: `SOFA_FORCE_MPV=1` (Wiedergabe in Echtzeit verifiziert; Bild nur auf echtem Bildschirm prüfbar, dev-Fenster ist offscreen). BILD VERIFIZIERT 2026-11-03 21:45: `sofa-dev frame NAME` rendert per GL-Readback in eigenes FBO (YouTube VP9 1080p + ZDF HLS: scharf, Farben/Ausrichtung korrekt). Der einmalige „INVALID_FRAMEBUFFER_OPERATION“ war ein klebriges Fehler-Flag von CoreAnimation (0x506 vor mpv) → wird vorher abgeholt; Rendern nur bei FRAMEBUFFER_COMPLETE. Fensteraufnahmen (screencapture/CGWindowList) gehen aus der SSH-Shell grundsätzlich nicht.: jede Quelle problemlos abspielen,
  Format-Auswahl entschärfen. Heute: AVFoundation 10.9 = nur H.264/AAC in TS/MP4-HLS;
  kein VP9/AV1/HEVC/Opus, kein fMP4/DASH, HLS ≤ v6 (Proxy deckelt), sporadisch -12643.
  Optionen (VOR Umsetzung recherchieren + vorlegen, Doktrin: nativ via MacPorts):
  (a) libmpv (MacPorts mpv/ffmpeg) als zweite Player-Engine hinter SFPlayerScreen,
      Ausgabe in eigene GL-/CALayer-Fläche; AVFoundation bleibt für H.264 (Hardware).
  (b) eigener Decoder-Pfad libavcodec/libavformat + Rendering (mehr Aufwand).
  Gewinn: YouTube direkt DASH/VP9 (1080p60/1440p, ohne HLS-Umweg), ORF/ARD ohne
  Versions-Tricks, Downloads ohne Remux-Grenzen. Prüfen: CPU (2011er iMac) für VP9/AV1
  in Software, Hardware nur H.264 → Auswahl-Regel "H.264 bevorzugen, sonst Software".
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
