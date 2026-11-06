// The controls of the Windows app's Themes/Styles.xaml and Controls/*.cs, drawn with Core Animation.
#import <Cocoa/Cocoa.h>
#import "CCCore.h"
#import "CCMotion.h"
#import "CCTheme.h"

NS_ASSUME_NONNULL_BEGIN

typedef NSColor *_Nonnull (^CCColorBlock)(void);

/// Views that restyle themselves when the theme or the language changes.
@protocol CCLive <NSObject>
@optional
- (void)applyTheme;
- (void)applyLanguage;
@end

@interface NSView (CC)
- (void)cc_broadcastTheme;
- (void)cc_broadcastLanguage;
/// Tells every view below that the pointer is over `hit` now (nil: over none of them). Hover comes from here, not from
/// enter and exit events alone: a row that scrolls out from under a still pointer gets neither.
- (void)cc_syncHover:(nullable NSView *)hit;
@end

/// translatesAutoresizingMaskIntoConstraints = NO.
__kindof NSView *CCAuto(__kindof NSView *view);
/// Whether y grows downwards inside this layer (an odd number of flipped layers on the way to the root).
BOOL CCLayerYDown(CALayer *layer);
void CCPin(NSView *view, NSView *container, NSEdgeInsets insets);
void CCSize(NSView *view, CGFloat width, CGFloat height);
NSStackView *CCHStack(NSArray<NSView *> *views, CGFloat spacing);
NSStackView *CCVStack(NSArray<NSView *> *views, CGFloat spacing);
/// A stretchable gap for stack views.
NSView *CCSpacer(void);

@interface CCFlippedView : NSView
@end

// ───────────── text & icons ─────────────

@interface CCLabel : NSTextField <CCLive>
+ (instancetype)text:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight role:(CCRole)role;
+ (instancetype)key:(NSString *)locKey size:(CGFloat)size weight:(NSFontWeight)weight role:(CCRole)role;
@property (nonatomic) CCRole role;
@property (nonatomic, copy, nullable) CCColorBlock colorBlock;
@property (nonatomic, copy, nullable) NSString *locKey;
/// Wraps onto several lines (otherwise one line, truncated with an ellipsis).
@property (nonatomic) BOOL wraps;
/// For a wrapping label that nothing gives a width: as wide as its text up to this, then it wraps.
@property (nonatomic) CGFloat wrapLimit;
@property (nonatomic) CGFloat lineHeight;
@end

typedef NS_ENUM(NSInteger, CCCounterPart) { CCCounterAll, CCCounterNumber, CCCounterUnit, CCCounterInteger };

/// Tweens between byte values like Controls/Counter.cs.
@interface CCCounter : CCLabel
@property (nonatomic) CCCounterPart part;
@property (nonatomic) double duration;
@property (nonatomic, readonly) long long bytes;
/// Called after each repaint, for containers that lay out by fitting size (the legend's flow).
@property (nonatomic, copy, nullable) void (^onRender)(void);
- (void)setBytes:(long long)bytes;
/// Re-renders the current value (after a language change).
- (void)render;
@end

@interface CCIcon : NSImageView <CCLive>
+ (instancetype)symbol:(NSString *)symbol size:(CGFloat)size weight:(NSFontWeight)weight role:(CCRole)role;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic) CCRole role;
@property (nonatomic, copy, nullable) CCColorBlock colorBlock;
@end

// ───────────── surfaces ─────────────

/// A rounded, layer-backed rectangle whose colours are re-resolved on theme changes.
@interface CCBox : NSView <CCLive>
@property (nonatomic, copy, nullable) CCColorBlock fill;
@property (nonatomic, copy, nullable) CCColorBlock stroke;
@property (nonatomic, copy, nullable) NSArray<NSColor *> *_Nonnull (^gradient)(void);
@property (nonatomic) CGFloat radius;
@property (nonatomic) CGFloat strokeWidth;
/// Pushes the colour blocks into the layer; subclasses with state-dependent colours override this.
- (void)applyBoxColors;
@end

/// The "Card" / "CardHover" styles: hover lifts by 4 pt and grows 1.2 %, icon tiles inside bounce.
@interface CCCard : CCBox
+ (instancetype)card;
@property (nonatomic) BOOL hoverable;
@property (nonatomic, copy, nullable) void (^onClick)(void);
@property (nonatomic, readonly) BOOL hovered;
/// A moving highlight laid over a card that is busy.
@property (nonatomic) BOOL shimmering;
@end

@interface CCIconTile : CCBox
+ (instancetype)tileWithSymbol:(NSString *)symbol size:(CGFloat)size radius:(CGFloat)radius iconSize:(CGFloat)iconSize;
@property (nonatomic, readonly) CCIcon *icon;
/// Pops to 112 % while the card around it is hovered.
@property (nonatomic) BOOL bounces;
- (void)setBounced:(BOOL)bounced;
@end

@interface CCPill : CCBox
+ (instancetype)pillWithText:(NSString *)text symbol:(nullable NSString *)symbol color:(CCColorBlock)color soft:(CCColorBlock)soft;
@property (nonatomic, readonly) CCLabel *label;
@end

// ───────────── buttons ─────────────

typedef NS_ENUM(NSInteger, CCButtonStyle) { CCButtonPrimary, CCButtonDanger, CCButtonGhost, CCButtonSubtle, CCButtonIcon, CCButtonSuccess };

