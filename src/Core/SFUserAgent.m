#import "SFUserAgent.h"
#include <sys/sysctl.h>
#include <sys/utsname.h>

NSString *SFNativeUserAgent(void) {
    static NSString *ua; static dispatch_once_t once;
    dispatch_once(&once, ^{
        // the format CFNetwork builds (a bundle without a version: "<name> (unknown version)")
        NSDictionary *i = [NSBundle mainBundle].infoDictionary;
        NSString *name = i[@"CFBundleName"] ?: [NSProcessInfo processInfo].processName;
        NSString *app = i[@"CFBundleVersion"] ? [NSString stringWithFormat:@"%@/%@", name, i[@"CFBundleVersion"]]
                                              : [name stringByAppendingString:@" (unknown version)"];
        NSString *cf = [NSBundle bundleWithIdentifier:@"com.apple.CFNetwork"].infoDictionary[@"CFBundleVersion"];
        struct utsname u; uname(&u);
        char model[64] = ""; size_t len = sizeof model;
        sysctlbyname("hw.model", model, &len, NULL, 0);
        NSString *m = [@(model) stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
        ua = [NSString stringWithFormat:@"%@ CFNetwork/%@ Darwin/%s (%s) (%@)", app, cf, u.release, u.machine, m];
    });
    return ua;
}

static NSMutableDictionary *gByDomain;   // domain -> user agent

void SFSetUserAgentForDomains(NSString *ua, NSArray *domains) {
    @synchronized ([NSProcessInfo class]) {
        if (!gByDomain) gByDomain = [NSMutableDictionary new];
        for (NSString *d in domains) { if (ua) gByDomain[d.lowercaseString] = ua; else [gByDomain removeObjectForKey:d.lowercaseString]; }
    }
}

NSString *SFUserAgentForHost(NSString *host) {
    NSString *h = host.lowercaseString;
    @synchronized ([NSProcessInfo class]) {
        for (NSString *d in gByDomain)
            if ([h isEqualToString:d] || [h hasSuffix:[@"." stringByAppendingString:d]]) return gByDomain[d];
    }
    return SFNativeUserAgent();
}
