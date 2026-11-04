// Typsichere Zugriffe auf geparstes JSON (Provider-APIs): liefern nil statt NSNull oder eines
// falschen Typs, damit z.B. [dict(x)[@"a"] length] nie auf einem NSNumber landet.
#import <Foundation/Foundation.h>

static inline id nn(id v) { return (v == [NSNull null]) ? nil : v; }
static inline NSString *str(id v) { v = nn(v); return [v isKindOfClass:[NSString class]] ? v : nil; }
static inline NSArray *arr(id v) { v = nn(v); return [v isKindOfClass:[NSArray class]] ? v : nil; }
static inline NSDictionary *dict(id v) { v = nn(v); return [v isKindOfClass:[NSDictionary class]] ? v : nil; }
