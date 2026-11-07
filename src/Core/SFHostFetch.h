// Hosts a source fetches through its own client. A source that must speak to its service as one
// client (YouTube: its engine's Firefox - docs/architecture.md "Network identity") registers that
// client for the service's hosts; Sofa's generic loaders (pictures, download thumbnails) then fetch
// those hosts through it - never natively, no fallback: a second client next to it is what the
// registration is there to prevent.
#import "SFCore.h"

// status: the host's HTTP status, 0 without an answer (data nil). Any queue.
typedef void (^SFHostFetchDone)(NSData *data, NSInteger status);
typedef void (^SFHostFetcher)(NSURL *url, SFHostFetchDone done);

// `hosts`: exact host names or ".suffix" entries (".ggpht.com" = every host ending so). Launch
// (SFApp start), before the first load.
void SFRegisterHostFetcher(NSArray *hosts, SFHostFetcher fetcher);
// The fetcher registered for `url`'s host; nil = fetched natively.
SFHostFetcher SFHostFetcherFor(NSURL *url);
