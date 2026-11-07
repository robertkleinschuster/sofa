// SFPlayerInfoScreen - shared by its files: state and the parts the actions file uses.
#import "SFPlayerInfoScreen.h"
#import "SFPlayerScreen+Private.h"

@interface SFPlayerInfoScreen () {
    __weak SFPlayerScreen *_player;
    __weak SFNavigator *_nav;      // kept: after removal self.navigator may still be needed for cleanup
    SFItem *_item;                 // the player's item this panel shows (identity: changes -> rebuild)
    NSDictionary *_details;        // YouTube watch page: description, channel, channelID, avatar, date
    NSArray *_related;             // YouTube recommendations (nil = not (yet) known)
    NSArray *_showEpisodes;        // online show (ZDF/ARD/ORF ...): episodes from its show page
    NSString *_showTitle;
    NSMapTable *_handlers;         // shown tile -> block (OK on a video tile of a shelf)
    BOOL _refreshQueued;
    NSMutableArray *_actionOrder;  // action ids in the order they first appeared (SFPlayerInfoScreen+Actions)
}
- (SFItem *)enrichedItem;
- (void)refresh;
- (void)leave;
@end

@interface SFPlayerInfoScreen (Actions)
- (NSArray *)actionsWithHero:(SFItem *)hero;   // the action buttons, in a stable order
@end
