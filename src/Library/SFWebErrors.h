// SFWebErrors - the machine-readable `code` every error answer of Sofa's web API carries next to its
// German `error` text (docs/api.md, api/openapi.yaml `ErrorCode`). The codes are a stable contract:
// clients branch on them (the PWA, the native apps), the text is only shown. A new code is added
// here and in the spec in the same change (tools/test-api compares both lists); a code is never
// renamed or reused for another meaning.
#import <Foundation/Foundation.h>

extern NSString *const SFWebErrBadRequest;        // 400 the request is malformed (body, parameters)
extern NSString *const SFWebErrUnknownItem;       // 400 the item sent back is unusable
extern NSString *const SFWebErrNotVideo;          // 400 the item is no video or live channel
extern NSString *const SFWebErrNotDownloadable;   // 400 the item can't be downloaded
extern NSString *const SFWebErrBadAction;         // 400 an unknown TV action
extern NSString *const SFWebErrBadState;          // 400 an unknown player state in a report
extern NSString *const SFWebErrNotPaired;         // 401 no token, or one Sofa doesn't know (any more)
extern NSString *const SFWebErrWrongCode;         // 403 pairing: the code is not the TV's
extern NSString *const SFWebErrDRM;               // 403 copy-protected: not playable outside the source
extern NSString *const SFWebErrBadSignature;      // 403 a picture path Sofa did not hand out
extern NSString *const SFWebErrForbidden;         // 403 a media path outside its stream
extern NSString *const SFWebErrNotFound;          // 404 no such route
extern NSString *const SFWebErrNoSearch;          // 404 the app has no search
extern NSString *const SFWebErrTVIdle;            // 404 nothing plays on the TV
extern NSString *const SFWebErrNoPicture;         // 404 the picture can't be loaded
extern NSString *const SFWebErrUnsupportedVersion;// 404 an API version this Sofa doesn't speak (/api/v<n>/)
extern NSString *const SFWebErrMethodNotAllowed;  // 405
extern NSString *const SFWebErrTVBusy;            // 409 another video plays on the TV (`busy` names it)
extern NSString *const SFWebErrNoPairingOpen;     // 410 pairing: no code shown on the TV right now
extern NSString *const SFWebErrPageGone;          // 410 a page or list handle Sofa no longer has: reload from the start
extern NSString *const SFWebErrStreamGone;        // 404/410 the stream ended: play the item again (`at` the position)
extern NSString *const SFWebErrNotPlayable;       // 415 no format this client decodes
extern NSString *const SFWebErrEncoderBusy;       // 415 another device's playback is being converted
extern NSString *const SFWebErrRateLimited;       // 429 too many wrong pairing codes
extern NSString *const SFWebErrInternal;          // 500
extern NSString *const SFWebErrUpstream;          // 502 the source failed (a page, a video's address)
extern NSString *const SFWebErrNotReady;          // 503 Sofa is not ready for it yet (the TV, the certificate)
extern NSString *const SFWebErrTimeout;           // 504 the source did not answer in time

// Every code above, sorted (diagnostics, tests)
NSArray *SFWebErrorCodes(void);
// The answer body of an error: {error: message, code}
NSDictionary *SFWebError(NSString *code, NSString *message);
