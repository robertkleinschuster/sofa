// InnerTube: YouTube's own web API (WEB client), without sign-in - everything Sofa needs
// (channels, playlists, search, recommendations) is public. docs/youtube.md §3.
// The request and the shapes of its JSON; what the JSON means is SFYTParser's.
//
// One identity: the calls go through the sofa-yt sidecar's session (POST /yt/<endpoint>), the same
// browser, visitor data and cookies as playback - not as a second client of Sofa's own (until
// 2026-11-06 a Safari user agent over libcurl without visitor data: one of the causes of the bot
// checks). Endpoints: browse, next, search, navigation/resolve_url; never "player" (the sidecar's
// job, with a PO token). Answers are cached here like any request (SFNet), keyed by endpoint + body.
#import "SFJSON.h"
#import "SFNet.h"

void SFYTCall(NSString *endpoint, NSDictionary *body, NSTimeInterval cacheAge, SFJSONDone done);             // what the viewer opens
void SFYTCallBackground(NSString *endpoint, NSDictionary *body, NSTimeInterval cacheAge, SFJSONDone done);   // refreshes: refused during a bot-check pause

id SFYTPath(id root, NSString *path);   // "a.b.0.c": dictionaries by key, arrays by index; nil when missing
NSString *SFYTText(id node);            // text node: "..." | {simpleText} | {runs:[{text}]} | {content}
NSString *SFYTLastURL(id sources);      // last (largest) of a thumbnails/sources list, "//" made https
