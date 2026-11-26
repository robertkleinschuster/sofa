// SFYTBrowserFormats - which of YouTube's formats a client of the web API gets (docs/api.md "Formats",
// docs/pwa.md §3): the codecs it decodes, in its order of preference, as the engine's requirement for
// the session (res/sofa-yt lib/formats.ts pickVideo/pickAudio). Pure (tests/units/ytbrowserformats.m).
#import <Foundation/Foundation.h>

// `formats`: the client's codecs (SFAVBrowserCodec names: avc1, hvc1, vp09, av01, mp4a, opus) in its
// order. -> {vcodecs, acodecs}: the engine's names of those YouTube offers (avc1, vp9, av01; mp4a,
// opus), in the same order. A client naming none of a kind gets H.264 resp. AAC - what every player
// decodes (an older PWA said nothing at all).
NSDictionary *SFYTBrowserCodecs(NSArray *formats);
