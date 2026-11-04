# Changelog

Was sich für Nutzer ändert. Der Abschnitt einer Version ist zugleich der Text ihres
GitHub-Releases (`tools/publish-release`) und erscheint in Sofa unter
Einstellungen → „Update installieren“.

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
