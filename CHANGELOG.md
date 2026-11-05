# Changelog

Was sich für Nutzer ändert. Der Abschnitt einer Version ist zugleich der Text ihres
GitHub-Releases (`tools/publish-release`) und erscheint in Sofa unter
Einstellungen → „Update installieren“.

## 0.3.7

- **Neu: Info im Player.** OK gedrückt halten öffnet über dem laufenden Video die Info:
  Beschreibung, „Zum Kanal“/„Zur Sendung“, Folgen, Herunterladen, Später ansehen, Ton und
  Untertitel – dazu die Playlist („Läuft“), „Als Nächstes“, weitere Folgen und bei YouTube
  Empfehlungen. Das Video läuft dabei weiter.
- **Bessere YouTube-Streams:** Sofa holt die hochwertigen Streams jetzt mit gültigem Nachweis
  (PO-Token) – Abbrüche mit „Zugriff verweigert“ und Ausweichen auf schlechtere Qualität
  werden seltener.
- **Downloads bleiben heil:** Ein Update während eines Downloads konnte die Datei beschädigen.
  Fertige Downloads werden jetzt geprüft; beschädigte werden automatisch neu geladen (die alte
  Datei bleibt, bis die neue fehlerfrei ist).
- **Bild kommt immer:** Direkt nach einem Update lief ein fortgesetztes Video manchmal nur mit
  Ton. Sofa wartet jetzt auf die Bildausgabe und repariert sie selbst, falls sie ausfällt.
- **Weniger YouTube-Sperren:** Sperrt YouTube kurzzeitig („kein Bot“), pausiert Sofa alle
  Hintergrund-Anfragen (Vorladen, Downloads) und versucht es später wieder, statt die Sperre
  zu verlängern. Downloads warten in der Zeit, statt fehlzuschlagen. Beim Start fragt Sofa
  YouTube nur noch, wenn es wirklich nötig ist.
- **Kopiergeschützte Folgen** werden beim automatischen Weiterspielen übersprungen.
- **Handy:** Untertitel lassen sich vom Handy aus umschalten.

## 0.3.6

- **„Online abspielen“ funktioniert:** Bei heruntergeladenen Videos startete der Wechsel bisher
  wieder die Datei – jetzt läuft wirklich der Online-Stream, an derselben Stelle.
- **„Offline“-Hinweis überall:** Heruntergeladene Videos zeigen das Zeichen „↓ Offline“ jetzt
  zuverlässig – auch unter „Weiterschauen“ und im Verlauf, wenn sie dort schon einmal liefen.

## 0.3.5

- **Vorschaubilder bleiben:** Wurde ein heruntergeladenes Video gelöscht, fehlte unter
  „Weiterschauen“ das Bild – jetzt erscheint das Online-Vorschaubild, und das Video läuft
  online weiter statt aus der gelöschten Datei.
- **Untertitel:** Bei deutschen Videos gibt es keine sinnlose „automatisch übersetzte“ deutsche
  Spur mehr neben den automatischen deutschen Untertiteln.
- **Verständliche Fehlermeldungen:** Lässt YouTube vorübergehend keine Wiedergabe zu oder
  scheitert ein Video, sagt Sofa jetzt auf Deutsch, was los ist und wie es weitergeht.
- **Handy:** Ein fehlgeschlagenes Video, das erneut vom Handy gesendet wird, lädt neu.
- **Originalton zuverlässiger:** Sofa erkennt die Original-Tonspur jetzt auch, wenn YouTube die
  Sprachangaben weglässt – automatisch synchronisierte Fassungen (z.B. KI-Stimmen) laufen nicht
  mehr versehentlich. Auch **Downloads** bekommen immer den Originalton.
- **Download oder online:** Bei heruntergeladenen Videos bietet „Ton & Untertitel“ (OK halten)
  „Online abspielen“ – mit allen Tonspuren und Untertiteln, an derselben Stelle.
- **Abo-Downloads:** Bei vorübergehenden YouTube-Sperren versucht Sofa es über mehrere Stunden
  verteilt erneut, statt die Folge nach wenigen Minuten aufzugeben.

## 0.3.4

