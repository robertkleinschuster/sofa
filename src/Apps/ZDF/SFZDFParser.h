// ZDF GraphQL / PTMD answers -> Sofa items and streams. Pure: no requests, no library state;
// tested against recorded answers (tests/fixtures/zdf, tools/test-parse). SFZDFApp sends the
// queries (the fragments below) and composes pages; folders come back without a page loader -
// the app attaches it by their ref (zdfshow: / zdfmeta: / zdfpage:).
#import "SFModel.h"

// GraphQL fragments (free-form queries; persisted hashes break on redeploys)
#define SFZDF_IMG_F   @"teaser { description imageWithoutLogo { layouts { dim768X432 dim1280X720 } } }"
#define SFZDF_VIDEO_F @"canonical title editorialDate " SFZDF_IMG_F " smartCollection { title canonical } currentMedia { nodes { __typename ptmdTemplate ... on VodMedia { duration geoLocation vodMediaType } ... on LiveMedia { geoLocation tvService } } }"
#define SFZDF_COLL_F  @"__typename canonical title " SFZDF_IMG_F
#define SFZDF_META_F  @"__typename id canonical title " SFZDF_IMG_F

@interface SFZDFParser : NSObject
+ (SFItem *)itemFromNode:(NSDictionary *)node;   // Video / *SmartCollection / MetaCollection / CuratedCollection by __typename
+ (SFItem *)videoItem:(NSDictionary *)video;
+ (NSString *)image:(NSDictionary *)teaser big:(BOOL)big;
// the media node a video plays: VOD in the main version (not sign language DGS/audio description), or its live stream
+ (NSDictionary *)mainMedia:(NSDictionary *)video;
// curatedCollectionByCanonical -> @[@{title, items}] of its horizontal clusters
+ (NSArray *)clustersIn:(NSDictionary *)curated;
// a season's display name: ZDF names seasons ("2026", "Staffel 3") or only numbers them
+ (NSString *)seasonName:(NSDictionary *)season;
// a PTMD answer -> @{url, subs}: progressive MP4 nearest to 720p (smooth on this Mac), else HLS
+ (NSDictionary *)streamIn:(NSDictionary *)ptmd;
@end

// ZDF geoLocation -> Sofa geoRegion: NONE = everywhere (nil), else the code ("DE", "DACH")
NSString *SFZDFRegion(NSString *geoLocation);
