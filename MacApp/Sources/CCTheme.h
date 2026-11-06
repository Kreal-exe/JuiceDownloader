// The palette of the Windows app's Themes/Dark.xaml and Themes/Light.xaml, plus the theme-independent category colours
// of Styles.xaml, which the sections wear in turn.
#import <Cocoa/Cocoa.h>
#import "CCCore.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const CCThemeDidChangeNotification;

typedef NS_ENUM(NSInteger, CCRole) {
    CCRoleText,
    CCRoleMuted,
    CCRoleFaint,
    CCRoleAccent,
    CCRoleSuccess,
    CCRoleWarning,
    CCRoleDanger,
    CCRoleOnAccent,
    CCRoleCustom,
};

@interface CCTheme : NSObject
@property (class, nonatomic, readonly) BOOL isDark;
/// "dark", "light" or "system".
+ (void)applyMode:(NSString *)mode;
+ (void)systemAppearanceChanged;

+ (NSColor *)bg;
+ (NSColor *)bgTranslucent;
+ (NSColor *)card;
+ (NSColor *)cardSolid;
+ (NSColor *)cardHover;
+ (NSColor *)cardBorder;
+ (NSColor *)cardBorderHover;
+ (NSColor *)inset;
+ (NSColor *)hover;
+ (NSColor *)pressed;
+ (NSColor *)text;
+ (NSColor *)textMuted;
+ (NSColor *)textFaint;
+ (NSColor *)accent;
+ (NSColor *)accent2;
+ (NSColor *)accentSoft;
+ (NSColor *)danger;
+ (NSColor *)dangerSoft;
+ (NSColor *)warning;
+ (NSColor *)warningSoft;
+ (NSColor *)success;
+ (NSColor *)successSoft;
+ (NSColor *)track;
+ (NSColor *)input;
+ (NSColor *)inputBorder;
+ (NSColor *)overlay;
+ (NSColor *)popup;
+ (NSColor *)knob;
+ (NSColor *)divider;
+ (CGFloat)shadowOpacity;
+ (NSColor *)colorForRole:(CCRole)role;

/// Gradients as colours + locations, drawn from the top-left to the bottom-right corner like the XAML brushes.
+ (NSArray<NSColor *> *)accentGradient;
+ (NSArray<NSNumber *> *)accentGradientLocations;
+ (NSArray<NSColor *> *)ringGradient;
+ (NSArray<NSColor *> *)dangerGradient;
+ (NSArray<NSColor *> *)successGradient;
+ (NSArray<NSColor *> *)blobColors;

+ (NSColor *)categoryColor:(NSInteger)index;
+ (NSColor *)categorySoft:(NSInteger)index;
@end

NSColor *CCHex(uint32_t rgb, CGFloat alpha);
NSFont *CCFont(CGFloat size, NSFontWeight weight);
/// Tabular digits, so animated counters do not jitter.
NSFont *CCDigitsFont(CGFloat size, NSFontWeight weight);
NSArray *CCCGColors(NSArray<NSColor *> *colors);

NS_ASSUME_NONNULL_END