- **Untertitel in den Einstellungen:** „Untertitel zum Mitlesen“ (Untertitel in der Sprache des
  Tons, z.B. für Hörgeschädigte) und „Untertitel übersetzt“ (deutsche Untertitel zu
  fremdsprachigen Videos) lassen sich jetzt auch ohne laufendes Video ein- und ausschalten.

## 0.3.3

- **Untertitel für ZDF, ARD und ORF:** Sendungen mit Untertiteln (meist für Hörgeschädigte)
  lassen sich jetzt über „Ton & Untertitel“ (OK gedrückt halten) einschalten.
- **Untertitel merken sich den Zweck:** Wer Untertitel in der Sprache des Tons einschaltet,
  bekommt sie künftig bei allen solchen Sendungen. Deutsche Untertitel zu einem englischen Video
  gelten dagegen nur für fremdsprachige Videos – deutsche Sendungen bleiben ohne.

## 0.3.2

- **Ton & Untertitel wählbar:** Während der Wiedergabe **OK gedrückt halten** öffnet das Menü
  „Ton & Untertitel“. Dort lassen sich die Tonspur (Original zuerst, synchronisierte Fassungen
  gekennzeichnet) und Untertitel wählen. Bei YouTube gibt es auch automatische und automatisch
  übersetzte deutsche Untertitel. Ein Hinweis oben rechts zeigt, wann das Menü verfügbar ist.
- Die gewählte Untertitelsprache bleibt gespeichert und gilt automatisch für die nächsten Videos.
- Ein Menü über dem Video unterbricht die Wiedergabe nicht mehr.

## 0.3.1

- **Neues App-Icon.**
- **Originalton:** YouTube spielt immer die Originalsprache – keine automatisch übersetzten
  Tonspuren mehr.
- Vom Handy gestartete Videos laufen nach einem Update an derselben Stelle weiter, statt von
  vorne zu beginnen.
- Videos, bei denen YouTube den bevorzugten Stream ablehnt, starten sofort mit dem
  Ausweich-Stream (vorher teils gar nicht oder erst nach mehreren Versuchen).

## 0.3.0

- **Ein Player für alles:** Sofa spielt jetzt alles mit mpv. YouTube läuft in VP9 bis 1080p60
  und startet zuverlässiger; die gelegentlichen Fehlstarts beim Öffnen sind weg.
- **YouTube sofort:** yt-dlp ist in der App enthalten – keine Einrichtungsminute mehr nach der
  Installation. Sofa hält yt-dlp selbst aktuell und prüft dabei die Signatur der yt-dlp-Entwickler.
- **Updates sind signiert:** Sofa installiert nur Updates mit gültiger Sofa-Signatur. Dadurch
  braucht Sofa keine aktuellen Zertifikatslisten mehr und funktioniert auf diesem Mac dauerhaft.
- Nach einem Update geht ein YouTube-Video in etwa 2 Sekunden weiter (vorher etwa 9).

## 0.2.0

- **Zum Herunterladen:** Sofa gibt es als DMG – in „Programme“ ziehen, fertig.
  MacPorts ist nicht mehr nötig, alles Benötigte steckt in der App.
- **Einstellungen** auf der Startseite: beim Anmelden starten, mit der Apple Remote
  starten, automatisch aktualisieren.
- **Updates:** Sofa sucht selbst nach neuen Versionen. Automatisch installiert wird nur,
  wenn gerade nichts läuft; danach geht es an derselben Stelle weiter.
- **Erster Start:** Begrüßung mit der Tastenbelegung, dann zwei kurze Fragen zum Start.
- Wird Sofa direkt aus der DMG gestartet, bittet es darum, in „Programme“ gezogen zu werden.
- Ist „Mit der Apple Remote starten“ aus, steuert die Remote den Mac (z. B. iTunes),
  solange Sofa geschlossen ist.

## 0.1.1

- YouTube funktioniert ohne Anmeldung und ohne Firefox.
- Updates während der Wiedergabe setzen das Video an derselben Stelle fort.

## 0.1.0

- Erste Version: YouTube, ZDF, ARD, ORF ON und media.ccc.de mit der Apple Remote,
  Folgen von Sendungen und Kanälen, automatische Downloads, Handy-Kopplung für YouTube.
