#import "SFSettings.h"
#import "SFCore.h"

static CFStringRef SFDomain(void) { return SFDevMode ? CFSTR("de.sofa.dev") : CFSTR("de.sofa.app"); }

static BOOL SFGetBool(CFStringRef key, BOOL dflt) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, SFDomain());
    BOOL on = v && CFGetTypeID(v) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)v) : dflt;
    if (v) CFRelease(v);
    return on;
}

static void SFSetBool(CFStringRef key, BOOL on) {
    CFPreferencesSetAppValue(key, on ? kCFBooleanTrue : kCFBooleanFalse, SFDomain());
    CFPreferencesAppSynchronize(SFDomain());   // sofort auf Platte: der Helper liest mit
}

BOOL SFAutostartEnabled(void) { return SFGetBool(CFSTR("autostart"), YES); }
void SFSetAutostartEnabled(BOOL on) { SFSetBool(CFSTR("autostart"), on); }
BOOL SFRemoteLaunchEnabled(void) { return SFGetBool(CFSTR("remoteLaunch"), YES); }
void SFSetRemoteLaunchEnabled(BOOL on) { SFSetBool(CFSTR("remoteLaunch"), on); }
BOOL SFAutoUpdateEnabled(void) { return SFGetBool(CFSTR("autoUpdate"), YES); }
void SFSetAutoUpdateEnabled(BOOL on) { SFSetBool(CFSTR("autoUpdate"), on); }
BOOL SFStartupQuestionsAsked(void) { return SFGetBool(CFSTR("startupAsked"), NO); }
void SFSetStartupQuestionsAsked(void) { SFSetBool(CFSTR("startupAsked"), YES); }
// Versteckter Notschalter (keine Oberfläche): defaults write de.sofa.app preferAVFoundation -bool YES
BOOL SFPreferAVFoundation(void) { return SFGetBool(CFSTR("preferAVFoundation"), NO); }

NSString *SFSubtitleLanguage(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("subtitleLanguage"), SFDomain());
    NSString *s = v && CFGetTypeID(v) == CFStringGetTypeID() ? [(__bridge NSString *)v copy] : nil;
    if (v) CFRelease(v);
    return s.length ? s : nil;
}
void SFSetSubtitleLanguage(NSString *lang) {
    CFPreferencesSetAppValue(CFSTR("subtitleLanguage"), (__bridge CFStringRef)(lang.length ? lang : nil), SFDomain());
    CFPreferencesAppSynchronize(SFDomain());
}
BOOL SFDeleteWatchedDownloads(void) {
    Boolean valid = false;
    Boolean v = CFPreferencesGetAppBooleanValue(CFSTR("deleteWatchedDownloads"), SFDomain(), &valid);
    return valid ? v : YES;
}
void SFSetDeleteWatchedDownloads(BOOL on) {
    CFPreferencesSetAppValue(CFSTR("deleteWatchedDownloads"), on ? kCFBooleanTrue : kCFBooleanFalse, SFDomain());
    CFPreferencesAppSynchronize(SFDomain());
}
BOOL SFSubtitlesSameLanguage(void) {
    return CFPreferencesGetAppBooleanValue(CFSTR("subtitlesSameLanguage"), SFDomain(), NULL);
}
void SFSetSubtitlesSameLanguage(BOOL on) {
    CFPreferencesSetAppValue(CFSTR("subtitlesSameLanguage"), on ? kCFBooleanTrue : NULL, SFDomain());
    CFPreferencesAppSynchronize(SFDomain());
}
