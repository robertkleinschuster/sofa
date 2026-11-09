// SFHLSPlaylist - pure reading of HLS playlists (RFC 8216) for the media proxy (SFMediaProxy+HLS):
// tag attributes, absolute URIs, a media playlist's resources, the variant a download takes. No
// requests, no state: any thread; tested on playlists in tests/units/hlsplaylist.m.
#import <Foundation/Foundation.h>

extern const int kSFHLSMaxHeight;   // the highest variant taken (1080p)

NSDictionary *SFHLSAttributes(NSString *line);             // a tag's attribute list: KEY=value / KEY="value"
NSString *SFHLSAbsolute(NSString *uri, NSString *base);    // absolute against base; nil only for a nil uri
NSArray *SFHLSResources(NSString *text, NSString *base);   // a media playlist's URIs (segments, keys, init sections)
// the best variant up to kSFHLSMaxHeight (by bandwidth) and its group's default audio rendition when
// it has its own playlist: @[variant URL, audio URL?]; nil = none
NSArray *SFHLSChooseVariant(NSString *master, NSString *base, long long *bandwidth);
// the master with only that variant and its audio renditions (what a download keeps is what plays)
NSString *SFHLSOneVariant(NSString *master, NSString *base);
