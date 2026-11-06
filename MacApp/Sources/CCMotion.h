// The motion vocabulary of the Windows app (Controls/Motion.cs, Entrance.cs, Smooth.cs…) on Core Animation:
// the same easing curves, durations and delays.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef double (^CCEase)(double t);

/// QuarticEase out — the default.
FOUNDATION_EXPORT CCEase CCEaseOut;
/// QuinticEase out.
FOUNDATION_EXPORT CCEase CCEaseOutStrong;
/// CubicEase in-out.
FOUNDATION_EXPORT CCEase CCEaseInOut;
/// CubicEase in.
FOUNDATION_EXPORT CCEase CCEaseIn;
/// CubicEase out.
FOUNDATION_EXPORT CCEase CCEaseCubicOut;
/// SineEase in-out.
FOUNDATION_EXPORT CCEase CCEaseSine;
FOUNDATION_EXPORT CCEase CCEaseLinear;
/// BackEase out with the given amplitude (overshoots, then settles).
CCEase CCEaseBack(double amplitude);
/// BackEase out, amplitude 0.35 — "Spring" in Motion.cs.
FOUNDATION_EXPORT CCEase CCEaseSpring;

/// The global "Animations" switch.
BOOL CCMotionEnabled(void);
void CCSetMotionEnabled(BOOL enabled);

/// A main-thread value animation driven by a shared 120 Hz timer.
@interface CCTween : NSObject
+ (CCTween *)from:(double)from
               to:(double)to
         duration:(double)milliseconds
            delay:(double)delayMilliseconds
             ease:(nullable CCEase)ease
           update:(void (^)(double value))update
       completion:(nullable void (^)(BOOL finished))completion;
@property (nonatomic, readonly) double value;
@property (nonatomic, readonly) BOOL running;
- (void)stop;
@end

/// Animates a numeric layer property from its on-screen value to `to` and leaves the model at `to`.
void CCAnimateNumber(CALayer *layer, NSString *keyPath, double to, double milliseconds, CCEase _Nullable ease, double delayMilliseconds);

/// A view's own transform, applied around its centre: scale, vertical offset (positive = down) and rotation (degrees).
typedef struct {
    double scale;
    double dy;
    double rotation;
} CCXform;
CCXform CCXformIdentity(void);
CCXform CCXformMake(double scale, double dy, double rotation);
/// Moves the view's transform to `target`, starting from wherever it is on screen right now.
void CCTransformView(NSView *view, CCXform target, double milliseconds, CCEase _Nullable ease);
/// Re-centres the current transform after a size change.
void CCXformRelayout(NSView *view);

/// Fade + rise, once: opacity 0 → its value over 380 ms, offset `distance` → 0 over 560 ms, after `delay` ms.
void CCEntrance(NSView *view, double delayMilliseconds, double distance);
/// The page transition of PageHost.cs.
void CCSlideIn(NSView *view, double distance, double delayMilliseconds);
/// +1 when a positive offset moves the view down on screen.
double CCDownSign(NSView *view);

/// Runs a block with implicit layer animations off.
void CCWithoutAnimation(void (^block)(void));

NS_ASSUME_NONNULL_END
