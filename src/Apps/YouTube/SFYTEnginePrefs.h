// SFYTEnginePrefs - the engine browser's prefs (user.js, written by SFYTBrowser at every start; a
// running browser with other prefs is not taken over). Every value with its reason.
#import <Foundation/Foundation.h>

NSDictionary *SFYTEnginePrefs(void);
NSString *SFYTUserJS(NSDictionary *prefs);   // the prefs as user.js lines, sorted