@interface CCButton : NSView <CCLive>
+ (instancetype)buttonWithStyle:(CCButtonStyle)style title:(nullable NSString *)title symbol:(nullable NSString *)symbol;
@property (nonatomic) CCButtonStyle style;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *locKey;
@property (nonatomic, copy, nullable) NSString *symbol;
@property (nonatomic) BOOL enabled;
@property (nonatomic) NSEdgeInsets padding;
@property (nonatomic) CGFloat fontSize;
@property (nonatomic) CGFloat symbolSize;
/// The breathing glow of the main action (Controls/Pulse.cs).
@property (nonatomic) BOOL pulsing;
@property (nonatomic, copy, nullable) void (^onClick)(void);
@property (nonatomic, readonly) CCIcon *iconView;
/// Overrides the icon colour.
@property (nonatomic, copy, nullable) CCColorBlock iconColor;
@end

@interface CCChip : NSView <CCLive>
+ (instancetype)chipWithTitle:(NSString *)title;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *locKey;
@property (nonatomic) BOOL checked;
@property (nonatomic, copy, nullable) void (^onClick)(void);
@end

@interface CCToggle : NSView <CCLive>
@property (nonatomic) BOOL on;
@property (nonatomic) BOOL enabled;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
@property (nonatomic, copy, nullable) void (^onChange)(BOOL on);
@end

@interface CCCheck : NSView <CCLive>
@property (nonatomic) BOOL checked;
@property (nonatomic) BOOL enabled;
- (void)setChecked:(BOOL)checked animated:(BOOL)animated;
/// The third state: part of what it stands for is ticked. Clicking it ticks the whole.
@property (nonatomic) BOOL mixed;
- (void)setChecked:(BOOL)checked mixed:(BOOL)mixed animated:(BOOL)animated;
@property (nonatomic, copy, nullable) void (^onChange)(BOOL checked);
@end

@interface CCSearchField : CCBox <NSTextFieldDelegate>
@property (nonatomic, copy, nullable) NSString *placeholderKey;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nullable) void (^onChange)(NSString *text);
@end

@interface CCPopupField : CCBox
@property (nonatomic, copy) NSArray<NSString *> *items;
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic, copy, nullable) void (^onSelect)(NSInteger index);
@end

// ───────────── data visuals ─────────────

/// A rounded 0…1 bar whose fill eases to its value (Controls/SmoothBar.cs).
@interface CCSmoothBar : NSView <CCLive>
@property (nonatomic) double value;
@property (nonatomic) double duration;
@property (nonatomic, copy, nullable) CCColorBlock fillColor;
@property (nonatomic, copy, nullable) NSArray<NSColor *> *_Nonnull (^fillGradient)(void);
@property (nonatomic, copy) CCColorBlock trackColor;
- (void)setValue:(double)value animated:(BOOL)animated;
@end

/// A draggable 0…1 slider in the look of the smooth bar: seek and volume.
@interface CCSlider : NSView <CCLive>
@property (nonatomic) double value;
/// Called as it is dragged; finished on release.
@property (nonatomic, copy, nullable) void (^onChange)(double value, BOOL finished);
@property (nonatomic, readonly) BOOL dragging;
@end

/// A stacked proportional bar that tweens from the old layout to the new one (Controls/SegmentBar.cs).
@interface CCSegmentBar : NSView <CCLive>
/// Weights and colours, in order.
- (void)setWeights:(NSArray<NSNumber *> *)weights colors:(NSArray<NSColor *> *)colors;
/// The whole the weights are a share of; what they leave is empty track. 0 fills the bar.
@property (nonatomic) double capacity;
/// Each band is its own rounded pill instead of one clipped strip.
@property (nonatomic) BOOL roundedSegments;
@end

/// The selected-share and progress ring: a gradient arc with a glow, or a spinning arc while busy.
@interface CCRing : NSView <CCLive>
@property (nonatomic) BOOL spinning;
/// 0…360.
- (void)setAngle:(double)angle animated:(BOOL)animated;
@end

/// A small spinning arc (the Downloading… tile).
@interface CCSpinner : NSView <CCLive>
- (instancetype)initWithDiameter:(CGFloat)diameter lineWidth:(CGFloat)lineWidth sweep:(double)degrees period:(double)seconds;
@end

/// Lays its subviews out left to right and wraps them like WPF's WrapPanel.
@interface CCFlowView : NSView
@property (nonatomic) CGFloat hSpacing;
@property (nonatomic) CGFloat vSpacing;
- (void)setItems:(NSArray<NSView *> *)items;
/// An item's content changed size; lay the row out again.
- (void)itemsChanged;
@end

/// The app logo of Views/Logo.xaml: a gradient tile with a white arrow down onto a tray.
@interface CCLogoView : NSView <CCLive>
@end

/// A settings row: icon tile, title, description, control on the right, divider below.
@interface CCSettingRow : NSView <CCLive>
+ (instancetype)rowWithSymbol:(NSString *)symbol titleKey:(nullable NSString *)titleKey descKey:(nullable NSString *)descKey control:(nullable NSView *)control;
@property (nonatomic, readonly) CCLabel *titleLabel;
@property (nonatomic, readonly) CCLabel *descLabel;
@property (nonatomic) BOOL showsDivider;
@end

NS_ASSUME_NONNULL_END
