// Player info panel (OK hold in the player): translucent overlay over the running video with the
// video's description, actions (audio, subtitles, online playback, channel/show, follow, download,
// watch later), the playlist / up next, more episodes of a downloaded show and YouTube
// recommendations. Built on SFBrowseScreen (overlay mode): tiles, focus, hero and the OK-hold
// context menu come from there.
//
// Lifecycle rules (no ordering assumptions): the panel never starts, stops or restarts playback by
// itself; it follows the player (new item -> rebuilt, player closed -> gone); late data for an older
// item or a closed panel is dropped; a failed or empty fetch just leaves its shelf out.
#import "SFBrowseScreen.h"

@class SFPlayerScreen;

// Follow / unfollow a channel or show folder with toast feedback; unfollowing a show that also
// downloads automatically asks first (destructive). Shared by the info panel and the end screen.
void SFToggleFollow(SFNavigator *nav, SFItem *folder, SFTheme *theme);

@interface SFPlayerInfoScreen : SFBrowseScreen
- (instancetype)initWithPlayer:(SFPlayerScreen *)player;
@end
