#import "CCMotion.h"
#import <objc/runtime.h>

static BOOL gMotion = YES;
BOOL CCMotionEnabled(void) { return gMotion; }
void CCSetMotionEnabled(BOOL enabled) { gMotion = enabled; }

static double BackIn(double t, double a) { return t * t * t - t * a * sin(M_PI * t); }

CCEase CCEaseOut = ^double(double t) { return 1 - pow(1 - t, 4); };
CCEase CCEaseOutStrong = ^double(double t) { return 1 - pow(1 - t, 5); };
CCEase CCEaseInOut = ^double(double t) { return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2; };
CCEase CCEaseIn = ^double(double t) { return t * t * t; };
CCEase CCEaseCubicOut = ^double(double t) { return 1 - pow(1 - t, 3); };
CCEase CCEaseSine = ^double(double t) { return (1 - cos(M_PI * t)) / 2; };
CCEase CCEaseLinear = ^double(double t) { return t; };
CCEase CCEaseSpring = ^double(double t) { return 1 - BackIn(1 - t, 0.35); };

CCEase CCEaseBack(double amplitude) {
    return ^double(double t) { return 1 - BackIn(1 - t, amplitude); };
}

void CCWithoutAnimation(void (^block)(void)) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    block();
    [CATransaction commit];
}

// ───────────── tweens ─────────────

@interface CCTween ()
@property (nonatomic) double from, to, duration, start;
@property (nonatomic, copy) CCEase ease;
@property (nonatomic, copy) void (^update)(double);
@property (nonatomic, copy) void (^completion)(BOOL);
@property (nonatomic, readwrite) double value;
@property (nonatomic, readwrite) BOOL running;
@end

static NSMutableArray<CCTween *> *gTweens;
static NSTimer *gTimer;

static void Tick(void) {
    double now = CACurrentMediaTime();
    NSArray *active = [gTweens copy];
    for (CCTween *tween in active) {
        if (!tween.running) continue;
        if (now < tween.start) continue;
        double t = tween.duration <= 0 ? 1 : MIN(1, (now - tween.start) / tween.duration);
        tween.value = tween.from + (tween.to - tween.from) * tween.ease(t);
        tween.update(tween.value);
        if (t >= 1) {
            tween.running = NO;
            [gTweens removeObject:tween];
            if (tween.completion) tween.completion(YES);
        }
    }
    if (gTweens.count == 0) {
        [gTimer invalidate];
        gTimer = nil;
    }
}

@implementation CCTween

+ (CCTween *)from:(double)from to:(double)to duration:(double)milliseconds delay:(double)delayMilliseconds ease:(CCEase)ease
           update:(void (^)(double))update completion:(void (^)(BOOL))completion {
    CCTween *tween = [CCTween new];
    tween.from = from;
    tween.to = to;
    tween.value = from;
    tween.update = update;
    tween.completion = completion;
    tween.ease = ease ?: CCEaseOut;

    if (!gMotion || milliseconds <= 0) {
        tween.value = to;
        update(to);
        if (completion) completion(YES);
        return tween;
    }

    tween.duration = milliseconds / 1000.0;
    tween.start = CACurrentMediaTime() + delayMilliseconds / 1000.0;
    tween.running = YES;
    if (!gTweens) gTweens = [NSMutableArray array];
    [gTweens addObject:tween];
    if (delayMilliseconds <= 0) update(from);
    if (!gTimer) {
        gTimer = [NSTimer timerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *timer) { Tick(); }];
        [NSRunLoop.mainRunLoop addTimer:gTimer forMode:NSRunLoopCommonModes];
    }
    return tween;
}

- (void)stop {
    if (!self.running) return;
    self.running = NO;
    [gTweens removeObject:self];
    if (self.completion) self.completion(NO);
}

@end

// ───────────── layer animations ─────────────

static NSArray *Samples(double from, double to, double seconds, CCEase ease) {
    NSUInteger n = MAX(2, (NSUInteger)ceil(seconds * 60));
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:n + 1];
    for (NSUInteger i = 0; i <= n; i++) [values addObject:@(from + (to - from) * ease((double)i / n))];
    return values;
}

void CCAnimateNumber(CALayer *layer, NSString *keyPath, double to, double milliseconds, CCEase ease, double delayMilliseconds) {
    CALayer *presentation = layer.presentationLayer ?: layer;
    double from = [[presentation valueForKeyPath:keyPath] doubleValue];
    CCWithoutAnimation(^{ [layer setValue:@(to) forKeyPath:keyPath]; });
    if (!gMotion || milliseconds <= 0 || fabs(from - to) < 1e-6) {
        [layer removeAnimationForKey:keyPath];
        return;
    }
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    a.values = Samples(from, to, milliseconds / 1000.0, ease ?: CCEaseOut);
    a.duration = milliseconds / 1000.0;
    a.calculationMode = kCAAnimationLinear;
    if (delayMilliseconds > 0) {
        a.beginTime = CACurrentMediaTime() + delayMilliseconds / 1000.0;
        a.fillMode = kCAFillModeBackwards;
    }
    [layer addAnimation:a forKey:keyPath];
}

// ───────────── view transforms ─────────────

CCXform CCXformIdentity(void) { return (CCXform){ 1, 0, 0 }; }
CCXform CCXformMake(double scale, double dy, double rotation) { return (CCXform){ scale, dy, rotation }; }

