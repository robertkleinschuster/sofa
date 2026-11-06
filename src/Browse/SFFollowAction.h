// Follow / unfollow a show or channel from a button (channel page, player info panel, end card).
// Following is immediate. Unfollowing asks first when it would also end automatic downloads, and
// always when `askAlways` - a button that has focus when its page opens (channel page): a
// reflexive OK must not silently drop the show.
#import "SFScreen.h"
#import "SFModel.h"
#import "SFTheme.h"

void SFToggleFollow(SFNavigator *nav, SFItem *folder, SFTheme *theme, BOOL askAlways);
