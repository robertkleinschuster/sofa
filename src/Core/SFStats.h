// Usage counters per day (table `stats` in the store): which path served what, how often each
// fallback was needed - the data for deciding whether a fallback can go (user 2026-11-05: "wir
// zeichnen dann auf wie oft welche fallbacks benötigt werden und können diese bei bedarf kicken").
// Events are short dotted names, e.g. "yt.play.sabr", "yt.play.ytdlp.sabr-error", "player.av-fallback".
// Kept 180 days. Local only, never sent anywhere.
#import "SFCore.h"

void SFCount(NSString *event);
// event -> total over the last `days` days, for the dev command `stats` and diagnostics
NSDictionary *SFStatsTotals(NSInteger days);