@interface CCXformState : NSObject
@property (nonatomic) CCXform from, to;
@property (nonatomic) double start, duration;
@property (nonatomic, copy) CCEase ease;
@end
@implementation CCXformState
@end

static char kXformKey;

static CCXform Lerp(CCXform a, CCXform b, double t) {
    return (CCXform){ a.scale + (b.scale - a.scale) * t, a.dy + (b.dy - a.dy) * t, a.rotation + (b.rotation - a.rotation) * t };
}

static CCXform Current(CCXformState *state) {
    if (!state) return CCXformIdentity();
    if (state.duration <= 0) return state.to;
    double t = MIN(1, MAX(0, (CACurrentMediaTime() - state.start) / state.duration));
    return Lerp(state.from, state.to, state.ease(t));
}

double CCDownSign(NSView *view) {
    // A view's transform moves it inside its superview's layer, which has the superview's orientation.
    return view.superview.isFlipped ? 1 : -1;
}

static CATransform3D Matrix(NSView *view, CCXform x) {
    CGSize size = view.layer.bounds.size;
    CGPoint anchor = view.layer.anchorPoint;
    double cx = size.width * (0.5 - anchor.x), cy = size.height * (0.5 - anchor.y);
    CATransform3D m = CATransform3DMakeTranslation(cx, cy, 0);
    m = CATransform3DRotate(m, -x.rotation * M_PI / 180 * CCDownSign(view), 0, 0, 1);
    m = CATransform3DScale(m, x.scale, x.scale, 1);
    m = CATransform3DTranslate(m, -cx, -cy, 0);
    CATransform3D move = CATransform3DMakeTranslation(0, x.dy * CCDownSign(view), 0);
    return CATransform3DConcat(m, move);
}

void CCTransformView(NSView *view, CCXform target, double milliseconds, CCEase ease) {
    view.wantsLayer = YES;
    CCXformState *state = objc_getAssociatedObject(view, &kXformKey);
    CCXform from = Current(state);
    if (!state) {
        state = [CCXformState new];
        objc_setAssociatedObject(view, &kXformKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL animate = gMotion && milliseconds > 0 && view.window != nil;
    state.from = from;
    state.to = target;
    state.start = CACurrentMediaTime();
    state.duration = animate ? milliseconds / 1000.0 : 0;
    state.ease = ease ?: CCEaseOut;

    CALayer *layer = view.layer;
    CCWithoutAnimation(^{ layer.transform = Matrix(view, target); });
    if (!animate) {
        [layer removeAnimationForKey:@"cc.xform"];
        return;
    }

    NSUInteger n = MAX(2, (NSUInteger)ceil(state.duration * 60));
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:n + 1];
    for (NSUInteger i = 0; i <= n; i++)
        [values addObject:[NSValue valueWithCATransform3D:Matrix(view, Lerp(from, target, state.ease((double)i / n)))]];
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    a.values = values;
    a.duration = state.duration;
    [layer addAnimation:a forKey:@"cc.xform"];
}

void CCXformRelayout(NSView *view) {
    CCXformState *state = objc_getAssociatedObject(view, &kXformKey);
    if (!state || !view.layer) return;
    CCXform target = state.to;
    if (target.scale == 1 && target.rotation == 0 && [view.layer animationForKey:@"cc.xform"] == nil) {
        CCWithoutAnimation(^{ view.layer.transform = Matrix(view, target); });
        return;
    }
    if ([view.layer animationForKey:@"cc.xform"] == nil)
        CCWithoutAnimation(^{ view.layer.transform = Matrix(view, target); });
}

// ───────────── entrances ─────────────

static void AddOffsetAnimation(NSView *view, NSString *key, double distance, double milliseconds, CCEase ease, double delay) {
    CAKeyframeAnimation *move = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.y"];
    move.values = Samples(distance * CCDownSign(view), 0, milliseconds / 1000.0, ease);
    move.duration = milliseconds / 1000.0;
    move.additive = YES;
    move.beginTime = CACurrentMediaTime() + delay / 1000.0;
    move.fillMode = kCAFillModeBackwards;
    [view.layer addAnimation:move forKey:key];
}

static void AddFadeAnimation(NSView *view, NSString *key, double milliseconds, CCEase ease, double delay) {
    double opacity = view.layer.opacity;
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values = Samples(-opacity, 0, milliseconds / 1000.0, ease);
    fade.duration = milliseconds / 1000.0;
    fade.additive = YES;
    fade.beginTime = CACurrentMediaTime() + delay / 1000.0;
    fade.fillMode = kCAFillModeBackwards;
    [view.layer addAnimation:fade forKey:key];
}

void CCEntrance(NSView *view, double delayMilliseconds, double distance) {
    if (!gMotion) return;
    view.wantsLayer = YES;
    AddFadeAnimation(view, @"cc.entrance.fade", 380, CCEaseOut, delayMilliseconds);
    AddOffsetAnimation(view, @"cc.entrance.move", distance, 560, CCEaseOutStrong, delayMilliseconds);
}

void CCSlideIn(NSView *view, double distance, double delayMilliseconds) {
    if (!gMotion) return;
    view.wantsLayer = YES;
    AddFadeAnimation(view, @"cc.page.fade", 320, CCEaseOut, delayMilliseconds);
    AddOffsetAnimation(view, @"cc.page.move", distance, 520, CCEaseOutStrong, delayMilliseconds);
}
