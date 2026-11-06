// InnerTube: YouTube's own web API (WEB client), without sign-in - everything Sofa needs
// (channels, playlists, search, player data, recommendations) is public. docs/youtube.md §3.
// The request and the shapes of its JSON; what the JSON means is SFYTParser's.
#import "SFJSON.h"
#import "SFNet.h"

void SFYTCall(NSString *endpoint, NSDictionary *body, NSTimeInterval cacheAge, SFJSONDone done);

id SFYTPath(id root, NSString *path);   // "a.b.0.c": dictionaries by key, arrays by index; nil when missing
NSString *SFYTText(id node);            // text node: "..." | {simpleText} | {runs:[{text}]} | {content}
NSString *SFYTLastURL(id sources);      // last (largest) of a thumbnails/sources list, "//" made https
