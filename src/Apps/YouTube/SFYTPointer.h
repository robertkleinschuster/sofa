// A pointer on an X display (the engine's Xvfb), moved and clicked through XTest: the X server
// delivers the events as a user's - a page sees trusted mouse events. Moves like a hand: a slightly
// curved, eased path from where the pointer is, a hover before the press, press and release apart.
// One serial queue per pointer; the X connection is opened per gesture and closed after it.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface SFYTPointer : NSObject
- (instancetype)initWithDisplay:(NSString *)display;   // ":N"
@property (nonatomic, readonly) NSString *display;
// Moves to a random point well inside `rect` (screen pixels) and clicks the left button there.
// done(ok) on the main queue: NO when the display could not be opened or has no XTest.
- (void)clickInRect:(CGRect)rect done:(void (^)(BOOL ok))done;
@end
