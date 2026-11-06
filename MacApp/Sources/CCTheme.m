#import "CCTheme.h"

NSNotificationName const CCThemeDidChangeNotification = @"CCThemeDidChange";

static BOOL gDark = YES;
static NSString *gMode = @"dark";

NSColor *CCHex(uint32_t rgb, CGFloat alpha) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:alpha];
}

NSFont *CCFont(CGFloat size, NSFontWeight weight) { return [NSFont systemFontOfSize:size weight:weight]; }

NSFont *CCDigitsFont(CGFloat size, NSFontWeight weight) { return [NSFont monospacedDigitSystemFontOfSize:size weight:weight]; }

NSArray *CCCGColors(NSArray<NSColor *> *colors) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSColor *c in colors) [result addObject:(__bridge id)c.CGColor];
    return result;
}

#define PICK(dark, light) (gDark ? (dark) : (light))

static BOOL SystemIsDark(void) {
    NSAppearanceName name = [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [name isEqualToString:NSAppearanceNameDarkAqua];
}

@implementation CCTheme

+ (BOOL)isDark { return gDark; }

+ (void)applyMode:(NSString *)mode {
    gMode = [mode copy];
    BOOL system = [mode isEqualToString:@"system"];
    // Native pieces (menus, scrollers, tooltips, panels) follow the same theme; "system" leaves them to macOS.
    if (system) NSApp.appearance = nil;
    BOOL dark = system ? SystemIsDark() : ![mode isEqualToString:@"light"];
    if (!system) NSApp.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    BOOL changed = dark != gDark;
    gDark = dark;
    if (changed) [NSNotificationCenter.defaultCenter postNotificationName:CCThemeDidChangeNotification object:nil];
}

+ (void)systemAppearanceChanged {
    if ([gMode isEqualToString:@"system"]) [self applyMode:gMode];
}

+ (NSColor *)bg { return PICK(CCHex(0x0B0D14, 1), CCHex(0xF3F4F9, 1)); }
+ (NSColor *)bgTranslucent { return PICK(CCHex(0x0B0D14, 0xD9 / 255.0), CCHex(0xF3F4F9, 0xCC / 255.0)); }
+ (NSColor *)card { return PICK(CCHex(0x141826, 0.92), CCHex(0xFFFFFF, 0.86)); }
+ (NSColor *)cardSolid { return PICK(CCHex(0x151A29, 1), CCHex(0xFFFFFF, 1)); }
+ (NSColor *)cardHover { return PICK(CCHex(0x1B2033, 1), CCHex(0xFFFFFF, 1)); }
+ (NSColor *)cardBorder { return PICK(CCHex(0xFFFFFF, 0.08), CCHex(0x0F172A, 0.08)); }
+ (NSColor *)cardBorderHover { return PICK(CCHex(0xFFFFFF, 0.16), CCHex(0x0F172A, 0.16)); }
+ (NSColor *)inset { return PICK(CCHex(0xFFFFFF, 0.04), CCHex(0x0F172A, 0.035)); }
+ (NSColor *)hover { return PICK(CCHex(0xFFFFFF, 0.06), CCHex(0x0F172A, 0.05)); }
+ (NSColor *)pressed { return PICK(CCHex(0xFFFFFF, 0.10), CCHex(0x0F172A, 0.09)); }
+ (NSColor *)text { return PICK(CCHex(0xF3F5F9, 1), CCHex(0x0F172A, 1)); }
+ (NSColor *)textMuted { return PICK(CCHex(0x8E96AB, 1), CCHex(0x5B6478, 1)); }
+ (NSColor *)textFaint { return PICK(CCHex(0x5B6479, 1), CCHex(0x94A0B8, 1)); }
+ (NSColor *)accent { return PICK(CCHex(0x7C6CFF, 1), CCHex(0x6A5AF9, 1)); }
+ (NSColor *)accent2 { return PICK(CCHex(0x22D3EE, 1), CCHex(0x0EA5C9, 1)); }
+ (NSColor *)accentSoft { return PICK(CCHex(0x7C6CFF, 0.18), CCHex(0x6A5AF9, 0.14)); }
+ (NSColor *)danger { return PICK(CCHex(0xFB7185, 1), CCHex(0xE11D48, 1)); }
+ (NSColor *)dangerSoft { return PICK(CCHex(0xFB7185, 0.16), CCHex(0xE11D48, 0.12)); }
+ (NSColor *)warning { return PICK(CCHex(0xFBBF24, 1), CCHex(0xD97706, 1)); }
+ (NSColor *)warningSoft { return PICK(CCHex(0xFBBF24, 0.16), CCHex(0xD97706, 0.12)); }
+ (NSColor *)success { return PICK(CCHex(0x34D399, 1), CCHex(0x059669, 1)); }
+ (NSColor *)successSoft { return PICK(CCHex(0x34D399, 0.16), CCHex(0x059669, 0.12)); }
+ (NSColor *)track { return PICK(CCHex(0xFFFFFF, 0.08), CCHex(0x0F172A, 0.08)); }
+ (NSColor *)input { return PICK(CCHex(0xFFFFFF, 0.05), CCHex(0xFFFFFF, 0.9)); }
+ (NSColor *)inputBorder { return PICK(CCHex(0xFFFFFF, 0.10), CCHex(0x0F172A, 0.12)); }
+ (NSColor *)overlay { return PICK(CCHex(0x06080F, 0.72), CCHex(0xE8EAF2, 0.72)); }
+ (NSColor *)popup { return PICK(CCHex(0x1A1F30, 1), CCHex(0xFFFFFF, 1)); }
+ (NSColor *)knob { return CCHex(0xFFFFFF, 1); }
+ (NSColor *)divider { return PICK(CCHex(0xFFFFFF, 0.07), CCHex(0x0F172A, 0.07)); }
+ (CGFloat)shadowOpacity { return PICK(0.45, 0.18); }

+ (NSColor *)colorForRole:(CCRole)role {
    switch (role) {
        case CCRoleText: return self.text;
        case CCRoleMuted: return self.textMuted;
        case CCRoleFaint: return self.textFaint;
        case CCRoleAccent: return self.accent;
        case CCRoleSuccess: return self.success;
        case CCRoleWarning: return self.warning;
        case CCRoleDanger: return self.danger;
        case CCRoleOnAccent: return NSColor.whiteColor;
        case CCRoleCustom: return self.text;
    }
    return self.text;
}

+ (NSArray<NSColor *> *)accentGradient {
    return PICK((@[ CCHex(0x8B7CFF, 1), CCHex(0x5B8CFF, 1), CCHex(0x22D3EE, 1) ]),
                (@[ CCHex(0x7C6CFF, 1), CCHex(0x4F7DFF, 1), CCHex(0x0EA5C9, 1) ]));
}
+ (NSArray<NSNumber *> *)accentGradientLocations { return @[ @0, @0.55, @1 ]; }
+ (NSArray<NSColor *> *)ringGradient {
    return PICK((@[ CCHex(0xA78BFA, 1), CCHex(0x7C6CFF, 1), CCHex(0x22D3EE, 1) ]),
                (@[ CCHex(0x8B5CF6, 1), CCHex(0x6A5AF9, 1), CCHex(0x0EA5C9, 1) ]));
}
+ (NSArray<NSColor *> *)dangerGradient {
    return PICK((@[ CCHex(0xFB7185, 1), CCHex(0xF43F5E, 1) ]), (@[ CCHex(0xF43F5E, 1), CCHex(0xE11D48, 1) ]));
}
+ (NSArray<NSColor *> *)successGradient {
    // Deep enough for white text in both themes (the light pair it replaced read poorly on dark).
    return PICK((@[ CCHex(0x059669, 1), CCHex(0x0E7490, 1) ]), (@[ CCHex(0x059669, 1), CCHex(0x0E7490, 1) ]));
}
+ (NSArray<NSColor *> *)blobColors {
    return PICK((@[ CCHex(0x7C6CFF, 0x55 / 255.0), CCHex(0x22D3EE, 0x3D / 255.0), CCHex(0xF472B6, 0x33 / 255.0) ]),
                (@[ CCHex(0x7C6CFF, 0x3D / 255.0), CCHex(0x22D3EE, 0x2E / 255.0), CCHex(0xF472B6, 0x26 / 255.0) ]));
}

+ (NSColor *)categoryColor:(NSInteger)index {
    static const uint32_t colors[] = { 0x60A5FA, 0xF59E0B, 0xA78BFA, 0x34D399, 0xF472B6, 0x22D3EE };
    return CCHex(colors[(NSUInteger)MAX(0, index) % 6], 1);
}
+ (NSColor *)categorySoft:(NSInteger)index { return [[self categoryColor:index] colorWithAlphaComponent:0.16]; }

@end
