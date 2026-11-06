#import "SFSettings.h"
#import "SFCore.h"

// dev instances: one domain each (de.sofa.dev.<instance>) - parallel tests never share settings
static CFStringRef SFDomain(void) {
    static CFStringRef d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = SFDevMode ? CFBridgingRetain([@"de.sofa.dev." stringByAppendingString:SFDevInstanceName() ?: @"view"]) : CFSTR("de.sofa.app"); });
    return d;
}

static BOOL SFGetBool(CFStringRef key, BOOL dflt) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, SFDomain());
    BOOL on = v && CFGetTypeID(v) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)v) : dflt;
    if (v) CFRelease(v);
    return on;
}

static void SFSetBool(CFStringRef key, BOOL on) {
    CFPreferencesSetAppValue(key, on ? kCFBooleanTrue : kCFBooleanFalse, SFDomain());
    CFPreferencesAppSynchronize(SFDomain());   // straight to disk: the helper reads it too
}

BOOL SFAutostartEnabled(void) { return SFGetBool(CFSTR("autostart"), YES); }
void SFSetAutostartEnabled(BOOL on) { SFSetBool(CFSTR("autostart"), on); }
BOOL SFRemoteLaunchEnabled(void) { return SFGetBool(CFSTR("remoteLaunch"), YES); }
void SFSetRemoteLaunchEnabled(BOOL on) { SFSetBool(CFSTR("remoteLaunch"), on); }
BOOL SFAutoUpdateEnabled(void) { return SFGetBool(CFSTR("autoUpdate"), YES); }
void SFSetAutoUpdateEnabled(BOOL on) { SFSetBool(CFSTR("autoUpdate"), on); }

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
BOOL SFSubtitlesSameLanguage(void) {
    return CFPreferencesGetAppBooleanValue(CFSTR("subtitlesSameLanguage"), SFDomain(), NULL);
}
void SFSetSubtitlesSameLanguage(BOOL on) {
    CFPreferencesSetAppValue(CFSTR("subtitlesSameLanguage"), on ? kCFBooleanTrue : NULL, SFDomain());
    CFPreferencesAppSynchronize(SFDomain());
}
