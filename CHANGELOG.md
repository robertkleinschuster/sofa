# Changelog

Was sich für Nutzer ändert. Der Abschnitt einer Version ist zugleich der Text ihres
GitHub-Releases (`tools/publish-release`) und erscheint in Sofa unter
Einstellungen → „Update installieren“.

## 0.3.9

- **Schärfere Hintergrundbilder:** Bei YouTube-Videos lädt Sofa das große Vorschaubild
  (1280×720) für den Hintergrund statt des kleinen Kachelbilds.
- **Neu in dieser Version:** Unter Einstellungen → „Neu in Version …“ steht jederzeit, was sich
  geändert hat – eine Zeile pro Neuerung, OK zeigt die Einzelheiten.
- **Lange Auswahllisten** (z. B. Untertitel-Sprachen) lassen sich jetzt bis zum Ende durchblättern.
- **„Zuletzt geladen“** unter Downloads zeigt die zuletzt heruntergeladenen Videos zuerst,
  auch ältere Folgen, die du von Hand geladen hast.
- **Aufgeräumte Untertitel der Kacheln:** kein einzelnes „·“ oder „noch“ mehr, wenn Kanal,
  Datum oder Länge fehlen.
- **media.ccc.de** zeigt jetzt wie die anderen Mediatheken „Meine Sendungen“ mit deinen
  Downloads, sobald du dort etwas heruntergeladen hast.
- **Neue Startseite:** Oben steht weiter „Weiterschauen“, darunter „Neue Folgen“, dann deine
  Apps. Danach gemischte Reihen aus allen Mediatheken: **„Jetzt live“** (die laufenden Sender),
  **„Nachrichten“** (tagesschau, heute, ZIB und aktuelle Meldungen, jeweils das Neueste) und
  **„Highlights“** – die Empfehlungen der Redaktionen und die Videos deiner YouTube-Kanäle,
  die gerade besonders gut ankommen. Ein kleines Logo auf jeder Kachel zeigt, woher sie kommt.
  Sender und Videos, die hier nicht laufen (nur in Deutschland verfügbar oder
  kopiergeschützt), und Videos, die du schon gesehen hast, lässt Sofa weg. Jeder Sender
  erscheint nur einmal, auch wenn ihn zwei Mediatheken anbieten.
- **Was läuft gerade:** Bei den Sendern steht jetzt, welche Sendung läuft und bis wann
  („Brisant · bis 18:00“), ein Balken zeigt, wie weit sie ist. Die große Vorschau nennt die
  Uhrzeit, was danach kommt, und beschreibt die Sendung (ARD-Sender und ORF).
- **Livestreams:** Die große Vorschau zeigt bei Sendern kein sinnloses Datum mehr.
- **Schneller und schlanker:** Sofa räumt seinen Zwischenspeicher jetzt selbst auf – die
  Datenbank ist von 234 auf etwa 68 MB geschrumpft.
- **Unter der Haube:** Sofa ist neu gegliedert – jede App (YouTube, ZDF, ARD, ORF,
  media.ccc.de) steckt in einem eigenen Modul mit klarer Schnittstelle. Für dich ändert sich
  nichts, neue Apps lassen sich aber künftig viel leichter ergänzen.

## 0.3.8

- **YouTube spielt wie im Browser:** Sofa holt YouTube-Videos jetzt so wie YouTubes eigener
  Web-Player (eine Anfrage pro Video, Streams direkt im Original-Format bis 1080p). Das
  funktioniert auch dann, wenn YouTube den bisherigen Weg mit „kein Bot“ blockiert; der alte
  Weg bleibt als Ausweichlösung.
- **Downloads in voller Qualität:** YouTube-Downloads laufen ebenfalls über den neuen Weg und
  haben jetzt dieselbe Qualität wie beim Abspielen (bis 1080p mit 60 Bildern/s, Originalton).
- **YouTube-Livestreams** laufen jetzt ebenfalls über den neuen Weg (bis 1080p mit 60 Bildern/s).
  Noch nicht gestartete Livestreams sagen, wann es losgeht („Dieser Livestream beginnt heute um
  20:15 Uhr“), statt mit einem Fehler abzubrechen.
- **Abspann-Empfehlungen:** Am Ende von YouTube-Videos erscheinen die vom Kanal verlinkten
  Videos, Playlists und Kanäle über dem Bild – mit ▼ auswählen, OK öffnet, MENU zurück zum Video.
- **Schlanker im Hintergrund:** Sofa braucht für YouTube einen Hintergrunddienst weniger
  (~125 MB weniger Arbeitsspeicher, kleinerer Download); der Ausweichweg startet nur noch bei Bedarf.
- **Sofa löscht nie mehr selbst:** Heruntergeladene Videos bleiben, bis du sie löschst – Videos
  verschwinden manchmal von YouTube oder aus den Mediatheken, dann ist die Kopie die einzige.
  Wird der Speicher knapp, pausieren die Downloads und Sofa fragt nach.
- **Platz schaffen:** Unter Downloads gesehene oder alte Videos und ganze Sendungen gesammelt
  löschen. Sofa prüft vorher, ob sie noch online sind – was nicht mehr online ist, bleibt.
- **Behalten:** Videos mit OK halten → „Behalten“ markieren; sie werden nie zum Löschen vorgeschlagen.
- **Weitere Folgen im Player:** Die Info (OK halten) zeigt jetzt auch bei ZDF, ARD und ORF die
  anderen Folgen der Sendung – nicht nur bei heruntergeladenen.
- **Vorpremieren:** Folgen, die schon vor der TV-Ausstrahlung online sind, zeigen „TV am …“
  statt eines Datums in der Zukunft.
- **Kein Hängenbleiben mehr:** Liefert ein Stream mitten im Video nichts mehr, merkt Sofa das
  und schaltet auf einen anderen Weg um, statt endlos zu laden.

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
