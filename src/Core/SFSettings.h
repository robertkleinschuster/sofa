// User settings (macOS preferences, also readable by the helper SofaRemote).
// Domain de.sofa.app (dev instances: de.sofa.dev.<instance>, never affect the real app).
//
// RULE: this holds what the user deliberately chooses (settings menu, prompts, switches on
// screens). State that Sofa keeps itself (phone pairing, recent searches, last used
// keyboard layout, migration markers, timestamps) belongs in SFStore (-setting:/-setSetting:).
#import <Foundation/Foundation.h>

BOOL SFAutostartEnabled(void);            // launch at login (default: on)
void SFSetAutostartEnabled(BOOL on);
BOOL SFRemoteLaunchEnabled(void);         // launch a closed Sofa with any Apple Remote button (default: on)
void SFSetRemoteLaunchEnabled(BOOL on);
BOOL SFAutoUpdateEnabled(void);           // download updates from GitHub automatically + install when idle (default: on)
void SFSetAutoUpdateEnabled(BOOL on);
// Preferred subtitle language (e.g. "de"); nil = subtitles off (default). Remembered on every
// choice in the player and applied to the next video when the language is available.
NSString *SFSubtitleLanguage(void);
void SFSetSubtitleLanguage(NSString *lang);
// Subtitles even when in the same language as the audio (hard-of-hearing subtitles); subtitleLanguage,
// by contrast, only applies to foreign-language audio (translation).
BOOL SFSubtitlesSameLanguage(void);
void SFSetSubtitlesSameLanguage(BOOL on);
// Diagnosis switches (developer, off by default; never in the settings menu): set from a shell with
// `defaults write de.sofa.app <name> -bool YES` (dev instance: de.sofa.dev.<instance>), take effect at
// the next read (re-read from disk each time - no relaunch). Names: ytEngineDebug (the engine's
// per-request lines, at its next start), mpvDebugDemux (what mpv's demuxers read, next player open).
BOOL SFDiagnosisEnabled(NSString *name);
