// Type-safe access to parsed JSON (provider APIs): return nil instead of NSNull or a
// wrong type, so that e.g. [dict(x)[@"a"] length] never lands on an NSNumber.
#import <Foundation/Foundation.h>

static inline id nn(id v) { return (v == [NSNull null]) ? nil : v; }
static inline NSString *str(id v) { v = nn(v); return [v isKindOfClass:[NSString class]] ? v : nil; }
static inline NSArray *arr(id v) { v = nn(v); return [v isKindOfClass:[NSArray class]] ? v : nil; }
static inline NSDictionary *dict(id v) { v = nn(v); return [v isKindOfClass:[NSDictionary class]] ? v : nil; }
