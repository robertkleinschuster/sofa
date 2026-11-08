// One end card over the video (SFPlayerScreen+Endscreen.m): thumbnail or round avatar, playlist
// chip / follow pill, focus look and caption. Kinds are the "endCards" kinds of SFApp.h.
#import "SFLayers.h"
#import "SFTheme.h"

static NSString *const SFEndCardVideo = @"video", *const SFEndCardPlaylist = @"playlist", *const SFEndCardChannel = @"channel", *const SFEndCardFollow = @"follow";

@interface SFEndTile : CALayer
@property (nonatomic, strong) NSDictionary *element;
@property (nonatomic, copy) NSString *kind;   // video, playlist, channel, follow
@property (nonatomic) double startS, endS;   // visibility window (s); endS 0 = until the end
@property (nonatomic) BOOL shownNow;
@property (nonatomic) BOOL focused;
@property (nonatomic) BOOL following;        // SUBSCRIBE: current follow state
@property (nonatomic, readonly) BOOL round;
- (void)buildWithTheme:(SFTheme *)theme;
- (void)loadImage;
- (void)setLook:(BOOL)engaged focused:(BOOL)focused bounds:(CGRect)limit;
- (NSString *)elementTitle;
- (NSString *)okAction;                      // what OK does, for the hint
// every text the tile may draw - measured off the main thread before it is built (fonts warm)
- (NSArray *)texts;
- (CGRect)captionFrame;                      // focused round tile: its name caption (superlayer coords), else null
@end
