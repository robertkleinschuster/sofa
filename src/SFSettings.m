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
BOOL SFStartupQuestionsAsked(void) { return SFGetBool(CFSTR("startupAsked"), NO); }
void SFSetStartupQuestionsAsked(void) { SFSetBool(CFSTR("startupAsked"), YES); }
