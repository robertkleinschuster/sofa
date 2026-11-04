// Laufzeit-Werkzeuge (ffmpeg, node, python, rsvg-convert, PO-Token-Server) finden.
//
// Release-Bundle (tools/make-release): alles liegt in Sofa.app/Contents/Runtime
// (bin/, Python.framework/, bgutil/, etc/; Bibliotheken in Contents/Frameworks), die Bibliotheken sind @loader_path-relativ
// umgelinkt -> Sofa braucht kein MacPorts. Entwicklungs-/Port-Build ohne Runtime-Ordner:
// Werkzeuge aus dem MacPorts-Prefix.
#import <Foundation/Foundation.h>

NSString *SFRuntimeDir(void);              // .../Contents/Runtime oder nil (Port/Dev)
NSString *SFTool(NSString *name);          // Runtime/bin/<name> oder /opt/local/bin/<name>
NSString *SFPythonPath(void);              // Basis-Python für das yt-dlp-venv
NSString *SFCABundle(void);                // CA-Zertifikate für libcurl (nil = libcurl-Default)
// Release-Bundle: ~/Library/LaunchAgents/de.sofa.{remote,app}.plist auf dieses Bundle
// einrichten (Fernbedienungs-Helper sofort laden, Autostart ab nächster Anmeldung).
// Nicht, wenn der MacPorts-Port seine Agents installiert hat. Nur aus der echten App aufrufen.
void SFInstallAgents(void);
// Einmal früh in main(): PATH, SSL_CERT_FILE, FONTCONFIG_*, SOFA_NODE für Kindprozesse.
void SFRuntimeSetup(void);
